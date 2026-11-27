import AppKit
import Combine
import CoreVideo
import Foundation
import Vision
import os

public enum EngineRunMode: Equatable, Sendable {
    case idle
    case lockScreenUnlock
    case diagnosticScan
    case enrollment(name: String, poseIndex: Int)
}

private final class SendablePixelBuffer: @unchecked Sendable {
    let buffer: CVPixelBuffer
    init(_ buffer: CVPixelBuffer) { self.buffer = buffer }
}

private final class FramePipelineGate: @unchecked Sendable {
    private let lock = NSLock()
    private var busy = false
    private var counter = 0

    func tryAcquire() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if busy { return false }
        busy = true
        return true
    }

    func release() {
        lock.lock()
        busy = false
        lock.unlock()
    }

    func nextFrameNumber() -> Int {
        lock.lock()
        defer { lock.unlock() }
        counter += 1
        return counter
    }

    func resetCounter() {
        lock.lock()
        counter = 0
        lock.unlock()
    }
}

/// Master coordinator tying together LockScreenMonitor, FastCameraCapture, FaceWarper,
/// ArcFace FP16 Core ML / Vision embedder, StreamingLivenessDetector, SessionCryptoVault,
/// and LockScreenKeystrokeDriver with strict 5-gate verification and zero-idle resource usage.
@MainActor
public final class FaceUnlockEngine: ObservableObject {
    public static let shared = FaceUnlockEngine()
    private static let log = Logger(subsystem: "com.local.pliw-face", category: "Engine")

    @Published public var settings: FaceSettings {
        didSet {
            settings.save()
        }
    }
    @Published public private(set) var identities: [FaceIdentity] = []
    @Published public private(set) var phase: UnlockPhase = .idle
    @Published public private(set) var telemetry: ScanTelemetry = .empty
    @Published public private(set) var runMode: EngineRunMode = .idle
    @Published public private(set) var isSessionArmed: Bool = false
    @Published public private(set) var hasStoredPassword: Bool = false
    @Published public private(set) var cameraAccess: CameraAccessState = .notDetermined
    @Published public private(set) var accessibilityTrusted: Bool = false
    @Published public private(set) var inputMonitoringGranted: Bool = false
    @Published public private(set) var isKeychainUnlockVerified: Bool = false
    @Published public private(set) var lastUnlockLatencyMs: Int? = nil
    @Published public private(set) var enrollmentCompletedPoses: [EnrollmentPose] = []
    @Published public private(set) var toastMessage: String? = nil
    @Published public private(set) var isToastError: Bool = false
    @Published public private(set) var isScreenLocked: Bool = false

    public let camera = FastCameraCapture()
    public private(set) var embedder: any FaceEmbeddingEngine

    private let warper = FaceWarper()
    private let liveness = StreamingLivenessDetector()
    private let lockMonitor = LockScreenMonitor()
    private let spacebarTrigger = SpacebarHIDTrigger()
    private let notchHoverTrigger = NotchHoverTrigger()
    private let vault: SessionCryptoVault
    private let identityStore: FaceIdentityStore

    private let pipelineQueue = DispatchQueue(label: "com.local.pliw-face.pipeline", qos: .userInteractive)
    private let frameGate = FramePipelineGate()

    private var scanStartUptime: TimeInterval = 0
    private var lastUnlockAttemptUptime: TimeInterval = 0
    private var scanTimeoutTask: Task<Void, Never>?
    private var idleLockTimer: Timer?
    private var toastTask: Task<Void, Never>?

    // Enrollment scratch state (main actor only)
    private var enrollmentTemplates: [EnrolledFaceTemplate] = []
    private var lastEnrollmentCaptureUptime: TimeInterval = 0

    public init(
        vault: SessionCryptoVault = .shared,
        identityStore: FaceIdentityStore = .shared,
        embedder: (any FaceEmbeddingEngine)? = nil
    ) {
        self.vault = vault
        self.identityStore = identityStore
        self.settings = FaceSettings.load()
        self.embedder = embedder ?? FaceEmbedderFactory.makeBestAvailable()
        self.telemetry.engineName = self.embedder.displayName

        if self.settings.autoArmOnLaunch, self.vault.autoArmFromKeychainIfAvailable() {
            startIdleSessionTimer()
        }

        refreshSystemReadiness()
        configureMonitors()
    }

    // MARK: - Readiness & Permissions

    public var isReadyForLockScreenUnlock: Bool {
        settings.isEnabled
            && isSessionArmed
            && hasStoredPassword
            && !enabledIdentitiesForCurrentModel.isEmpty
            && cameraAccess.isAuthorized
            && accessibilityTrusted
    }

    public var enabledIdentitiesForCurrentModel: [FaceIdentity] {
        identities.filter { $0.isEnabled && $0.modelIdentifier == embedder.modelIdentifier }
    }

    public func refreshSystemReadiness() {
        isSessionArmed = vault.isSessionArmed
        hasStoredPassword = vault.hasStoredPassword()
        cameraAccess = FastCameraCapture.authorizationState()
        accessibilityTrusted = LockScreenKeystrokeDriver.isAccessibilityTrusted()
        inputMonitoringGranted = SpacebarHIDTrigger.isInputMonitoringGranted()

        if isSessionArmed {
            reloadIdentities()
        }
    }

    public func requestCameraPermission() {
        Task { @MainActor in
            let granted = await FastCameraCapture.requestAccess()
            refreshSystemReadiness()
            if !granted {
                showToast("Enable Camera in System Settings → Privacy & Security", isError: true)
            }
        }
    }

    public func requestAccessibilityPermission() {
        LockScreenKeystrokeDriver.requestAccessibilityPrompt()
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 800_000_000)
            refreshSystemReadiness()
        }
    }

    public func requestInputMonitoringPermission() {
        _ = SpacebarHIDTrigger.requestInputMonitoringAccess()
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 800_000_000)
            refreshSystemReadiness()
        }
    }

    /// Pre-authorizes Keychain password read while unlocked so macOS "Always Allow" never hides behind the Lock Screen.
    public func verifyAndAuthorizeKeychainAccess() {
        Task { @MainActor in
            do {
                if !vault.isSessionArmed {
                    try await vault.armSession(reason: "Verify Pliw Face Keychain unlock access")
                    refreshSystemReadiness()
                }
                guard vault.hasStoredPassword() else {
                    showToast("Save your Mac login password below first", isError: true)
                    return
                }
                try await Task.detached(priority: .userInitiated) { [vault] in
                    try vault.verifyKeychainPasswordAccess()
                }.value
                isKeychainUnlockVerified = true
                showToast("Keychain authorized — Lock Screen auto-fill ready!", isError: false)
            } catch SessionVaultError.authenticationCancelled {
                showToast("Touch ID cancelled", isError: false)
            } catch {
                isKeychainUnlockVerified = false
                showToast("Keychain check failed: \(error.localizedDescription)", isError: true)
            }
        }
    }

    // MARK: - Session & Credential Lifecycle

    public func armSession() {
        Task { @MainActor in
            do {
                try await vault.armSession(reason: "Authorize Pliw Face unlock session")
                isSessionArmed = vault.isSessionArmed
                reloadIdentities()
                startIdleSessionTimer()
                showToast("Session armed — Face Unlock active", isError: false)
            } catch SessionVaultError.authenticationCancelled {
                showToast("Touch ID cancelled", isError: false)
            } catch {
                showToast(error.localizedDescription, isError: true)
            }
        }
    }

    public func disarmSession() {
        stopAnyActiveScan()
        vault.disarmSession()
        isSessionArmed = false
        identities = []
        stopIdleSessionTimer()
        showToast("Session locked", isError: false)
    }

    public func saveMacPassword(_ plainPassword: String) {
        guard !plainPassword.isEmpty else {
            showToast("Password cannot be empty", isError: true)
            return
        }
        Task { @MainActor in
            do {
                var bytes = Data(plainPassword.utf8)
                defer { bytes.resetBytes(in: 0..<bytes.count) }

                if !vault.isSessionArmed {
                    try await vault.armSession(reason: "Encrypt and store Mac login password")
                } else {
                    try await vault.authenticateOwner(reason: "Update encrypted Mac login password")
                }
                let copy = bytes
                try await Task.detached(priority: .userInitiated) { [vault] in
                    try vault.savePassword(copy)
                }.value

                refreshSystemReadiness()
                startIdleSessionTimer()
                showToast("Login password encrypted in Keychain", isError: false)
            } catch SessionVaultError.authenticationCancelled {
                showToast("Touch ID cancelled", isError: false)
            } catch {
                showToast(error.localizedDescription, isError: true)
            }
        }
    }

    public func deleteStoredCredentialsAndFaces() {
        stopAnyActiveScan()
        try? vault.deleteAllCredentials()
        identityStore.deleteAll()
        identities = []
        refreshSystemReadiness()
        showToast("Cleared all stored credentials & face data", isError: false)
    }

    public func reloadIdentities() {
        guard vault.isSessionArmed else {
            identities = []
            return
        }
        do {
            identities = try identityStore.load()
        } catch {
            identities = []
        }
    }

    public func toggleIdentityEnabled(_ id: UUID) {
        guard let idx = identities.firstIndex(where: { $0.id == id }) else { return }
        identities[idx].isEnabled.toggle()
        try? identityStore.save(identities)
    }

    public func deleteIdentity(_ id: UUID) {
        identities.removeAll { $0.id == id }
        if vault.isSessionArmed {
            try? identityStore.save(identities)
        }
        showToast("Face identity removed", isError: false)
    }

    // MARK: - Monitors & Zero-Idle Lifecycle

    public func startBackgroundMonitoring() {
        lockMonitor.start()
        isScreenLocked = LockScreenMonitor.isScreenActuallyLocked()
        if isScreenLocked {
            if settings.unlockOnSpacebar {
                spacebarTrigger.startListening()
            }
            if settings.unlockOnNotchHover {
                notchHoverTrigger.startListening()
            }
        }
    }

    public func stopBackgroundMonitoring() {
        stopAnyActiveScan()
        lockMonitor.stop()
        spacebarTrigger.stopListening()
        notchHoverTrigger.stopListening()
        isScreenLocked = false
        stopIdleSessionTimer()
    }

    private func configureMonitors() {
        lockMonitor.onEvent = { [weak self] event in
            self?.handleLockEvent(event)
        }
        spacebarTrigger.onSpacePressed = { [weak self] in
            self?.handleSpacebarWhileLocked()
        }
        notchHoverTrigger.onNotchHovered = { [weak self] in
            self?.handleNotchHoverWhileLocked()
        }
    }

    private func handleLockEvent(_ event: LockEvent) {
        switch event {
        case .willSleep:
            stopAnyActiveScan()
            spacebarTrigger.stopListening()
            notchHoverTrigger.stopListening()

        case .locked:
            isScreenLocked = true
            if settings.unlockOnSpacebar {
                spacebarTrigger.startListening()
                if !spacebarTrigger.isListening {
                    Task { @MainActor [weak self] in
                        try? await Task.sleep(nanoseconds: 350_000_000)
                        guard let self, self.settings.unlockOnSpacebar, LockScreenMonitor.isScreenActuallyLocked() else { return }
                        self.spacebarTrigger.startListening()
                    }
                }
            }
            if settings.unlockOnNotchHover {
                notchHoverTrigger.startListening()
            }
            guard settings.unlockOnLock, !lockMonitor.isSleeping else { return }
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 300_000_000)
                self?.triggerLockScreenScanIfEligible()
            }

        case .wokeUp:
            let locked = LockScreenMonitor.isScreenActuallyLocked()
            isScreenLocked = locked
            if locked {
                if settings.unlockOnSpacebar {
                    spacebarTrigger.startListening()
                }
                if settings.unlockOnNotchHover {
                    notchHoverTrigger.startListening()
                }
                if settings.unlockOnWake {
                    Task { @MainActor [weak self] in
                        try? await Task.sleep(nanoseconds: 220_000_000)
                        self?.triggerLockScreenScanIfEligible()
                    }
                }
            }

        case .unlocked:
            isScreenLocked = false
            spacebarTrigger.stopListening()
            notchHoverTrigger.stopListening()
            if runMode == .lockScreenUnlock {
                stopAnyActiveScan()
            }
        }
    }

    private func handleSpacebarWhileLocked() {
        let locked = LockScreenMonitor.isScreenActuallyLocked()
        Self.log.info("Spacebar callback: unlockOnSpacebar=\(self.settings.unlockOnSpacebar) locked=\(locked) armed=\(self.isSessionArmed)")
        guard settings.unlockOnSpacebar, locked else { return }
        triggerLockScreenScanIfEligible(manualTrigger: true)
    }

    public func handleNotchHoverWhileLocked() {
        let locked = LockScreenMonitor.isScreenActuallyLocked()
        guard settings.unlockOnNotchHover, locked, runMode == .idle else { return }
        Self.log.info("Notch hover callback — triggering Lock Screen rescan")
        if settings.hapticFeedback {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
        triggerLockScreenScanIfEligible(manualTrigger: true)
    }

    // MARK: - Scan Control (Lock Screen / Diagnostic / Enrollment)

    public func triggerLockScreenScanIfEligible(manualTrigger: Bool = false) {
        // Enforce idle timeout before attempting any unlock
        if vault.enforceIdleTimeout(settings.sessionTimeout.timeInterval) {
            isSessionArmed = false
            identities = []
            return
        }

        refreshSystemReadiness()
        guard runMode == .idle else {
            Self.log.info("Skip scan: runMode not idle")
            return
        }
        guard isReadyForLockScreenUnlock else {
            Self.log.warning("Skip scan: not ready (enabled=\(self.settings.isEnabled) armed=\(self.isSessionArmed) pw=\(self.hasStoredPassword) faces=\(self.enabledIdentitiesForCurrentModel.count) cam=\(self.cameraAccess.isAuthorized) ax=\(self.accessibilityTrusted))")
            return
        }
        guard LockScreenMonitor.isScreenActuallyLocked() else { return }

        let now = ProcessInfo.processInfo.systemUptime
        let cooldown: TimeInterval = manualTrigger ? 0.6 : 2.2
        guard now - lastUnlockAttemptUptime >= cooldown else { return }

        Self.log.info("Starting Lock Screen face scan (manual=\(manualTrigger))")
        beginScan(mode: .lockScreenUnlock, timeout: settings.scanTimeoutSeconds)
    }

    public func startDiagnosticScan() {
        refreshSystemReadiness()
        Task { @MainActor in
            if !cameraAccess.isAuthorized {
                let granted = await FastCameraCapture.requestAccess()
                refreshSystemReadiness()
                guard granted else {
                    showToast("Enable Camera in System Settings → Privacy & Security → Camera", isError: true)
                    return
                }
            }
            stopAnyActiveScan()
            beginScan(mode: .diagnosticScan, timeout: nil)
        }
    }

    public func startEnrollment(name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let label = trimmed.isEmpty ? "Primary Face" : trimmed

        refreshSystemReadiness()

        Task { @MainActor in
            if !cameraAccess.isAuthorized {
                let granted = await FastCameraCapture.requestAccess()
                refreshSystemReadiness()
                guard granted else {
                    showToast("Enable Camera in System Settings → Privacy & Security → Camera", isError: true)
                    return
                }
            }

            if !vault.isSessionArmed {
                do {
                    try await vault.armSession(reason: "Authorize Pliw Face enrollment")
                    refreshSystemReadiness()
                    startIdleSessionTimer()
                } catch SessionVaultError.authenticationCancelled {
                    showToast("Touch ID cancelled — enrollment stopped", isError: false)
                    return
                } catch {
                    showToast("Keychain error: \(error.localizedDescription)", isError: true)
                    return
                }
            }

            stopAnyActiveScan()
            enrollmentTemplates = []
            enrollmentCompletedPoses = []
            lastEnrollmentCaptureUptime = 0
            beginScan(mode: .enrollment(name: label, poseIndex: 0), timeout: nil)
        }
    }

    public func stopAnyActiveScan() {
        scanTimeoutTask?.cancel()
        scanTimeoutTask = nil
        camera.stop()
        runMode = .idle
        phase = .idle
        frameGate.resetCounter()
        liveness.reset()
    }

    private func beginScan(mode: EngineRunMode, timeout: TimeInterval?) {
        runMode = mode
        phase = .warmingCamera
        scanStartUptime = ProcessInfo.processInfo.systemUptime
        frameGate.resetCounter()
        liveness.reset()
        telemetry = ScanTelemetry(
            engineName: embedder.displayName,
            faceDetected: false,
            faceQuality: 0,
            bestIdentityName: nil,
            similarityScore: 0,
            inferenceMs: 0,
            totalElapsedMs: 0,
            livenessVerdict: .pending,
            glareRatio: 0,
            bezelDetected: false,
            blinkDetected: false,
            parallaxScore: 0,
            framesProcessed: 0
        )

        let activeIdentities = enabledIdentitiesForCurrentModel
        let activeSettings = settings
        let activeEmbedder = embedder

        camera.start(
            onFrame: { [weak self] pixelBuffer, timestamp in
                self?.enqueueFrame(
                    pixelBuffer: pixelBuffer,
                    timestamp: timestamp,
                    mode: mode,
                    identities: activeIdentities,
                    settings: activeSettings,
                    embedder: activeEmbedder
                )
            },
            onError: { [weak self] errorMessage in
                Task { @MainActor [weak self] in
                    self?.stopAnyActiveScan()
                    self?.showToast(errorMessage, isError: true)
                }
            }
        )

        if let timeout {
            scanTimeoutTask?.cancel()
            scanTimeoutTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                guard !Task.isCancelled, let self, self.runMode == .lockScreenUnlock else { return }
                self.stopAnyActiveScan()
                self.phase = .rejected("Scan timed out")
            }
        }
    }

    // MARK: - High-Performance Frame Pipeline (Off-Main-Actor)

    private nonisolated func enqueueFrame(
        pixelBuffer: CVPixelBuffer,
        timestamp: TimeInterval,
        mode: EngineRunMode,
        identities: [FaceIdentity],
        settings: FaceSettings,
        embedder: any FaceEmbeddingEngine
    ) {
        guard frameGate.tryAcquire() else { return }
        let boxed = SendablePixelBuffer(pixelBuffer)

        pipelineQueue.async { [weak self] in
            guard let self else { return }
            defer { self.frameGate.release() }
            self.processFrameOnPipeline(
                pixelBuffer: boxed.buffer,
                timestamp: timestamp,
                mode: mode,
                identities: identities,
                settings: settings,
                embedder: embedder
            )
        }
    }

    private nonisolated func processFrameOnPipeline(
        pixelBuffer: CVPixelBuffer,
        timestamp: TimeInterval,
        mode: EngineRunMode,
        identities: [FaceIdentity],
        settings: FaceSettings,
        embedder: any FaceEmbeddingEngine
    ) {
        let frameStart = ProcessInfo.processInfo.systemUptime

        let landmarksReq = VNDetectFaceLandmarksRequest()
        let qualityReq = VNDetectFaceCaptureQualityRequest()

        // Throttle rectangle/bezel detection to every 3rd frame to save CPU/GPU budget
        let localFrameNum = frameGate.nextFrameNumber()
        let runBezelCheck = (localFrameNum % 3 == 1)

        var requests: [VNRequest] = [landmarksReq, qualityReq]
        let rectReq = VNDetectRectanglesRequest()
        if runBezelCheck {
            rectReq.maximumObservations = 4
            rectReq.minimumConfidence = 0.72
            rectReq.minimumSize = 0.22
            requests.append(rectReq)
        }

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
        do {
            try handler.perform(requests)
        } catch {
            return
        }

        // Select the largest face in frame
        guard let face = (landmarksReq.results ?? []).max(by: {
            ($0.boundingBox.width * $0.boundingBox.height) < ($1.boundingBox.width * $1.boundingBox.height)
        }) else {
            Task { @MainActor [weak self] in
                guard let self, self.runMode != .idle else { return }
                self.phase = .scanning
                self.telemetry.faceDetected = false
                self.telemetry.framesProcessed = localFrameNum
                self.telemetry.totalElapsedMs = (ProcessInfo.processInfo.systemUptime - self.scanStartUptime) * 1000
            }
            return
        }

        // Early-exit frame gatekeeper: drop pitch-black camera warm-up frames while remaining responsive in dim night lighting
        let quality = (qualityReq.results?.first?.faceCaptureQuality) ?? 0.35
        guard quality >= 0.12 else {
            return
        }

        // 1. Align face to 112×112 using Metal/CIContext + reusable pixel buffer pool
        guard let warped = warper.warpFace(from: pixelBuffer, observation: face) else {
            return
        }

        // 2. Run FP16 ArcFace Core ML (or Vision fallback) inference
        let inferStart = ProcessInfo.processInfo.systemUptime
        let vector: [Float]
        do {
            vector = try embedder.embed(alignedFace: warped.buffer)
        } catch {
            return
        }
        let inferMs = (ProcessInfo.processInfo.systemUptime - inferStart) * 1000

        // 3. Extract fast zero-copy liveness cues
        let glareRatio = VectorMath.computeSpecularGlareRatio(
            pixelBuffer: pixelBuffer,
            normalizedVisionBox: face.boundingBox
        )
        let bezelDetected = runBezelCheck
            ? StreamingLivenessDetector.detectFramingBezel(rectangles: rectReq.results ?? [], faceBox: face.boundingBox)
            : false
        let geo = StreamingLivenessDetector.extractGeometryCues(from: face)
        let yaw = face.yaw?.floatValue ?? 0

        let sample = LivenessFrameSample(
            timestamp: timestamp,
            glareRatio: glareRatio,
            bezelDetected: bezelDetected,
            eyeAspectRatio: geo.ear,
            noseOffsetX: geo.noseOffsetX,
            noseOffsetY: geo.noseOffsetY,
            yaw: yaw,
            faceQuality: quality
        )

        // 4. Match against enrolled templates with Accelerate vDSP (< 0.01ms)
        let match = VectorMath.bestMatch(
            query: vector,
            identities: identities,
            modelIdentifier: embedder.modelIdentifier
        )

        let frameTimeMs = (ProcessInfo.processInfo.systemUptime - frameStart) * 1000
        _ = frameTimeMs

        Task { @MainActor [weak self] in
            self?.handleProcessedFrame(
                vector: vector,
                quality: quality,
                inferMs: inferMs,
                sample: sample,
                match: match,
                frameNumber: localFrameNum
            )
        }
    }

    private func handleProcessedFrame(
        vector: [Float],
        quality: Float,
        inferMs: Double,
        sample: LivenessFrameSample,
        match: (identity: FaceIdentity, score: Float)?,
        frameNumber: Int
    ) {
        guard runMode != .idle else { return }

        let livenessEval = liveness.recordAndEvaluate(sample, mode: settings.livenessMode)
        let elapsedMs = (ProcessInfo.processInfo.systemUptime - scanStartUptime) * 1000

        telemetry = ScanTelemetry(
            engineName: embedder.displayName,
            faceDetected: true,
            faceQuality: quality,
            bestIdentityName: match?.identity.name,
            similarityScore: match?.score ?? 0,
            inferenceMs: inferMs,
            totalElapsedMs: elapsedMs,
            livenessVerdict: livenessEval.verdict,
            glareRatio: livenessEval.maxGlareRatio,
            bezelDetected: livenessEval.bezelDetected,
            blinkDetected: livenessEval.blinkDetected,
            parallaxScore: livenessEval.parallaxScore,
            framesProcessed: frameNumber
        )

        switch runMode {
        case .idle:
            return

        case .diagnosticScan:
            phase = .scanning

        case .enrollment(let name, let poseIndex):
            phase = .scanning
            handleEnrollmentFrame(
                name: name,
                poseIndex: poseIndex,
                vector: vector,
                quality: quality
            )

        case .lockScreenUnlock:
            phase = .scanning
            handleLockScreenDecision(match: match, livenessEval: livenessEval, elapsedMs: elapsedMs)
        }
    }

    private func handleEnrollmentFrame(
        name: String,
        poseIndex: Int,
        vector: [Float],
        quality: Float
    ) {
        let allPoses = EnrollmentPose.allCases
        guard poseIndex < allPoses.count else { return }

        // Require usable frame quality and a brief pause between poses so the user naturally shifts angle
        let now = ProcessInfo.processInfo.systemUptime
        guard quality >= 0.16, now - lastEnrollmentCaptureUptime >= 0.55 else { return }

        let pose = allPoses[poseIndex]
        enrollmentTemplates.append(EnrolledFaceTemplate(pose: pose, vector: vector, qualityScore: quality))
        enrollmentCompletedPoses.append(pose)
        lastEnrollmentCaptureUptime = now

        if settings.hapticFeedback {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }

        let nextIndex = poseIndex + 1
        if nextIndex < allPoses.count {
            runMode = .enrollment(name: name, poseIndex: nextIndex)
        } else {
            // Save encrypted identity
            let identity = FaceIdentity(
                name: name,
                isEnabled: true,
                modelIdentifier: embedder.modelIdentifier,
                embeddingDimension: embedder.embeddingDimension,
                templates: enrollmentTemplates
            )
            identities.insert(identity, at: 0)
            do {
                try identityStore.save(identities)
                stopAnyActiveScan()
                showToast("Enrolled \"\(name)\" (\(enrollmentTemplates.count) angles encrypted)", isError: false)
            } catch {
                stopAnyActiveScan()
                showToast("Failed to save face identity: \(error.localizedDescription)", isError: true)
            }
        }
    }

    /// Strict 5-gate lock-screen unlock verification.
    private func handleLockScreenDecision(
        match: (identity: FaceIdentity, score: Float)?,
        livenessEval: LivenessEvaluation,
        elapsedMs: Double
    ) {
        if case .spoofDetected(let reason) = livenessEval.verdict {
            stopAnyActiveScan()
            phase = .rejected("Blocked: \(reason)")
            return
        }

        guard let match, match.score >= settings.similarityThreshold else {
            return
        }
        guard livenessEval.verdict.isLive else {
            return
        }

        // Gate 1..5 final check directly before reading password bytes
        guard vault.isSessionArmed,
              LockScreenMonitor.isScreenActuallyLocked(),
              LockScreenKeystrokeDriver.isAccessibilityTrusted() else {
            stopAnyActiveScan()
            return
        }

        lastUnlockAttemptUptime = ProcessInfo.processInfo.systemUptime
        stopAnyActiveScan()

        let matchedName = match.identity.name
        let latencyMs = Int(elapsedMs.rounded())
        let useHaptics = settings.hapticFeedback

        Task.detached(priority: .userInitiated) { [vault] in
            do {
                var passwordBytes = try vault.readPassword()
                guard LockScreenMonitor.isScreenActuallyLocked() else {
                    if !passwordBytes.isEmpty {
                        passwordBytes.resetBytes(in: 0..<passwordBytes.count)
                    }
                    return
                }
                try LockScreenKeystrokeDriver.submitPassword(&passwordBytes)
                await MainActor.run { [weak self] in
                    self?.lastUnlockLatencyMs = latencyMs
                    self?.phase = .unlocked(identityName: matchedName, latencyMs: latencyMs)
                    if useHaptics {
                        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
                    }
                }
            } catch KeystrokeDriverError.screenNoLongerLocked {
                // Screen unlocked concurrently (e.g. Touch ID / Apple Watch); silently abort
                return
            } catch {
                await MainActor.run { [weak self] in
                    self?.phase = .failed(error.localizedDescription)
                }
            }
        }
    }

    // MARK: - Idle Session Auto-Locker & Toast

    private func startIdleSessionTimer() {
        stopIdleSessionTimer()
        idleLockTimer = Timer.scheduledTimer(withTimeInterval: 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.vault.enforceIdleTimeout(self.settings.sessionTimeout.timeInterval) {
                    self.isSessionArmed = false
                    self.identities = []
                    self.stopIdleSessionTimer()
                }
            }
        }
    }

    private func stopIdleSessionTimer() {
        idleLockTimer?.invalidate()
        idleLockTimer = nil
    }

    public func showToast(_ text: String, isError: Bool) {
        toastTask?.cancel()
        toastMessage = text
        isToastError = isError
        toastTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 3_200_000_000)
            guard !Task.isCancelled else { return }
            self?.toastMessage = nil
        }
    }
}
