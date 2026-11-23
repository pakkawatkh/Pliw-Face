import AppKit
import SwiftUI

public enum SetupTab: String, CaseIterable, Identifiable {
    case enroll = "Enrollment"
    case security = "Security"
    case lab = "Face Lab"

    public var id: String { rawValue }

    public var iconName: String {
        switch self {
        case .enroll: return "faceid"
        case .security: return "lock.shield"
        case .lab: return "waveform.path.ecg"
        }
    }
}

public struct SetupWindowView: View {
    @ObservedObject var engine: FaceUnlockEngine = .shared

    @State private var selectedTab: SetupTab = .enroll
    @State private var newIdentityName: String = "My Face"
    @State private var passwordInput: String = ""

    public init() {}

    public var body: some View {
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                topHeader
                    .padding(.top, 28)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 12)

                tabPicker
                    .padding(.horizontal, 20)
                    .padding(.bottom, 12)

                Divider().background(.white.opacity(0.08))

                ScrollView {
                    Group {
                        switch selectedTab {
                        case .enroll:
                            enrollmentTab
                        case .security:
                            securityTab
                        case .lab:
                            faceLabTab
                        }
                    }
                    .padding(20)
                }
            }

            if let toast = engine.toastMessage {
                HStack(spacing: 7) {
                    Image(systemName: engine.isToastError ? "exclamationmark.triangle.fill" : "checkmark.shield.fill")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(engine.isToastError ? .orange : Color(red: 0.32, green: 0.92, blue: 0.80))
                    Text(toast)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Color(red: 0.10, green: 0.13, blue: 0.19).opacity(0.96))
                .clipShape(Capsule())
                .overlay(Capsule().stroke(.white.opacity(0.16), lineWidth: 1))
                .shadow(color: .black.opacity(0.45), radius: 10, y: 4)
                .padding(.bottom, 16)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
                .allowsHitTesting(false)
            }
        }
        .frame(width: 540, height: 570)
        .background(Color(red: 0.07, green: 0.08, blue: 0.11))
        .preferredColorScheme(.dark)
        .animation(.easeInOut(duration: 0.2), value: engine.toastMessage)
        .onChange(of: selectedTab) { newTab in
            if newTab != .lab && engine.runMode == .diagnosticScan {
                engine.stopAnyActiveScan()
            }
            if newTab != .enroll, case .enrollment = engine.runMode {
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

    private var topHeader: some View {
        HStack {
            HStack(spacing: 9) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [Color(red: 0.08, green: 0.62, blue: 0.56), Color(red: 0.04, green: 0.38, blue: 0.42)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    Image(systemName: "faceid")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.white)
                }
                .frame(width: 32, height: 32)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Tiffy Face")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.white)
                    Text("On-device \(engine.embedder.displayName)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.50))
                }
            }

            Spacer()

            Text("v1.0.0")
                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.38))
        }
    }

    private var tabPicker: some View {
        HStack(spacing: 6) {
            ForEach(SetupTab.allCases) { tab in
                Button(action: { selectedTab = tab }) {
                    HStack(spacing: 6) {
                        Image(systemName: tab.iconName)
                            .font(.system(size: 11.5, weight: .semibold))
                        Text(tab.rawValue)
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundStyle(selectedTab == tab ? .white : .white.opacity(0.55))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
                    .background(
                        selectedTab == tab
                            ? Color(red: 0.08, green: 0.54, blue: 0.52).opacity(0.85)
                            : .white.opacity(0.06)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Tab 1: Enrollment

    private var enrollmentTab: some View {
        VStack(spacing: 16) {
            // Circular Face ID-style camera ring
            ZStack {
                Circle()
                    .fill(.white.opacity(0.04))
                    .frame(width: 196, height: 196)

                if case .enrollment = engine.runMode {
                    CameraPreviewNSView(session: engine.camera.session)
                        .frame(width: 176, height: 176)
                        .clipShape(Circle())
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "faceid")
                            .font(.system(size: 42, weight: .light))
                            .foregroundStyle(Color(red: 0.35, green: 0.88, blue: 0.80))
                        Text("5-Angle Capture")
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(.white.opacity(0.55))
                    }
                }

                // 5-angle progress ring
                let progress = Double(engine.enrollmentCompletedPoses.count) / Double(EnrollmentPose.allCases.count)
                Circle()
                    .stroke(.white.opacity(0.10), lineWidth: 5)
                    .frame(width: 190, height: 190)

                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(
                        Color(red: 0.25, green: 0.92, blue: 0.78),
                        style: StrokeStyle(lineWidth: 5, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .frame(width: 190, height: 190)
                    .animation(.easeOut(duration: 0.25), value: progress)
            }

            // Live instruction
            if case .enrollment(_, let poseIndex) = engine.runMode,
               poseIndex < EnrollmentPose.allCases.count {
                let pose = EnrollmentPose.allCases[poseIndex]
                VStack(spacing: 4) {
                    Text(pose.instruction)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color(red: 0.42, green: 0.96, blue: 0.86))
                    Text("Pose \(poseIndex + 1) of \(EnrollmentPose.allCases.count) • Quality \(Int(engine.telemetry.faceQuality * 100))%")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.56))
                }
            } else {
                Text("Frames are converted into encrypted 512-dim embeddings in RAM and immediately discarded.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.white.opacity(0.55))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
            }

            // Name & Start/Stop button
            HStack(spacing: 10) {
                TextField("Identity Name", text: $newIdentityName)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(.white.opacity(0.07))
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(.white.opacity(0.12), lineWidth: 1))

                if case .enrollment = engine.runMode {
                    Button(action: { engine.stopAnyActiveScan() }) {
                        Text("Cancel")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 7.5)
                            .background(Color.red.opacity(0.75))
                            .clipShape(RoundedRectangle(cornerRadius: 7))
                    }
                    .buttonStyle(.plain)
                } else {
                    Button(action: { engine.startEnrollment(name: newIdentityName) }) {
                        HStack(spacing: 5) {
                            Image(systemName: "plus.viewfinder")
                                .font(.system(size: 11.5, weight: .semibold))
                            Text("Enroll Face")
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 7.5)
                        .background(Color(red: 0.08, green: 0.58, blue: 0.54))
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                    }
                    .buttonStyle(.plain)
                }
            }

            // Enrolled identities list
            VStack(alignment: .leading, spacing: 8) {
                Text("Enrolled Identities")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.75))

                if !engine.isSessionArmed {
                    HStack {
                        Text("Arm session with Touch ID to view or edit encrypted face identities.")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.white.opacity(0.50))
                        Spacer()
                        Button("Arm Session") { engine.armSession() }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                    }
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 9).fill(.white.opacity(0.045)))
                } else if engine.identities.isEmpty {
                    Text("No faces enrolled yet. Click \"Enroll Face\" above to get started.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.white.opacity(0.48))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: 9).fill(.white.opacity(0.045)))
                } else {
                    ForEach(engine.identities) { identity in
                        HStack(spacing: 10) {
                            Image(systemName: "person.crop.circle.badge.checkmark")
                                .font(.system(size: 16))
                                .foregroundStyle(identity.isEnabled ? Color(red: 0.30, green: 0.92, blue: 0.80) : .white.opacity(0.35))

                            VStack(alignment: .leading, spacing: 2) {
                                Text(identity.name)
                                    .font(.system(size: 12.5, weight: .semibold))
                                    .foregroundStyle(.white)
                                Text("\(identity.templates.count) angles • \(identity.embeddingDimension)D")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.white.opacity(0.46))
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
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 9).fill(.white.opacity(0.05)))
                    }
                }
            }
        }
    }

    // MARK: - Tab 2: Security & Permissions

    private var securityTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionCard(title: "Permissions") {
                permissionRow(
                    title: "Camera",
                    subtitle: "Used only while scanning on Lock Screen or Enrollment",
                    granted: engine.cameraAccess.isAuthorized,
                    buttonTitle: "Grant",
                    action: { engine.requestCameraPermission() }
                )
                Divider().background(.white.opacity(0.07))
                permissionRow(
                    title: "Accessibility",
                    subtitle: "Required to submit your password on the macOS Lock Screen",
                    granted: engine.accessibilityTrusted,
                    buttonTitle: "Open Settings",
                    action: { engine.requestAccessibilityPermission() }
                )
            }

            sectionCard(title: "Mac Login Password (AES-256-GCM + Touch ID)") {
                VStack(alignment: .leading, spacing: 8) {
                    Text(
                        engine.hasStoredPassword
                            ? "A login password is encrypted and stored in your macOS Keychain."
                            : "Enter your Mac login password once. It is encrypted with a Touch-ID-gated AES-256 key."
                    )
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.58))

                    HStack(spacing: 8) {
                        SecureField("Mac login password", text: $passwordInput)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(.white.opacity(0.07))
                            .clipShape(RoundedRectangle(cornerRadius: 7))

                        Button(action: {
                            let value = passwordInput
                            passwordInput = ""
                            engine.saveMacPassword(value)
                        }) {
                            Text(engine.hasStoredPassword ? "Update" : "Save")
                                .font(.system(size: 11.5, weight: .semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 7)
                                .background(Color(red: 0.08, green: 0.56, blue: 0.54))
                                .clipShape(RoundedRectangle(cornerRadius: 7))
                        }
                        .buttonStyle(.plain)
                        .disabled(passwordInput.isEmpty)
                    }
                }
            }

            sectionCard(title: "Triggers & Auto-Lock") {
                VStack(spacing: 8) {
                    toggleLine("Unlock on Wake from Sleep", isOn: $engine.settings.unlockOnWake)
                    toggleLine("Unlock on Spacebar at Lock Screen", isOn: $engine.settings.unlockOnSpacebar)
                    toggleLine("Unlock Immediately on Lock", isOn: $engine.settings.unlockOnLock)
                    toggleLine("Trackpad Haptic Feedback", isOn: $engine.settings.hapticFeedback)

                    Divider().background(.white.opacity(0.07))

                    HStack {
                        Text("Auto-Lock Touch ID Session")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.white.opacity(0.78))
                        Spacer()
                        Picker("", selection: $engine.settings.sessionTimeout) {
                            ForEach(SessionTimeoutOption.allCases) { opt in
                                Text(opt.displayName).tag(opt)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 110)
                    }

                    HStack {
                        Text("Match Threshold: \(String(format: "%.2f", engine.settings.similarityThreshold))")
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.78))
                        Spacer()
                        Slider(value: $engine.settings.similarityThreshold, in: 0.35...0.75, step: 0.01)
                            .frame(width: 170)
                    }
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

    // MARK: - Tab 3: Live Face Lab (Diagnostics & Latency Benchmark)

    private var faceLabTab: some View {
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
                            .foregroundStyle(Color(red: 0.35, green: 0.88, blue: 0.80))
                        Text("Start Live Face Lab to benchmark Neural Engine latency & liveness cues")
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
                Text(engine.runMode == .diagnosticScan ? "Stop Live Test" : "Start Live Test Scan")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8.5)
                    .background(
                        engine.runMode == .diagnosticScan
                            ? Color.red.opacity(0.75)
                            : Color(red: 0.08, green: 0.56, blue: 0.54)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)

            sectionCard(title: "Real-Time Telemetry") {
                VStack(spacing: 6) {
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
    }

    private func livenessDescription(_ verdict: LivenessVerdict) -> String {
        switch verdict {
        case .pending: return "Analyzing..."
        case .live(let reason): return "LIVE — \(reason)"
        case .spoofDetected(let reason): return "SPOOF — \(reason)"
        }
    }

    // MARK: - Helpers

    private func sectionCard<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.white.opacity(0.72))
            VStack(alignment: .leading, spacing: 8) {
                content()
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white.opacity(0.045)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(.white.opacity(0.08), lineWidth: 1))
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
                    .foregroundStyle(Color(red: 0.30, green: 0.92, blue: 0.80))
            } else {
                Button(buttonTitle, action: action)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        }
    }

    private func toggleLine(_ title: String, isOn: Binding<Bool>) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 11.5))
                .foregroundStyle(.white.opacity(0.80))
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
