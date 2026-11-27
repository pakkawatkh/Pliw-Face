import AppKit
import ServiceManagement
import SwiftUI

public enum SetupTab: String, CaseIterable, Identifiable {
    case faceID = "Face ID"
    case triggers = "Notch"
    case security = "Security"

    public var id: String { rawValue }

    public var iconName: String {
        switch self {
        case .faceID: return "faceid"
        case .triggers: return "sparkles"
        case .security: return "lock.shield"
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
            if newTab != .faceID, case .enrollment = engine.runMode {
                engine.stopAnyActiveScan()
            }
            engine.refreshSystemReadiness()
        }
        .onDisappear {
            if case .enrollment = engine.runMode {
                engine.stopAnyActiveScan()
            }
        }
    }

    // MARK: - Native Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 34, height: 34)

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
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7.5)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(selectedTab == tab ? Color.white.opacity(0.12) : Color.clear)
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)

            Spacer()

            HStack(spacing: 6) {
                Circle()
                    .fill(engine.isReadyForLockScreenUnlock ? Self.iosGreen : .orange)
                    .frame(width: 7, height: 7)
                Text(engine.isReadyForLockScreenUnlock ? "Ready to Unlock" : "Setup Incomplete")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
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
            Text(selectedTab.rawValue)
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(.white)
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

                Text(engine.isSessionArmed ? "Session Armed" : "Touch ID Required")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.white)

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
                let completedSet = Set(engine.enrollmentCompletedPoses)
                let isEnrolling: Bool = {
                    if case .enrollment = engine.runMode { return true }
                    return false
                }()
                let centerCaptured = completedSet.contains(.center)

                ZStack {
                    // 36 radial Face ID ticks mapped spatially to each 22.5° outer head-turn sector
                    let activeTargetAngle: Double? = isEnrolling ? engine.enrollmentGuidancePose.directionAngleDegrees : nil
                    let liveHeadAngle: Double? = {
                        guard isEnrolling, centerCaptured else { return nil }
                        let pt = engine.enrollmentHeadPoint
                        guard hypot(pt.x, pt.y) >= 0.35 else { return nil }
                        var deg = atan2(pt.x, -pt.y) * 180.0 / .pi
                        if deg < 0 { deg += 360.0 }
                        return deg
                    }()

                    ForEach(0..<36, id: \.self) { idx in
                        let tickDeg = Double(idx) * 10.0
                        let sectorPose = EnrollmentPose.outerPose(forClockDegrees: tickDeg)
                        let completed = completedSet.contains(sectorPose)
                        let isLiveGlow: Bool = {
                            guard !completed, let headDeg = liveHeadAngle else { return false }
                            let diff = abs(((tickDeg - headDeg + 540).truncatingRemainder(dividingBy: 360)) - 180)
                            return diff <= 16.0
                        }()
                        let isTargetSegment: Bool = {
                            guard centerCaptured, !completed, let target = activeTargetAngle else { return false }
                            let diff = abs(((tickDeg - target + 540).truncatingRemainder(dividingBy: 360)) - 180)
                            return diff <= 12.0
                        }()
                        Capsule()
                            .fill(
                                completed
                                    ? Self.iosGreen
                                    : (isLiveGlow
                                        ? Color.white.opacity(0.92)
                                        : (isTargetSegment ? Self.iosTeal.opacity(0.75) : Color.white.opacity(0.14)))
                            )
                            .frame(
                                width: (completed || isLiveGlow) ? 3.2 : 2.6,
                                height: completed ? 13 : (isLiveGlow ? 12.5 : (isTargetSegment ? 10.5 : 8))
                            )
                            .offset(y: -86)
                            .rotationEffect(.degrees(tickDeg))
                    }
                    .animation(.easeOut(duration: 0.16), value: engine.enrollmentCompletedPoses.count)
                    .animation(.easeOut(duration: 0.12), value: engine.enrollmentHeadPoint)

                    if isEnrolling {
                        CameraPreviewNSView(session: engine.camera.session)
                            .frame(width: 148, height: 148)
                            .clipShape(Circle())
                            .overlay(
                                Circle()
                                    .stroke(
                                        engine.isEnrollmentPoseAligned ? Self.iosGreen.opacity(0.85) : Color.white.opacity(0.14),
                                        lineWidth: engine.isEnrollmentPoseAligned ? 2.2 : 1.2
                                    )
                            )
                    } else {
                        Circle()
                            .fill(.white.opacity(0.04))
                            .frame(width: 148, height: 148)
                            .overlay(
                                VStack(spacing: 6) {
                                    Image(systemName: "faceid")
                                        .font(.system(size: 36, weight: .light))
                                        .foregroundStyle(Self.iosGreen)
                                    Text("Setup")
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundStyle(.white.opacity(0.55))
                                }
                            )
                    }
                }
                .frame(height: 186)

                if isEnrolling {
                    let capturedCount = completedSet.count
                    let remainingOuter = EnrollmentPose.outerRingPoses.filter { !completedSet.contains($0) }
                    let headline: String = {
                        if !engine.telemetry.faceDetected {
                            return "Position your face in the circle"
                        }
                        if !centerCaptured {
                            return engine.isEnrollmentPoseAligned ? "Hold steady…" : EnrollmentPose.center.instruction
                        }
                        if remainingOuter.count > 3 {
                            return engine.isEnrollmentPoseAligned ? "Great — keep moving slowly" : "Move your head slowly in a circle"
                        }
                        return engine.isEnrollmentPoseAligned ? "Hold steady…" : engine.enrollmentGuidancePose.instruction
                    }()

                    VStack(spacing: 3) {
                        Text(headline)
                            .font(.system(size: 13.5, weight: .semibold))
                            .foregroundStyle(engine.isEnrollmentPoseAligned ? Self.iosGreen : .white)
                        Text("\(capturedCount) of \(EnrollmentPose.allCases.count) angles captured • Quality \(Int(engine.telemetry.faceQuality * 100))%")
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.54))
                    }
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

                            Text(identity.name)
                                .font(.system(size: 12.5, weight: .semibold))
                                .foregroundStyle(.white)

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
                    isOn: $engine.settings.showNotchHUD
                )

                Divider().background(.white.opacity(0.07))

                HStack {
                    Text("HUD Style")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.88))
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
                    Text("Preview Animation")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.88))
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
                    isOn: Binding(
                        get: { launchAtLogin },
                        set: { enabled in
                            engine.settings.launchAtLoginPreferred = enabled
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
                    isOn: $engine.settings.unlockOnWake
                )
                Divider().background(.white.opacity(0.07))
                toggleRow(
                    title: "Hover or Click Notch to Rescan",
                    isOn: $engine.settings.unlockOnNotchHover
                )
                Divider().background(.white.opacity(0.07))
                HStack {
                    Text("Scan Timeout: \(String(format: "%.1fs", engine.settings.scanTimeoutSeconds))")
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.88))
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
                    granted: engine.cameraAccess.isAuthorized,
                    buttonTitle: "Grant",
                    action: { engine.requestCameraPermission() }
                )
                Divider().background(.white.opacity(0.07))
                permissionRow(
                    title: "Accessibility",
                    granted: engine.accessibilityTrusted,
                    buttonTitle: "Open Settings",
                    action: { engine.requestAccessibilityPermission() }
                )
                Divider().background(.white.opacity(0.07))
                permissionRow(
                    title: "Keychain Auto-Fill Access",
                    granted: engine.isKeychainUnlockVerified,
                    buttonTitle: "Authorize & Test",
                    action: { engine.verifyAndAuthorizeKeychainAccess() }
                )
            }

            settingsGroup(title: "Mac Login Password") {
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
                    isOn: $engine.settings.autoArmOnLaunch
                )

                Divider().background(.white.opacity(0.07))

                HStack {
                    Text("Liveness Protection")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.88))
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

    // MARK: - Helpers

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
        granted: Bool,
        buttonTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
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

    private func toggleRow(title: String, isOn: Binding<Bool>) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.88))
            Spacer()
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
        }
    }
}
