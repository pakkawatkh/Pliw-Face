import AppKit
import SwiftUI

public enum NotchHUDDisplayState: Equatable, Sendable {
    case hidden
    case lockedIdle
    case scanning(faceDetected: Bool, quality: Float)
    case unlocked(identityName: String, latencyMs: Int)
    case rejected(reason: String, isSpoof: Bool)

    public var isHidden: Bool {
        if case .hidden = self { return true }
        return false
    }
}

public struct NotchHUDGeometry: Equatable, Sendable {
    public let hasHardwareNotch: Bool
    public let notchWidth: CGFloat
    public let notchHeight: CGFloat
    public let panelFrame: CGRect

    public static let defaultPanelSize = CGSize(width: 340, height: 172)

    public init(
        hasHardwareNotch: Bool,
        notchWidth: CGFloat,
        notchHeight: CGFloat,
        panelFrame: CGRect
    ) {
        self.hasHardwareNotch = hasHardwareNotch
        self.notchWidth = notchWidth
        self.notchHeight = notchHeight
        self.panelFrame = panelFrame
    }

    /// Pure geometry calculator for both notched MacBooks and non-notched displays.
    public static func compute(
        screenFrame: CGRect,
        visibleFrame: CGRect,
        safeTop: CGFloat,
        leftAuxWidth: CGFloat,
        rightAuxWidth: CGFloat,
        panelSize: CGSize = defaultPanelSize
    ) -> NotchHUDGeometry {
        let hasNotch = safeTop > 0
        let rawNotchWidth = hasNotch ? max(0, screenFrame.width - leftAuxWidth - rightAuxWidth) : 120
        let notchWidth = hasNotch ? max(150, min(260, rawNotchWidth > 0 ? rawNotchWidth : 186)) : 120
        let notchHeight = hasNotch ? max(28, min(46, safeTop)) : 30

        let x = round(screenFrame.midX - panelSize.width * 0.5)
        let y: CGFloat
        if hasNotch {
            y = round(screenFrame.maxY - panelSize.height)
        } else {
            let topAnchor = min(visibleFrame.maxY, screenFrame.maxY - 26)
            y = round(topAnchor - 8 - panelSize.height)
        }

        return NotchHUDGeometry(
            hasHardwareNotch: hasNotch,
            notchWidth: notchWidth,
            notchHeight: notchHeight,
            panelFrame: CGRect(origin: CGPoint(x: x, y: y), size: panelSize)
        )
    }

    @MainActor
    public static func current(for screen: NSScreen? = NSScreen.main ?? NSScreen.screens.first) -> NotchHUDGeometry {
        guard let screen else {
            return compute(
                screenFrame: CGRect(x: 0, y: 0, width: 1440, height: 900),
                visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 875),
                safeTop: 0,
                leftAuxWidth: 0,
                rightAuxWidth: 0
            )
        }
        let safeTop = screen.safeAreaInsets.top
        let leftW = screen.auxiliaryTopLeftArea?.width ?? 0
        let rightW = screen.auxiliaryTopRightArea?.width ?? 0
        return compute(
            screenFrame: screen.frame,
            visibleFrame: screen.visibleFrame,
            safeTop: safeTop,
            leftAuxWidth: leftW,
            rightAuxWidth: rightW
        )
    }
}

@MainActor
public final class NotchHUDModel: ObservableObject {
    @Published public var state: NotchHUDDisplayState = .hidden
    @Published public var style: NotchHUDStyle = .notchWings
    @Published public var geometry: NotchHUDGeometry = .current()
}

/// Top-flush notch silhouette using continuous Cubic Bezier curves (Apple squircle feel)
/// for liquid-smooth concave top ears and organic bottom corners.
private struct NotchSilhouetteShape: Shape {
    var topEarRadius: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topEarRadius, bottomRadius) }
        set {
            topEarRadius = newValue.first
            bottomRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let ear = min(topEarRadius, rect.width * 0.14)
        let br = min(bottomRadius, rect.height * 0.52, (rect.width - ear * 2) * 0.48)
        let kEar: CGFloat = 0.62
        let kBot: CGFloat = 0.60

        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))

        // Right concave ear (liquid cubic curve into side wall)
        p.addCurve(
            to: CGPoint(x: rect.maxX - ear, y: rect.minY + ear),
            control1: CGPoint(x: rect.maxX - ear * kEar, y: rect.minY),
            control2: CGPoint(x: rect.maxX - ear, y: rect.minY + ear * (1 - kEar))
        )

        p.addLine(to: CGPoint(x: rect.maxX - ear, y: rect.maxY - br))

        // Bottom-right Apple squircle corner
        p.addCurve(
            to: CGPoint(x: rect.maxX - ear - br, y: rect.maxY),
            control1: CGPoint(x: rect.maxX - ear, y: rect.maxY - br * (1 - kBot)),
            control2: CGPoint(x: rect.maxX - ear - br * (1 - kBot), y: rect.maxY)
        )

        p.addLine(to: CGPoint(x: rect.minX + ear + br, y: rect.maxY))

        // Bottom-left Apple squircle corner
        p.addCurve(
            to: CGPoint(x: rect.minX + ear, y: rect.maxY - br),
            control1: CGPoint(x: rect.minX + ear + br * (1 - kBot), y: rect.maxY),
            control2: CGPoint(x: rect.minX + ear, y: rect.maxY - br * (1 - kBot))
        )

        p.addLine(to: CGPoint(x: rect.minX + ear, y: rect.minY + ear))

        // Left concave ear (liquid cubic curve into top bezel)
        p.addCurve(
            to: CGPoint(x: rect.minX, y: rect.minY),
            control1: CGPoint(x: rect.minX + ear, y: rect.minY + ear * (1 - kEar)),
            control2: CGPoint(x: rect.minX + ear * kEar, y: rect.minY)
        )

        p.closeSubpath()
        return p
    }
}

/// Classic iOS Face ID double-shake effect on failure.
private struct FaceIDShakeEffect: GeometryEffect {
    var trigger: CGFloat

    var animatableData: CGFloat {
        get { trigger }
        set { trigger = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        let decay = max(0, 1 - trigger)
        let offset = sin(trigger * .pi * 4.5) * 9 * decay
        return ProjectionTransform(CGAffineTransform(translationX: offset, y: 0))
    }
}

public struct NotchHUDView: View {
    @ObservedObject var model: NotchHUDModel

    @State private var ringProgress: CGFloat = 0
    @State private var checkProgress: CGFloat = 0
    @State private var checkScale: CGFloat = 0.72
    @State private var shakeTrigger: CGFloat = 0

    public init(model: NotchHUDModel) {
        self.model = model
    }

    private static let iosGreen = Color(red: 0.188, green: 0.820, blue: 0.345) // #30D158
    private static let iosRed = Color(red: 1.000, green: 0.271, blue: 0.227)   // #FF453A
    private static let iosAmber = Color(red: 1.000, green: 0.624, blue: 0.039) // #FF9F0A

    private var isActiveState: Bool {
        switch model.state {
        case .scanning, .unlocked, .rejected:
            return true
        case .hidden, .lockedIdle:
            return false
        }
    }

    private var isVisible: Bool {
        !model.state.isHidden
    }

    /// In Dynamic Island mode, `.lockedIdle` stays visually collapsed behind the hardware notch (opacity 0)
    /// so `.rejected` -> `.lockedIdle` retracts identically to `.unlocked` -> `.hidden`.
    private var isVisuallyVisible: Bool {
        switch model.style {
        case .notchWings:
            return isVisible
        case .dynamicIsland:
            return isActiveState
        }
    }

    private var statusAccent: Color {
        switch model.state {
        case .hidden, .lockedIdle:
            return .white.opacity(0.75)
        case .scanning(let faceDetected, _):
            return faceDetected ? Self.iosGreen : .white
        case .unlocked:
            return Self.iosGreen
        case .rejected(_, let isSpoof):
            return isSpoof ? Self.iosAmber : Self.iosRed
        }
    }

    // MARK: - Style-Specific Pure Dimensions

    private var topEarRadius: CGFloat {
        switch model.style {
        case .notchWings:
            return isVisible ? 10 : 0
        case .dynamicIsland:
            return isActiveState ? 14 : 0
        }
    }

    private var hudWidth: CGFloat {
        let hasNotch = model.geometry.hasHardwareNotch
        let baseW = model.geometry.notchWidth
        // Compensate for both concave top ears so vertical walls align 1:1 with the physical MacBook notch
        let earComp = hasNotch ? (topEarRadius * 2) : 0

        switch model.style {
        case .notchWings:
            switch model.state {
            case .hidden:
                return hasNotch ? max(0, baseW - 2) : 110
            case .lockedIdle:
                return hasNotch ? (baseW + 64 + earComp) : 132
            case .scanning, .unlocked, .rejected:
                return hasNotch ? (baseW + 96 + earComp) : 168
            }

        case .dynamicIsland:
            switch model.state {
            case .hidden, .lockedIdle:
                return hasNotch ? max(0, baseW - 2) : 110
            case .scanning, .unlocked, .rejected:
                return hasNotch ? (baseW + 56 + earComp) : 210
            }
        }
    }

    private var hudHeight: CGFloat {
        let hasNotch = model.geometry.hasHardwareNotch
        let baseH = model.geometry.notchHeight

        switch model.style {
        case .notchWings:
            switch model.state {
            case .hidden:
                return hasNotch ? max(0, baseH - 2) : 30
            default:
                return hasNotch ? baseH : 36
            }

        case .dynamicIsland:
            switch model.state {
            case .hidden, .lockedIdle:
                return hasNotch ? max(0, baseH - 2) : 30
            case .scanning, .unlocked, .rejected:
                return hasNotch ? (baseH + 92) : 136
            }
        }
    }

    private var bottomCornerRadius: CGFloat {
        switch model.style {
        case .notchWings:
            return model.geometry.hasHardwareNotch ? (isVisible ? 12 : 8) : 18
        case .dynamicIsland:
            return isActiveState ? 34 : (model.geometry.hasHardwareNotch ? 8 : 16)
        }
    }

    public var body: some View {
        ZStack(alignment: .top) {
            Color.clear

            hudContainer
                .frame(width: hudWidth, height: hudHeight)
                .modifier(FaceIDShakeEffect(trigger: shakeTrigger))
                .opacity(isVisuallyVisible ? 1 : 0)
                .scaleEffect(isVisuallyVisible || model.geometry.hasHardwareNotch ? 1.0 : 0.84, anchor: .top)
                .animation(.spring(response: 0.44, dampingFraction: 0.84), value: model.state)
                .animation(.spring(response: 0.38, dampingFraction: 0.84), value: model.style)
        }
        .frame(
            width: NotchHUDGeometry.defaultPanelSize.width,
            height: NotchHUDGeometry.defaultPanelSize.height,
            alignment: .top
        )
        .onChange(of: model.state) { newState in
            switch newState {
            case .unlocked:
                ringProgress = 0
                checkProgress = 0
                checkScale = 0.72
                withAnimation(.easeInOut(duration: 0.24)) {
                    ringProgress = 1
                }
                withAnimation(.spring(response: 0.28, dampingFraction: 0.62).delay(0.14)) {
                    checkProgress = 1
                    checkScale = 1.0
                }
            case .rejected:
                ringProgress = 0
                checkProgress = 0
                shakeTrigger = 0
                withAnimation(.linear(duration: 0.40)) {
                    shakeTrigger = 1
                }
            default:
                ringProgress = 0
                checkProgress = 0
                checkScale = 0.72
            }
        }
    }

    @ViewBuilder
    private var hudContainer: some View {
        if model.geometry.hasHardwareNotch {
            let shape = NotchSilhouetteShape(
                topEarRadius: topEarRadius,
                bottomRadius: bottomCornerRadius
            )
            // Pure matte black (#000000) with clipShape so inner icons retract seamlessly inside the notch.
            ZStack(alignment: .top) {
                shape.fill(Color.black)
                activeStyleContent
            }
            .clipShape(shape)
            .shadow(
                color: (model.style == .dynamicIsland && isActiveState) ? .black.opacity(0.38) : .clear,
                radius: 12,
                y: 5
            )
        } else {
            let shape = RoundedRectangle(cornerRadius: bottomCornerRadius, style: .continuous)
            ZStack(alignment: .top) {
                shape.fill(Color.black)
                activeStyleContent
            }
            .clipShape(shape)
            .shadow(color: .black.opacity(0.45), radius: 14, y: 6)
        }
    }

    @ViewBuilder
    private var activeStyleContent: some View {
        switch model.style {
        case .notchWings:
            notchWingsContent
        case .dynamicIsland:
            dynamicIslandContent
        }
    }

    // MARK: - Style 1: Seamless Horizontal Notch Wings (Exact Notch Height)

    @ViewBuilder
    private var notchWingsContent: some View {
        if isVisible {
            HStack(spacing: 0) {
                // Left wing: Padlock icon
                wingLockIcon
                    .frame(width: model.geometry.hasHardwareNotch ? 36 : 32)

                Spacer(minLength: 0)

                // Right wing: Compact animated Face ID / Check / X
                compactWingStatusGlyph
                    .frame(width: model.geometry.hasHardwareNotch ? 36 : 32)
            }
            .padding(.horizontal, model.geometry.hasHardwareNotch ? 12 : 14)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .transition(.opacity)
        }
    }

    @ViewBuilder
    private var wingLockIcon: some View {
        switch model.state {
        case .unlocked:
            Image(systemName: "lock.open.fill")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(Self.iosGreen)
        case .rejected:
            Image(systemName: "lock.fill")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(statusAccent)
        case .lockedIdle:
            Image(systemName: "lock.fill")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.75))
        default:
            Image(systemName: "lock.fill")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(.white.opacity(0.92))
        }
    }

    @ViewBuilder
    private var compactWingStatusGlyph: some View {
        switch model.state {
        case .lockedIdle:
            Image(systemName: "faceid")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.55))

        case .scanning(let faceDetected, _):
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
                let t = timeline.date.timeIntervalSinceReferenceDate
                let pulse = 0.90 + 0.10 * sin(t * 4.5)
                let yawDeg = sin(t * 2.4) * (faceDetected ? 6.0 : 16.0)
                Image(systemName: "faceid")
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(faceDetected ? Self.iosGreen : .white)
                    .scaleEffect(pulse)
                    .rotation3DEffect(.degrees(yawDeg), axis: (x: 0, y: 1, z: 0))
            }

        case .unlocked:
            ZStack {
                Circle()
                    .trim(from: 0, to: ringProgress)
                    .stroke(Self.iosGreen, style: StrokeStyle(lineWidth: 2.0, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .frame(width: 18, height: 18)

                CheckmarkShape()
                    .trim(from: 0, to: checkProgress)
                    .stroke(Self.iosGreen, style: StrokeStyle(lineWidth: 2.0, lineCap: .round, lineJoin: .round))
                    .frame(width: 9, height: 9)
                    .scaleEffect(checkScale)
            }

        case .rejected(_, let isSpoof):
            Image(systemName: isSpoof ? "shield.slash.fill" : "xmark.circle.fill")
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(statusAccent)

        case .hidden:
            EmptyView()
        }
    }

    // MARK: - Style 2: Pure iPhone Dynamic Island Squircle Drop (No Side Wings)

    @ViewBuilder
    private var dynamicIslandContent: some View {
        VStack(spacing: 4) {
            if model.geometry.hasHardwareNotch {
                // Reserve exact physical notch clearance so glyph sits cleanly centered below camera
                Color.clear.frame(height: model.geometry.notchHeight)
            }

            Spacer(minLength: 0)

            IOSFaceIDGlyphView(
                state: model.state,
                accentColor: statusAccent,
                ringProgress: ringProgress,
                checkProgress: checkProgress,
                checkScale: checkScale
            )
            .frame(width: 54, height: 54)

            Spacer(minLength: 14)
        }
        .opacity(isActiveState ? 1 : 0)
        .scaleEffect(isActiveState ? 1 : 0.78, anchor: .top)
        .animation(.easeOut(duration: 0.14), value: isActiveState)
    }
}

/// Native Apple SF Symbol Face ID glyph matching iPhone / Glance proportions:
/// - Scanning: crisp Apple `faceid` SF Symbol with subtle 3D look-around & breathing
/// - Unlocked: iOS green circle sweep + spring-animated checkmark
/// - Rejected: iOS red `faceid` SF Symbol (or spoof shield) with horizontal shake
private struct IOSFaceIDGlyphView: View {
    let state: NotchHUDDisplayState
    let accentColor: Color
    let ringProgress: CGFloat
    let checkProgress: CGFloat
    let checkScale: CGFloat

    var body: some View {
        switch state {
        case .scanning(let faceDetected, _):
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
                let t = timeline.date.timeIntervalSinceReferenceDate
                let breath = 0.96 + 0.04 * sin(t * 3.6)
                let yawDeg = sin(t * 2.0) * (faceDetected ? 5.0 : 14.0)
                let pitchDeg = cos(t * 1.5) * (faceDetected ? 3.0 : 7.0)

                Image(systemName: "faceid")
                    .font(.system(size: 42, weight: .light))
                    .foregroundStyle(accentColor)
                    .scaleEffect(faceDetected ? 0.96 : breath)
                    .rotation3DEffect(.degrees(yawDeg), axis: (x: 0, y: 1, z: 0))
                    .rotation3DEffect(.degrees(pitchDeg), axis: (x: 1, y: 0, z: 0))
            }

        case .unlocked:
            ZStack {
                Circle()
                    .stroke(accentColor.opacity(0.18), lineWidth: 3.0)
                    .padding(4)

                Circle()
                    .trim(from: 0, to: ringProgress)
                    .stroke(
                        accentColor,
                        style: StrokeStyle(lineWidth: 3.0, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .padding(4)

                CheckmarkShape()
                    .trim(from: 0, to: checkProgress)
                    .stroke(
                        accentColor,
                        style: StrokeStyle(lineWidth: 3.0, lineCap: .round, lineJoin: .round)
                    )
                    .padding(16)
                    .scaleEffect(checkScale)
            }

        case .rejected(_, let isSpoof):
            Image(systemName: isSpoof ? "shield.slash.fill" : "faceid")
                .font(.system(size: isSpoof ? 34 : 42, weight: .light))
                .foregroundStyle(accentColor)

        case .hidden, .lockedIdle:
            EmptyView()
        }
    }
}

private struct CheckmarkShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX + rect.width * 0.10, y: rect.minY + rect.height * 0.54))
        p.addLine(to: CGPoint(x: rect.minX + rect.width * 0.39, y: rect.minY + rect.height * 0.82))
        p.addLine(to: CGPoint(x: rect.minX + rect.width * 0.90, y: rect.minY + rect.height * 0.20))
        return p
    }
}
