import AppKit
import SwiftUI

public enum AuthVisualKind: Equatable, Sendable {
    case faceID
    case touchID
}

public enum NotchHUDDisplayState: Equatable, Sendable {
    case hidden
    case lockedIdle
    case scanning(faceDetected: Bool, quality: Float, kind: AuthVisualKind = .faceID)
    case unlocked(identityName: String, latencyMs: Int, kind: AuthVisualKind = .faceID)
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

/// Single-scalar animatable liquid Dynamic Island silhouette anchored flush at `y = 0`.
/// - Top concave ears ramp up immediately (`p * 4`) so the organic curve appears right away at the notch bezel.
/// - Bottom corners stay rounded throughout the entire morph (never turning into a sharp rectangle).
/// - Returns an empty path at `p <= 0.005` so zero pixels remain when retracted.
private struct DynamicIslandLiquidShape: Shape {
    var progress: CGFloat
    let baseWidth: CGFloat
    let baseHeight: CGFloat
    let expandedWidth: CGFloat
    let expandedHeight: CGFloat
    let hasHardwareNotch: Bool

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let p = max(0, min(1, progress))
        guard p > 0.005 else { return Path() }

        if !hasHardwareNotch {
            let collapsedW: CGFloat = 96
            let collapsedH: CGFloat = 14
            let w = collapsedW + (expandedWidth - collapsedW) * p
            let h = collapsedH + (expandedHeight - collapsedH) * p
            let minX = rect.midX - w * 0.5
            let corner = min(34, h * 0.48, w * 0.45)
            return Path(roundedRect: CGRect(x: minX, y: rect.minY, width: w, height: h), cornerRadius: corner)
        }

        // Top concave ears appear immediately as the island begins emerging from the notch
        let collapsedH = max(4, baseHeight - 4)
        let h = collapsedH + (expandedHeight - collapsedH) * p
        let earRamp = min(1.0, p * 4.0)
        let ear = min(14.0 * earRamp, h * 0.42)

        // Keep inner body width strictly >= physical notch width (`baseWidth`) at every frame
        // so the MacBook's hardware notch NEVER peeks out past the side walls while retracting.
        let expandedBodyW = max(baseWidth, expandedWidth - 28.0)
        let bodyW = baseWidth + (expandedBodyW - baseWidth) * p
        let w = bodyW + ear * 2.0

        let minX = rect.midX - w * 0.5
        let maxX = rect.midX + w * 0.5
        let minY = rect.minY
        let maxY = rect.minY + h

        let br = min(34.0, max(8.0, h * 0.46), max(8.0, bodyW * 0.46))
        let kEar: CGFloat = 0.62
        let kBot: CGFloat = 0.60

        var path = Path()
        path.move(to: CGPoint(x: minX, y: minY))
        path.addLine(to: CGPoint(x: maxX, y: minY))

        // Right concave ear
        path.addCurve(
            to: CGPoint(x: maxX - ear, y: minY + ear),
            control1: CGPoint(x: maxX - ear * kEar, y: minY),
            control2: CGPoint(x: maxX - ear, y: minY + ear * (1 - kEar))
        )

        path.addLine(to: CGPoint(x: maxX - ear, y: maxY - br))

        // Bottom-right Apple squircle corner
        path.addCurve(
            to: CGPoint(x: maxX - ear - br, y: maxY),
            control1: CGPoint(x: maxX - ear, y: maxY - br * (1 - kBot)),
            control2: CGPoint(x: maxX - ear - br * (1 - kBot), y: maxY)
        )

        path.addLine(to: CGPoint(x: minX + ear + br, y: maxY))

        // Bottom-left Apple squircle corner
        path.addCurve(
            to: CGPoint(x: minX + ear, y: maxY - br),
            control1: CGPoint(x: minX + ear + br * (1 - kBot), y: maxY),
            control2: CGPoint(x: minX + ear, y: maxY - br * (1 - kBot))
        )

        path.addLine(to: CGPoint(x: minX + ear, y: minY + ear))

        // Left concave ear
        path.addCurve(
            to: CGPoint(x: minX, y: minY),
            control1: CGPoint(x: minX + ear, y: minY + ear * (1 - kEar)),
            control2: CGPoint(x: minX + ear * kEar, y: minY)
        )

        path.closeSubpath()
        return path
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
    private static let iosPink = Color(red: 1.000, green: 0.216, blue: 0.373)  // #FF375F (Touch ID)

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

    /// Both styles stay visually collapsed behind the hardware notch during `.lockedIdle`
    /// so the invisible hover-to-rescan tracking area works without keeping wings visible while idle.
    private var isVisuallyVisible: Bool {
        isActiveState
    }

    private var statusAccent: Color {
        switch model.state {
        case .hidden, .lockedIdle:
            return .white.opacity(0.75)
        case .scanning(let faceDetected, _, let kind):
            if kind == .touchID {
                return Self.iosPink
            }
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
            return isActiveState ? 10 : 0
        case .dynamicIsland:
            return 14
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
            case .hidden, .lockedIdle:
                return hasNotch ? max(0, baseW - 2) : 110
            case .scanning, .unlocked, .rejected:
                // Exact same width across Scanning, Retry, and Unlocked so icons never jump!
                return hasNotch ? (baseW + 84 + earComp) : 160
            }

        case .dynamicIsland:
            return hasNotch ? (baseW + 56 + earComp) : 210
        }
    }

    private var hudHeight: CGFloat {
        let hasNotch = model.geometry.hasHardwareNotch
        let baseH = model.geometry.notchHeight

        switch model.style {
        case .notchWings:
            switch model.state {
            case .hidden, .lockedIdle:
                return hasNotch ? max(0, baseH - 2) : 30
            default:
                return hasNotch ? baseH : 36
            }

        case .dynamicIsland:
            return hasNotch ? (baseH + 92) : 136
        }
    }

    private var bottomCornerRadius: CGFloat {
        switch model.style {
        case .notchWings:
            return model.geometry.hasHardwareNotch ? (isActiveState ? 12 : 8) : 18
        case .dynamicIsland:
            return 34
        }
    }

    public var body: some View {
        ZStack(alignment: .top) {
            Color.clear

            if model.style == .dynamicIsland {
                dynamicIslandLiquidContainer
                    .modifier(FaceIDShakeEffect(trigger: shakeTrigger))
                    .animation(
                        isActiveState
                            ? .spring(response: 0.40, dampingFraction: 1.0)
                            : .timingCurve(0.42, 0.0, 0.18, 1.0, duration: 0.42),
                        value: model.state
                    )
            } else {
                hudContainer
                    .frame(width: hudWidth, height: hudHeight, alignment: .top)
                    .modifier(FaceIDShakeEffect(trigger: shakeTrigger))
                    .opacity(isVisuallyVisible ? 1.0 : 0.0)
                    .scaleEffect(isVisuallyVisible || model.geometry.hasHardwareNotch ? 1.0 : 0.88, anchor: .top)
                    .animation(
                        isVisuallyVisible
                            ? .spring(response: 0.34, dampingFraction: 1.0)
                            : .timingCurve(0.4, 0.0, 0.2, 1.0, duration: 0.26),
                        value: model.state
                    )
            }
        }
        .frame(
            width: NotchHUDGeometry.defaultPanelSize.width,
            height: NotchHUDGeometry.defaultPanelSize.height,
            alignment: .top
        )
        .clipped()
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

    private var dynamicIslandLiquidContainer: some View {
        let shape = DynamicIslandLiquidShape(
            progress: isActiveState ? 1.0 : 0.0,
            baseWidth: model.geometry.notchWidth,
            baseHeight: model.geometry.notchHeight,
            expandedWidth: hudWidth,
            expandedHeight: hudHeight,
            hasHardwareNotch: model.geometry.hasHardwareNotch
        )
        return ZStack(alignment: .top) {
            shape.fill(Color.black)
            dynamicIslandContent
                .frame(width: hudWidth, height: hudHeight, alignment: .top)
        }
        .frame(width: hudWidth, height: hudHeight, alignment: .top)
        .clipShape(shape)
    }

    @ViewBuilder
    private var hudContainer: some View {
        if model.geometry.hasHardwareNotch {
            let shape = NotchSilhouetteShape(
                topEarRadius: topEarRadius,
                bottomRadius: bottomCornerRadius
            )
            // Pure matte black (#000000) with clipShape and no drop shadow so zero ghost box appears near the notch.
            ZStack(alignment: .top) {
                shape.fill(Color.black)
                activeStyleContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            .clipShape(shape)
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
        if isActiveState {
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

        case .scanning(let faceDetected, _, let kind):
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
                let t = timeline.date.timeIntervalSinceReferenceDate
                let pulse = 0.90 + 0.10 * sin(t * 4.5)
                if kind == .touchID {
                    Image(systemName: "touchid")
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(Self.iosPink)
                        .scaleEffect(pulse)
                } else {
                    let yawDeg = sin(t * 2.4) * (faceDetected ? 6.0 : 16.0)
                    Image(systemName: "faceid")
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(faceDetected ? Self.iosGreen : .white)
                        .scaleEffect(pulse)
                        .rotation3DEffect(.degrees(yawDeg), axis: (x: 0, y: 1, z: 0))
                }
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
        case .scanning(let faceDetected, _, let kind):
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
                let t = timeline.date.timeIntervalSinceReferenceDate
                let breath = 0.95 + 0.05 * sin(t * 3.6)

                if kind == .touchID {
                    ZStack {
                        Circle()
                            .stroke(accentColor.opacity(0.24), lineWidth: 2.2)
                            .scaleEffect(0.92 + 0.08 * sin(t * 3.6))
                            .padding(2)
                        Image(systemName: "touchid")
                            .font(.system(size: 38, weight: .light))
                            .foregroundStyle(accentColor)
                            .scaleEffect(breath)
                    }
                } else {
                    let yawDeg = sin(t * 2.0) * (faceDetected ? 5.0 : 14.0)
                    let pitchDeg = cos(t * 1.5) * (faceDetected ? 3.0 : 7.0)

                    Image(systemName: "faceid")
                        .font(.system(size: 42, weight: .light))
                        .foregroundStyle(accentColor)
                        .scaleEffect(faceDetected ? 0.96 : breath)
                        .rotation3DEffect(.degrees(yawDeg), axis: (x: 0, y: 1, z: 0))
                        .rotation3DEffect(.degrees(pitchDeg), axis: (x: 1, y: 0, z: 0))
                }
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
