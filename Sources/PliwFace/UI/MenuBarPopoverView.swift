import AppKit
import SwiftUI

public struct MenuBarPopoverView: View {
    @ObservedObject var engine: FaceUnlockEngine = .shared
    public let onOpenSetup: () -> Void
    public let onPreviewHUD: () -> Void
    public let onQuit: () -> Void

    @State private var isActionHovered = false

    public init(
        onOpenSetup: @escaping () -> Void,
        onPreviewHUD: @escaping () -> Void = {},
        onQuit: @escaping () -> Void
    ) {
        self.onOpenSetup = onOpenSetup
        self.onPreviewHUD = onPreviewHUD
        self.onQuit = onQuit
    }

    public var body: some View {
        ZStack {
            backgroundLayer

            VStack(spacing: 12) {
                headerRow
                primarySessionButton

                if engine.isSessionArmed && !engine.isReadyForLockScreenUnlock {
                    Button(action: onOpenSetup) {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.circle.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(.orange)
                            Text("Finish setup in Settings")
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundStyle(.white.opacity(0.90))
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.45))
                        }
                        .padding(.horizontal, 11)
                        .padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.orange.opacity(0.12)))
                        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(Color.orange.opacity(0.25), lineWidth: 1))
                        .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }

                quickControlsCard

                if let toast = engine.toastMessage {
                    toastStrip(message: toast, isError: engine.isToastError)
                        .transition(.opacity)
                }

                Divider()
                    .background(.white.opacity(0.08))

                footerRow
            }
            .padding(15)
        }
        .frame(width: 310)
        .fixedSize(horizontal: true, vertical: true)
        .preferredColorScheme(.dark)
        .animation(.easeInOut(duration: 0.2), value: engine.isSessionArmed)
        .animation(.easeInOut(duration: 0.18), value: engine.toastMessage)
    }

    private var backgroundLayer: some View {
        ZStack {
            Color(red: 0.075, green: 0.085, blue: 0.115)
            RadialGradient(
                colors: [
                    engine.isReadyForLockScreenUnlock
                        ? Color(red: 0.06, green: 0.65, blue: 0.56).opacity(0.20)
                        : Color(red: 0.14, green: 0.32, blue: 0.62).opacity(0.16),
                    Color.clear,
                ],
                center: UnitPoint(x: 0.5, y: 0.22),
                startRadius: 8,
                endRadius: 170
            )
        }
    }

    private var headerRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "faceid")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(
                    engine.isReadyForLockScreenUnlock
                        ? Color(red: 0.30, green: 0.92, blue: 0.80)
                        : Color(red: 0.45, green: 0.74, blue: 1.0)
                )

            Text("Pliw Face")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.white)

            Spacer()

            statusPill
        }
    }

    private var statusPill: some View {
        let label: String
        let dotColor: Color
        let bgColor: Color

        if engine.isReadyForLockScreenUnlock {
            label = "ARMED"
            dotColor = Color(red: 0.30, green: 0.94, blue: 0.80)
            bgColor = Color.teal.opacity(0.22)
        } else if engine.isSessionArmed {
            label = "SETUP"
            dotColor = .orange
            bgColor = Color.orange.opacity(0.18)
        } else {
            label = "LOCKED"
            dotColor = .white.opacity(0.40)
            bgColor = .white.opacity(0.08)
        }

        return HStack(spacing: 5) {
            Circle()
                .fill(dotColor)
                .frame(width: 6, height: 6)
            Text(label)
                .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.90))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3.5)
        .background(bgColor)
        .clipShape(Capsule())
    }

    private var primarySessionButton: some View {
        Button(action: {
            if engine.isSessionArmed {
                engine.disarmSessionWithAuth()
            } else {
                engine.armSession()
            }
        }) {
            HStack(spacing: 8) {
                Image(systemName: engine.isSessionArmed ? "lock.open.fill" : "touchid")
                    .font(.system(size: 13.5, weight: .semibold))
                Text(engine.isSessionArmed ? "Lock Session" : "Arm Session with Touch ID")
                    .font(.system(size: 12.5, weight: .semibold))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9.5)
            .background(
                engine.isSessionArmed
                    ? LinearGradient(
                        colors: [Color.white.opacity(0.13), Color.white.opacity(0.08)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    : LinearGradient(
                        colors: [
                            Color(red: 0.08, green: 0.62, blue: 0.56),
                            Color(red: 0.05, green: 0.44, blue: 0.42),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
            )
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(.white.opacity(isActionHovered ? 0.28 : 0.14), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { isActionHovered = $0 }
        .accessibilityLabel(engine.isSessionArmed ? "Lock Pliw Face session" : "Arm Pliw Face session with Touch ID")
    }

    private var quickControlsCard: some View {
        VStack(spacing: 8) {
            HStack {
                Text("Face Unlock")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.82))
                Spacer()
                Toggle("", isOn: Binding(
                    get: { engine.settings.isEnabled },
                    set: { engine.setFaceUnlockEnabledWithAuth($0) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
            }

            HStack {
                Text("Notch HUD")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.82))
                Spacer()
                Button("Preview") {
                    onPreviewHUD()
                }
                .buttonStyle(.plain)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color(red: 0.30, green: 0.92, blue: 0.80))
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(.white.opacity(0.07))
                .clipShape(RoundedRectangle(cornerRadius: 5))

                Toggle("", isOn: $engine.settings.showNotchHUD)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
            }

            HStack(spacing: 4) {
                Text("Liveness")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.60))
                Spacer()
                ForEach(LivenessMode.allCases) { mode in
                    Button(action: { engine.settings.livenessMode = mode }) {
                        Text(mode.displayName)
                            .font(.system(size: 10, weight: engine.settings.livenessMode == mode ? .semibold : .medium))
                            .foregroundStyle(engine.settings.livenessMode == mode ? .white : .white.opacity(0.55))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3.5)
                            .background(
                                engine.settings.livenessMode == mode
                                    ? Color(red: 0.08, green: 0.56, blue: 0.54)
                                    : .white.opacity(0.06)
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 5))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(.white.opacity(0.045)))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(.white.opacity(0.08), lineWidth: 1))
    }

    private func toastStrip(message: String, isError: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: isError ? "exclamationmark.triangle.fill" : "checkmark.shield.fill")
                .font(.system(size: 10.5))
                .foregroundStyle(isError ? .orange : Color(red: 0.35, green: 0.92, blue: 0.80))
            Text(message)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.92))
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 7).fill(isError ? Color.orange.opacity(0.15) : Color.teal.opacity(0.16)))
    }

    private var footerRow: some View {
        HStack(spacing: 8) {
            Button(action: onOpenSetup) {
                HStack(spacing: 5) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 10.5, weight: .semibold))
                    Text("Setup")
                        .font(.system(size: 11, weight: .semibold))
                }
                .foregroundStyle(.white.opacity(0.88))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(.white.opacity(0.09))
                .clipShape(RoundedRectangle(cornerRadius: 6.5))
            }
            .buttonStyle(.plain)

            Spacer()

            Button(action: onQuit) {
                Text("Quit")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.58))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(.white.opacity(0.05))
                    .clipShape(RoundedRectangle(cornerRadius: 6.5))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Quit Pliw Face")
        }
    }
}
