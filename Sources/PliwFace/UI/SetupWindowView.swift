import AppKit
import ServiceManagement
import SwiftUI

public enum SetupTab: String, CaseIterable, Identifiable {
    case faceID = "Face ID"
    case triggers = "Notch & Triggers"
    case security = "Security"
    case diagnostics = "Diagnostics"

    public var id: String { rawValue }

    public var iconName: String {
        switch self {
        case .faceID: return "faceid"
        case .triggers: return "sparkles"
        case .security: return "lock.shield"
        case .diagnostics: return "waveform.path.ecg"
        }
    }

    public var subtitle: String {
        switch self {
        case .faceID: return "Enroll faces and manage unlock readiness"
        case .triggers: return "Dynamic Island HUD & lock-screen triggers"
        case .security: return "macOS permissions, password & anti-spoofing"
        case .diagnostics: return "Live Neural Engine & liveness telemetry"
        }
    }
}

public struct SetupWindowView: View {
    @ObservedObject var engine: FaceUnlockEngine = .shared

    public let onPreviewUnlockHUD: () -> Void
    public let onPreviewFailureHUD: () -> Void

    @State private var selectedTab: SetupTab = .faceID
    @State private var newIdentityName: String = "My Face"
    @State private var passwordInput: String = ""
    @State private var launchAtLogin: Bool = (SMAppService.mainApp.status == .enabled)

    public init(
        onPreviewUnlockHUD: @escaping () -> Void = {},
        onPreviewFailureHUD: @escaping () -> Void = {}
    ) {
        self.onPreviewUnlockHUD = onPreviewUnlockHUD
        self.onPreviewFailureHUD = onPreviewFailureHUD
    }

    private static let iosGreen = Color(red: 0.188, green: 0.820, blue: 0.345)
    private static let iosTeal = Color(red: 0.14, green: 0.72, blue: 0.65)

    public var body: some View {
        ZStack(alignment: .bottom) {
            HStack(spacing: 0) {
                sidebar
                Divider().background(.white.opacity(0.08))
                detailPane
            }

            if let toast = engine.toastMessage {
                HStack(spacing: 7) {
                    Image(systemName: engine.isToastError ? "exclamationmark.triangle.fill" : "checkmark.shield.fill")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(engine.isToastError ? .orange : Self.iosGreen)
                    Text(toast)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Color(red: 0.12, green: 0.13, blue: 0.16).opacity(0.96))
                .clipShape(Capsule())
                .overlay(Capsule().stroke(.white.opacity(0.16), lineWidth: 1))
                .shadow(color: .black.opacity(0.45), radius: 12, y: 4)
                .padding(.bottom, 16)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
                .allowsHitTesting(false)
            }
        }
        .frame(width: 680, height: 520)
        .background(Color(red: 0.08, green: 0.085, blue: 0.105))
        .preferredColorScheme(.dark)
        .animation(.easeInOut(duration: 0.2), value: engine.toastMessage)
        .onChange(of: selectedTab) { newTab in
            if newTab != .diagnostics && engine.runMode == .diagnosticScan {
                engine.stopAnyActiveScan()
            }
            if newTab != .faceID, case .enrollment = engine.runMode {
                engine.stopAnyActiveScan()
            }
            engine.refreshSystemReadiness()
        }
        .onDisappear {
            if engine.runMode == .diagnosticScan {
                engine.stopAnyActiveScan()
            }
            if case .enrollment = engine.runMode {
                engine.stopAnyActiveScan()
            }
        }
    }

    // MARK: - Native Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [Self.iosGreen.opacity(0.85), Self.iosTeal],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    Image(systemName: "faceid")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .frame(width: 30, height: 30)

                VStack(alignment: .leading, spacing: 1) {
                    Text("Pliw Face")
                        .font(.system(size: 13.5, weight: .bold))
                        .foregroundStyle(.white)
                    Text("v1.0.0")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.45))
                }
            }
            .padding(.top, 34)
            .padding(.horizontal, 14)
            .padding(.bottom, 18)

            VStack(spacing: 3) {
                ForEach(SetupTab.allCases) { tab in
                    Button(action: { selectedTab = tab }) {
                        HStack(spacing: 9) {
                            Image(systemName: tab.iconName)
                                .font(.system(size: 12.5, weight: .medium))
                                .foregroundStyle(selectedTab == tab ? .white : .white.opacity(0.60))
                                .frame(width: 18)

                            Text(tab.rawValue)
                                .font(.system(size: 12.5, weight: selectedTab == tab ? .semibold : .medium))
                                .foregroundStyle(selectedTab == tab ? .white : .white.opacity(0.76))

                            Spacer()
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7.5)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(selectedTab == tab ? Color.white.opacity(0.12) : Color.clear)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)

            Spacer()

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(engine.isReadyForLockScreenUnlock ? Self.iosGreen : .orange)
                        .frame(width: 7, height: 7)
                    Text(engine.isReadyForLockScreenUnlock ? "Ready to Unlock" : "Setup Incomplete")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.85))
                }
                Text(engine.embedder.displayName)
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.42))
                    .lineLimit(1)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(.white.opacity(0.04)))
            .padding(12)
        }
        .frame(width: 182)
        .background(Color.white.opacity(0.025))
    }

    // MARK: - Detail Pane

    private var detailPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text(selectedTab.rawValue)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(.white)
                Text(selectedTab.subtitle)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.white.opacity(0.50))
            }
            .padding(.top, 26)
            .padding(.horizontal, 22)
            .padding(.bottom, 14)

            Divider().background(.white.opacity(0.08))

            ScrollView {
                Group {
                    switch selectedTab {
                    case .faceID:
                        faceIDTab
                    case .triggers:
                        triggersTab
                    case .security:
                        securityTab
                    case .diagnostics:
                        diagnosticsTab
                    }
                }
                .padding(22)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Tab 1: Face ID (Enrollment & Readiness)

    private var faceIDTab: some View {
        VStack(alignment: .leading, spacing: 18) {
            // Readiness / Session Banner
            HStack(spacing: 12) {
                Image(systemName: engine.isSessionArmed ? "checkmark.shield.fill" : "touchid")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(engine.isSessionArmed ? Self.iosGreen : .orange)
                    .frame(width: 34, height: 34)
                    .background((engine.isSessionArmed ? Self.iosGreen : Color.orange).opacity(0.14))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(engine.isSessionArmed ? "Session Armed" : "Touch ID Required")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(.white)
                    Text(
                        engine.isSessionArmed
                            ? "Encrypted face profiles & login password are active in RAM."
                            : "Authorize once with Touch ID to unlock encrypted face profiles."
                    )
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.54))
                }

                Spacer()

                if engine.isSessionArmed {
                    Button("Lock") { engine.disarmSession() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                } else {
                    Button("Arm Session") { engine.armSession() }
                        .buttonStyle(.borderedProminent)
                        .tint(Self.iosGreen)
                        .controlSize(.small)
                }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(.white.opacity(0.045)))
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).stroke(.white.opacity(0.08), lineWidth: 1))

            // iPhone-style Circular Radial-Tick Enrollment
            VStack(spacing: 14) {
                let progress = Double(engine.enrollmentCompletedPoses.count) / Double(EnrollmentPose.allCases.count)

                ZStack {
                    // 36 radial Face ID ticks like iPhone Face ID setup
                    let activeTargetAngle: Double? = {
                        if case .enrollment(_, let poseIndex) = engine.runMode,
                           poseIndex < EnrollmentPose.allCases.count {
                            return EnrollmentPose.allCases[poseIndex].directionAngleDegrees
                        }
                        return nil
                    }()

                    ForEach(0..<36, id: \.self) { idx in
                        let fraction = Double(idx) / 36.0
                        let completed = fraction < progress
                        let tickDeg = Double(idx) * 10.0
                        let isTargetSegment: Bool = {
                            guard let target = activeTargetAngle else { return false }
                            let diff = abs(((tickDeg - target + 540).truncatingRemainder(dividingBy: 360)) - 180)
                            return diff <= 15.0
                        }()
                        Capsule()
                            .fill(
                                completed
                                    ? Self.iosGreen
                                    : (isTargetSegment ? Color.white.opacity(0.92) : Color.white.opacity(0.14))
                            )
                            .frame(width: isTargetSegment ? 3.2 : 2.6, height: (completed || isTargetSegment) ? 12 : 8)
                            .offset(y: -86)
                            .rotationEffect(.degrees(tickDeg))
                    }
                    .animation(.easeOut(duration: 0.22), value: progress)

                    if case .enrollment = engine.runMode {
                        CameraPreviewNSView(session: engine.camera.session)
                            .frame(width: 148, height: 148)
                            .clipShape(Circle())
                    } else {
                        Circle()
                            .fill(.white.opacity(0.04))
                            .frame(width: 148, height: 148)
                            .overlay(
                                VStack(spacing: 6) {
                                    Image(systemName: "faceid")
                                        .font(.system(size: 36, weight: .light))
                                        .foregroundStyle(Self.iosGreen)
                                    Text("9-Angle Setup")
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundStyle(.white.opacity(0.55))
                                }
                            )
                    }
                }
                .frame(height: 186)

                if case .enrollment(_, let poseIndex) = engine.runMode,
                   poseIndex < EnrollmentPose.allCases.count {
                    let pose = EnrollmentPose.allCases[poseIndex]
                    VStack(spacing: 3) {
                        Text(engine.isEnrollmentPoseAligned ? "Hold steady…" : pose.instruction)
                            .font(.system(size: 13.5, weight: .semibold))
                            .foregroundStyle(engine.isEnrollmentPoseAligned ? Self.iosGreen : .white)
                        Text("Pose \(poseIndex + 1) of \(EnrollmentPose.allCases.count) (\(pose.shortLabel)) • Quality \(Int(engine.telemetry.faceQuality * 100))%")
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.54))
                    }
                } else {
                    Text("Frames are processed in RAM and immediately discarded. Only encrypted 512D embeddings are saved.")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.50))
                        .multilineTextAlignment(.center)
                }

                HStack(spacing: 10) {
                    TextField("Identity Name", text: $newIdentityName)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(.white.opacity(0.07))
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                        .overlay(RoundedRectangle(cornerRadius: 7).stroke(.white.opacity(0.11), lineWidth: 1))

                    if case .enrollment = engine.runMode {
                        Button("Cancel") { engine.stopAnyActiveScan() }
                            .buttonStyle(.borderedProminent)
                            .tint(.red)
                    } else {
                        Button(action: { engine.startEnrollment(name: newIdentityName) }) {
                            Label("Set Up Face ID", systemImage: "plus.viewfinder")
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Self.iosTeal)
                    }
                }
            }
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(0.035)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(.white.opacity(0.08), lineWidth: 1))

            // Enrolled Identities
            settingsGroup(title: "Enrolled Faces") {
                if !engine.isSessionArmed {
                    Text("Arm session above to view or manage enrolled faces.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.white.opacity(0.48))
                        .padding(.vertical, 4)
                } else if engine.identities.isEmpty {
                    Text("No faces enrolled yet. Click \"Set Up Face ID\" above.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.white.opacity(0.48))
                        .padding(.vertical, 4)
                } else {
                    ForEach(Array(engine.identities.enumerated()), id: \.element.id) { idx, identity in
                        if idx > 0 { Divider().background(.white.opacity(0.07)) }
                        HStack(spacing: 10) {
                            Image(systemName: "person.crop.circle.badge.checkmark")
                                .font(.system(size: 16))
                                .foregroundStyle(identity.isEnabled ? Self.iosGreen : .white.opacity(0.35))

                            VStack(alignment: .leading, spacing: 1.5) {
                                Text(identity.name)
                                    .font(.system(size: 12.5, weight: .semibold))
                                    .foregroundStyle(.white)
                                Text("\(identity.templates.count) angles • \(identity.embeddingDimension)D")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.white.opacity(0.45))
                            }

                            Spacer()

                            Toggle("", isOn: Binding(
                                get: { identity.isEnabled },
                                set: { _ in engine.toggleIdentityEnabled(identity.id) }
                            ))
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.mini)

                            Button(action: { engine.deleteIdentity(identity.id) }) {
                                Image(systemName: "trash")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.white.opacity(0.50))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Delete \(identity.name)")
                        }
                    }
                }
            }
        }
    }

    // MARK: - Tab 2: Notch & Triggers

    private var triggersTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            settingsGroup(title: "Dynamic Island / Notch HUD") {
                toggleRow(
                    title: "Show Notch HUD Animation",
                    subtitle: "Seamless pitch-black HUD blended into the MacBook notch",
                    isOn: $engine.settings.showNotchHUD
                )

                Divider().background(.white.opacity(0.07))

                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("HUD Style")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.white.opacity(0.88))
                        Text(engine.settings.hudStyle.summary)
                            .font(.system(size: 10.5))
                            .foregroundStyle(.white.opacity(0.48))
                    }
                    Spacer()
                    Picker("", selection: $engine.settings.hudStyle) {
                        ForEach(NotchHUDStyle.allCases) { style in
                            Text(style.displayName).tag(style)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 210)
                }

                Divider().background(.white.opacity(0.07))

                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Preview Animation")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.white.opacity(0.88))
                        Text("Test the selected HUD style right at your notch")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.white.opacity(0.48))
                    }
                    Spacer()
                    Button("Preview Unlock") { onPreviewUnlockHUD() }
                        .buttonStyle(.borderedProminent)
                        .tint(Self.iosGreen)
                        .controlSize(.small)
                    Button("Preview Retry") { onPreviewFailureHUD() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }

            settingsGroup(title: "Startup & Lock Screen Triggers") {
                toggleRow(
                    title: "Launch at Login",
                    subtitle: "Start Pliw Face automatically whenever you log in to your Mac",
                    isOn: Binding(
                        get: { launchAtLogin },
                        set: { enabled in
                            do {
                                if enabled {
                                    try SMAppService.mainApp.register()
                                } else {
                                    try SMAppService.mainApp.unregister()
                                }
                                launchAtLogin = (SMAppService.mainApp.status == .enabled)
                            } catch {
                                engine.showToast("Launch at Login failed: \(error.localizedDescription)", isError: true)
                                launchAtLogin = (SMAppService.mainApp.status == .enabled)
                            }
                        }
                    )
                )
                Divider().background(.white.opacity(0.07))
                toggleRow(
                    title: "Unlock on Wake from Sleep",
                    subtitle: "Automatically scan when opening the lid or waking the display",
                    isOn: $engine.settings.unlockOnWake
                )
                Divider().background(.white.opacity(0.07))
                toggleRow(
                    title: "Hover or Click Notch to Rescan",
                    subtitle: "Move the cursor onto or click the notch after a failed scan to retry",
                    isOn: $engine.settings.unlockOnNotchHover
                )
                Divider().background(.white.opacity(0.07))
                HStack {
                    VStack(alignment: .leading, spacing: 1.5) {
                        Text("Scan Timeout: \(String(format: "%.1fs", engine.settings.scanTimeoutSeconds))")
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.88))
                        Text("Stop camera and show failed state if no face matches in time")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.white.opacity(0.48))
                    }
                    Spacer()
                    Slider(value: $engine.settings.scanTimeoutSeconds, in: 1.5...10.0, step: 0.5)
                        .frame(width: 155)
                }
            }
        }
    }

    // MARK: - Tab 3: Security & Permissions

    private var securityTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            settingsGroup(title: "macOS Permissions") {
                permissionRow(
                    title: "Camera",
                    subtitle: "Active only during Lock Screen unlock or enrollment",
                    granted: engine.cameraAccess.isAuthorized,
                    buttonTitle: "Grant",
                    action: { engine.requestCameraPermission() }
                )
                Divider().background(.white.opacity(0.07))
                permissionRow(
                    title: "Accessibility",
                    subtitle: "Submits your encrypted password on the Lock Screen",
                    granted: engine.accessibilityTrusted,
                    buttonTitle: "Open Settings",
                    action: { engine.requestAccessibilityPermission() }
                )
                Divider().background(.white.opacity(0.07))
                permissionRow(
                    title: "Keychain Auto-Fill Access",
                    subtitle: "Pre-authorize macOS Keychain ('Always Allow') so Lock Screen unlock never stalls",
                    granted: engine.isKeychainUnlockVerified,
                    buttonTitle: "Authorize & Test",
                    action: { engine.verifyAndAuthorizeKeychainAccess() }
                )
            }

            settingsGroup(title: "Mac Login Password (AES-256-GCM + Touch ID)") {
                Text(
                    engine.hasStoredPassword
                        ? "Your login password is encrypted in the macOS Keychain."
                        : "Enter your Mac login password once to encrypt it with Touch ID."
                )
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.56))

                HStack(spacing: 8) {
                    SecureField("Mac login password", text: $passwordInput)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(.white.opacity(0.07))
                        .clipShape(RoundedRectangle(cornerRadius: 7))

                    Button(engine.hasStoredPassword ? "Update" : "Save") {
                        let value = passwordInput
                        passwordInput = ""
                        engine.saveMacPassword(value)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Self.iosTeal)
                    .disabled(passwordInput.isEmpty)
                }
            }

            settingsGroup(title: "Anti-Spoofing & Session") {
                toggleRow(
                    title: "Auto-Arm Session on Launch",
                    subtitle: "Load encrypted face profiles automatically when Pliw Face starts",
                    isOn: $engine.settings.autoArmOnLaunch
                )

                Divider().background(.white.opacity(0.07))

                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Liveness Protection")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.white.opacity(0.88))
                        Text(engine.settings.livenessMode.summary)
                            .font(.system(size: 10.5))
                            .foregroundStyle(.white.opacity(0.48))
                    }
                    Spacer()
                    Picker("", selection: $engine.settings.livenessMode) {
                        ForEach(LivenessMode.allCases) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 190)
                }

                Divider().background(.white.opacity(0.07))

                HStack {
                    Text("Auto-Lock Touch ID Session")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.84))
                    Spacer()
                    Picker("", selection: $engine.settings.sessionTimeout) {
                        ForEach(SessionTimeoutOption.allCases) { opt in
                            Text(opt.displayName).tag(opt)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 110)
                }

                Divider().background(.white.opacity(0.07))

                HStack {
                    Text("Match Threshold: \(String(format: "%.2f", engine.settings.similarityThreshold))")
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.82))
                    Spacer()
                    Slider(value: $engine.settings.similarityThreshold, in: 0.35...0.75, step: 0.01)
                        .frame(width: 180)
                }
            }

            HStack {
                Spacer()
                Button(role: .destructive, action: { engine.deleteStoredCredentialsAndFaces() }) {
                    Text("Wipe All Stored Credentials & Faces")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.red.opacity(0.88))
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Tab 4: Diagnostics

    private var diagnosticsTab: some View {
        VStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.white.opacity(0.04))
                    .frame(height: 185)

                if engine.runMode == .diagnosticScan {
                    CameraPreviewNSView(session: engine.camera.session)
                        .frame(height: 185)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "waveform.path.ecg")
                            .font(.system(size: 30, weight: .light))
                            .foregroundStyle(Self.iosGreen)
                        Text("Start Live Diagnostics to benchmark Neural Engine latency & liveness")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.white.opacity(0.55))
                    }
                }
            }

            Button(action: {
                if engine.runMode == .diagnosticScan {
                    engine.stopAnyActiveScan()
                } else {
                    engine.startDiagnosticScan()
                }
            }) {
                Text(engine.runMode == .diagnosticScan ? "Stop Live Scan" : "Start Live Diagnostic Scan")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8.5)
                    .background(engine.runMode == .diagnosticScan ? Color.red.opacity(0.80) : Self.iosTeal)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)

            settingsGroup(title: "Real-Time Telemetry") {
                metricRow("Engine", engine.telemetry.engineName)
                metricRow("Inference Time", String(format: "%.2f ms", engine.telemetry.inferenceMs))
                metricRow(
                    "Best Match",
                    engine.telemetry.bestIdentityName.map { "\($0) (\(String(format: "%.3f", engine.telemetry.similarityScore)))" } ?? "—"
                )
                metricRow("Face Quality", String(format: "%.0f%%", engine.telemetry.faceQuality * 100))
                metricRow("Liveness Verdict", livenessDescription(engine.telemetry.livenessVerdict))
                metricRow(
                    "Cues (Glare / Bezel / Blink / 3D)",
                    String(
                        format: "%.0f%% / %@ / %@ / %.3f",
                        engine.telemetry.glareRatio * 100,
                        engine.telemetry.bezelDetected ? "YES" : "no",
                        engine.telemetry.blinkDetected ? "YES" : "no",
                        engine.telemetry.parallaxScore
                    )
                )
            }
        }
    }

    // MARK: - Helpers

    private func livenessDescription(_ verdict: LivenessVerdict) -> String {
        switch verdict {
        case .pending: return "Analyzing..."
        case .live(let reason): return "LIVE — \(reason)"
        case .spoofDetected(let reason): return "SPOOF — \(reason)"
        }
    }

    private func settingsGroup<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title.uppercased())
                .font(.system(size: 10.5, weight: .semibold))
                .tracking(0.5)
                .foregroundStyle(.white.opacity(0.48))
                .padding(.horizontal, 4)

            VStack(alignment: .leading, spacing: 9) {
                content()
            }
            .padding(13)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(.white.opacity(0.045)))
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).stroke(.white.opacity(0.08), lineWidth: 1))
        }
    }

    private func permissionRow(
        title: String,
        subtitle: String,
        granted: Bool,
        buttonTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                Text(subtitle)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.white.opacity(0.50))
            }
            Spacer()
            if granted {
                Label("Granted", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Self.iosGreen)
            } else {
                Button(buttonTitle, action: action)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        }
    }

    private func toggleRow(title: String, subtitle: String, isOn: Binding<Bool>) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 1.5) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.88))
                Text(subtitle)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.white.opacity(0.48))
            }
            Spacer()
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
        }
    }

    private func metricRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.52))
            Spacer()
            Text(value)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.92))
        }
    }
}
