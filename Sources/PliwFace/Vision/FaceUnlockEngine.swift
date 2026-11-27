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
    @Published public private(set) var isKeychainUnlockVerified: Bool = false
    @Published public private(set) var lastUnlockLatencyMs: Int? = nil
    @Published public private(set) var enrollmentCompletedPoses: [EnrollmentPose] = []
    @Published public private(set) var isEnrollmentPoseAligned: Bool = false
    @Published public private(set) var enrollmentHeadPoint: CGPoint = .zero
    @Published public private(set) var enrollmentGuidancePose: EnrollmentPose = .center
    @Published public private(set) var toastMessage: String? = nil
    @Published public private(set) var isToastError: Bool = false
    @Published public private(set) var isScreenLocked: Bool = false
    @Published public private(set) var isTouchIDAuthInProgress: Bool = false

    public let camera = FastCameraCapture()
    public private(set) var embedder: any FaceEmbeddingEngine

    private let warper = FaceWarper()
    private let liveness = StreamingLivenessDetector()
    private let lockMonitor = LockScreenMonitor()
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
    private var isVerifyingKeychainAccess: Bool = false

    // Lock-screen multi-frame consensus scratch state (main actor only)
    private var lockScreenMatchStreak: Int = 0
    private var lockScreenMatchedIdentityID: UUID? = nil

    // Enrollment scratch state (main actor only)
    private var enrollmentTemplates: [EnrolledFaceTemplate] = []
    private var enrollmentCompletedSet: Set<EnrollmentPose> = []
    private var lastEnrollmentCaptureUptime: TimeInterval = 0
    private var enrollmentAlignedStreak: Int = 0
    private var enrollmentCandidatePose: EnrollmentPose?
    private var headPoseEstimator = HeadPoseEstimator()

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

    /// Automatically triggers/verifies macOS Keychain ACL ("Always Allow") on launch or after arming
    /// so the user doesn't have to manually click "Authorize & Test" inside Settings.
    public func autoVerifyKeychainAccessIfNeeded() {
        guard !isKeychainUnlockVerified, !isVerifyingKeychainAccess else { return }
        guard vault.isSessionArmed, vault.hasStoredPassword() else { return }
        isVerifyingKeychainAccess = true

        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.isVerifyingKeychainAccess = false }
            do {
                try await Task.detached(priority: .userInitiated) { [vault = self.vault] in
                    try vault.verifyKeychainPasswordAccess()
                }.value
                self.isKeychainUnlockVerified = true
            } catch {
                self.isKeychainUnlockVerified = false
            }
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
            isTouchIDAuthInProgress = true
            defer { isTouchIDAuthInProgress = false }
            do {
                try await vault.armSession(reason: "Authorize Pliw Face unlock session")
                isSessionArmed = vault.isSessionArmed
                reloadIdentities()
                startIdleSessionTimer()
                autoVerifyKeychainAccessIfNeeded()
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

    public func disarmSessionWithAuth() {
        Task { @MainActor in
            isTouchIDAuthInProgress = true
            defer { isTouchIDAuthInProgress = false }
            do {
                try await vault.authenticateOwner(reason: "Authenticate to lock Pliw Face session")
                disarmSession()
            } catch SessionVaultError.authenticationCancelled {
                showToast("Touch ID cancelled", isError: false)
            } catch {
                showToast(error.localizedDescription, isError: true)
            }
        }
    }

    public func setFaceUnlockEnabledWithAuth(_ enabled: Bool) {
        guard settings.isEnabled != enabled else { return }
        Task { @MainActor in
            isTouchIDAuthInProgress = true
            defer { isTouchIDAuthInProgress = false }
            do {
                let reason = enabled ? "Authenticate to enable Face Unlock" : "Authenticate to disable Face Unlock"
                try await vault.authenticateOwner(reason: reason)
                settings.isEnabled = enabled
            } catch SessionVaultError.authenticationCancelled {
                showToast("Touch ID cancelled", isError: false)
            } catch {
                showToast(error.localizedDescription, isError: true)
            }
        }
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
                    try vault.verifyKeychainPasswordAccess()
                }.value

                isKeychainUnlockVerified = true
                refreshSystemReadiness()
                startIdleSessionTimer()
                showToast("Login password encrypted & Keychain authorized", isError: false)
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
        if isScreenLocked && settings.unlockOnNotchHover {
            notchHoverTrigger.startListening()
        }
    }

    public func stopBackgroundMonitoring() {
        stopAnyActiveScan()
        lockMonitor.stop()
        notchHoverTrigger.stopListening()
        isScreenLocked = false
        stopIdleSessionTimer()
    }

    private func configureMonitors() {
        lockMonitor.onEvent = { [weak self] event in
            self?.handleLockEvent(event)
        }
        notchHoverTrigger.onNotchHovered = { [weak self] in
            self?.handleNotchHoverWhileLocked()
        }
    }

    private func handleLockEvent(_ event: LockEvent) {
        switch event {
        case .willSleep:
            stopAnyActiveScan()
            notchHoverTrigger.stopListening()

        case .locked:
            phase = .idle
            isScreenLocked = true
            if settings.unlockOnNotchHover {
                notchHoverTrigger.startListening()
            }

        case .wokeUp:
            let locked = LockScreenMonitor.isScreenActuallyLocked()
            isScreenLocked = locked
            if locked {
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
            notchHoverTrigger.stopListening()
            if runMode == .lockScreenUnlock {
                stopAnyActiveScan()
            } else if case .rejected = phase {
                phase = .idle
            } else if case .failed = phase {
                phase = .idle
            }
        }
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
            enrollmentCompletedSet = []
            lastEnrollmentCaptureUptime = 0
            enrollmentAlignedStreak = 0
            enrollmentCandidatePose = nil
            isEnrollmentPoseAligned = false
            enrollmentHeadPoint = .zero
            enrollmentGuidancePose = .center
            headPoseEstimator.reset()
            beginScan(mode: .enrollment(name: label, poseIndex: 0), timeout: nil)
        }
    }

    public func stopAnyActiveScan() {
        stopCameraPreservingPhase()
        phase = .idle
    }

    /// Stops camera and scan timers without resetting `phase` to `.idle` so the Notch HUD
    /// transitions seamlessly from `.scanning` -> `.unlocked` (green check) -> `.hidden` in one motion.
    private func stopCameraPreservingPhase() {
        scanTimeoutTask?.cancel()
        scanTimeoutTask = nil
        camera.stop()
        runMode = .idle
        isEnrollmentPoseAligned = false
        enrollmentAlignedStreak = 0
        enrollmentCandidatePose = nil
        enrollmentHeadPoint = .zero
        lockScreenMatchStreak = 0
        lockScreenMatchedIdentityID = nil
        headPoseEstimator.reset()
        frameGate.resetCounter()
        liveness.reset()
    }

    private func beginScan(mode: EngineRunMode, timeout: TimeInterval?) {
        runMode = mode
        phase = .warmingCamera
        scanStartUptime = ProcessInfo.processInfo.systemUptime
        lockScreenMatchStreak = 0
        lockScreenMatchedIdentityID = nil
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
                self.stopCameraPreservingPhase()
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
        let faceRectReq = VNDetectFaceRectanglesRequest()
        faceRectReq.revision = VNDetectFaceRectanglesRequestRevision3

        // Throttle rectangle/bezel detection to every 3rd frame to save CPU/GPU budget
        let localFrameNum = frameGate.nextFrameNumber()
        let isEnrolling: Bool
        if case .enrollment = mode { isEnrolling = true } else { isEnrolling = false }
        let runBezelCheck = !isEnrolling && (localFrameNum % 3 == 1)

        var requests: [VNRequest] = [landmarksReq, qualityReq]
        if isEnrolling {
            // Rev 3 FaceRectangles provides true continuous 3D yaw + pitch (Landmarks leaves pitch == nil on macOS)
            requests.append(faceRectReq)
        }
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
                if case .enrollment = self.runMode {
                    self.isEnrollmentPoseAligned = false
                    self.enrollmentAlignedStreak = 0
                    self.enrollmentCandidatePose = nil
                }
            }
            return
        }

        let rectFace = (faceRectReq.results ?? []).max(by: {
            ($0.boundingBox.width * $0.boundingBox.height) < ($1.boundingBox.width * $1.boundingBox.height)
        })

        // Early-exit frame gatekeeper: angled enrollment faces naturally score lower on frontal quality models
        let quality = (qualityReq.results?.first?.faceCaptureQuality) ?? 0.35
        let minFrameQuality: Float = isEnrolling ? 0.06 : 0.12
        guard quality >= minFrameQuality else {
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

        // 3. Extract fast zero-copy liveness cues & continuous 3D head pose
        let glareRatio = VectorMath.computeSpecularGlareRatio(
            pixelBuffer: pixelBuffer,
            normalizedVisionBox: face.boundingBox
        )
        let bezelDetected = runBezelCheck
            ? StreamingLivenessDetector.detectFramingBezel(rectangles: rectReq.results ?? [], faceBox: face.boundingBox)
            : false
        let geo = StreamingLivenessDetector.extractGeometryCues(from: face)
        let headPose = HeadPoseEstimator.extractRawPose(landmarksFace: face, rectanglesFace: rectFace)
        let yaw = headPose.yaw
        let pitch = headPose.pitch

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

        // 4. Match against enrolled templates + centroid consensus with Accelerate vDSP (< 0.02ms)
        let match = VectorMath.bestVerifiedMatch(
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
                frameNumber: localFrameNum,
                yaw: yaw,
                pitch: pitch
            )
        }
    }

    private func handleProcessedFrame(
        vector: [Float],
        quality: Float,
        inferMs: Double,
        sample: LivenessFrameSample,
        match: FaceMatchResult?,
        frameNumber: Int,
        yaw: Float,
        pitch: Float
    ) {
        guard runMode != .idle else { return }

        let livenessEval = liveness.recordAndEvaluate(sample, mode: settings.livenessMode)
        let elapsedMs = (ProcessInfo.processInfo.systemUptime - scanStartUptime) * 1000

        telemetry = ScanTelemetry(
            engineName: embedder.displayName,
            faceDetected: true,
            faceQuality: quality,
            bestIdentityName: match?.identity.name,
            similarityScore: match?.bestTemplateScore ?? 0,
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
                quality: quality,
                yaw: yaw,
                pitch: pitch
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
        quality: Float,
        yaw: Float,
        pitch: Float
    ) {
        let rawPose = HeadPoseSample(yaw: yaw, pitch: pitch)
        let relative = headPoseEstimator.update(raw: rawPose)
        let now = ProcessInfo.processInfo.systemUptime

        // Stage 1: Calibrate & capture neutral .center pose first
        if !enrollmentCompletedSet.contains(.center) {
            enrollmentGuidancePose = .center
            enrollmentHeadPoint = .zero

            let steadyCenter = quality >= 0.14 && abs(rawPose.yaw) <= 0.32
            isEnrollmentPoseAligned = steadyCenter
            guard steadyCenter else {
                enrollmentAlignedStreak = 0
                return
            }

            enrollmentAlignedStreak += 1
            guard enrollmentAlignedStreak >= 3 else { return }

            headPoseEstimator.calibrateCenter(headPoseEstimator.smoothed)
            captureEnrollmentPose(
                .center,
                name: name,
                vector: vector,
                quality: quality,
                now: now
            )
            return
        }

        // Stage 2: iOS Face ID-style free-flow 360° circle across the 8 remaining outer sectors in any order
        enrollmentHeadPoint = headPoseEstimator.normalizedPointer(for: relative)

        if let nextRemaining = EnrollmentPose.outerRingPoses.first(where: { !enrollmentCompletedSet.contains($0) }) {
            enrollmentGuidancePose = nextRemaining
        }

        guard let matchedSector = headPoseEstimator.matchedOuterPose(for: relative),
              !enrollmentCompletedSet.contains(matchedSector),
              quality >= 0.08 else {
            isEnrollmentPoseAligned = false
            enrollmentAlignedStreak = 0
            enrollmentCandidatePose = nil
            return
        }

        isEnrollmentPoseAligned = true
        if enrollmentCandidatePose == matchedSector {
            enrollmentAlignedStreak += 1
        } else {
            enrollmentCandidatePose = matchedSector
            enrollmentAlignedStreak = 1
        }

        guard enrollmentAlignedStreak >= 1, now - lastEnrollmentCaptureUptime >= 0.12 else { return }

        captureEnrollmentPose(
            matchedSector,
            name: name,
            vector: vector,
            quality: quality,
            now: now
        )
    }

    private func captureEnrollmentPose(
        _ pose: EnrollmentPose,
        name: String,
        vector: [Float],
        quality: Float,
        now: TimeInterval
    ) {
        enrollmentAlignedStreak = 0
        enrollmentCandidatePose = nil
        isEnrollmentPoseAligned = false
        enrollmentCompletedSet.insert(pose)
        enrollmentTemplates.append(EnrolledFaceTemplate(pose: pose, vector: vector, qualityScore: quality))
        enrollmentCompletedPoses.append(pose)
        lastEnrollmentCaptureUptime = now

        if settings.hapticFeedback {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }

        let capturedCount = enrollmentCompletedSet.count
        if capturedCount < EnrollmentPose.allCases.count {
            if let nextRemaining = EnrollmentPose.outerRingPoses.first(where: { !enrollmentCompletedSet.contains($0) }) {
                enrollmentGuidancePose = nextRemaining
            }
            runMode = .enrollment(name: name, poseIndex: capturedCount)
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
            } catch {
                stopAnyActiveScan()
                showToast("Failed to save face identity: \(error.localizedDescription)", isError: true)
            }
        }
    }

    /// Strict multi-frame + centroid consensus lock-screen unlock verification.
    private func handleLockScreenDecision(
        match: FaceMatchResult?,
        livenessEval: LivenessEvaluation,
        elapsedMs: Double
    ) {
        if case .spoofDetected(let reason) = livenessEval.verdict {
            stopCameraPreservingPhase()
            phase = .rejected("Blocked: \(reason)")
            return
        }

        let centroidFloor = max(0.30, settings.similarityThreshold - 0.07)
        guard let match,
              match.bestTemplateScore >= settings.similarityThreshold,
              match.centroidScore >= centroidFloor else {
            lockScreenMatchStreak = 0
            lockScreenMatchedIdentityID = nil
            return
        }

        if lockScreenMatchedIdentityID == match.identity.id {
            lockScreenMatchStreak += 1
        } else {
            lockScreenMatchedIdentityID = match.identity.id
            lockScreenMatchStreak = 1
        }

        let requiredConsensusFrames = (settings.livenessMode == .strict) ? 3 : 2
        guard lockScreenMatchStreak >= requiredConsensusFrames else {
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
        stopCameraPreservingPhase()

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
                    Task { @MainActor [weak self] in
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        guard let self, case .unlocked = self.phase else { return }
                        self.phase = .idle
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
