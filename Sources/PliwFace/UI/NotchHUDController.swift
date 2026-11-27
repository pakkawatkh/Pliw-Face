import AppKit
import Combine
import CoreGraphics
import SwiftUI

private final class LockScreenNotchPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class NotchHoverHostingView: NSHostingView<NotchHUDView> {
    var onHoverEntered: (() -> Void)?
    private var trackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        onHoverEntered?()
    }

    override func mouseDown(with event: NSEvent) {
        onHoverEntered?()
    }
}

/// Controls the Glance-style Dynamic Island / Notch Face ID HUD `NSPanel`.
/// Visible over the macOS Lock Screen (`canBecomeVisibleWithoutLogin = true` + shielding window level)
/// and completely ordered out (`orderOut`) with zero animation overhead whenever unlocked & idle.
@MainActor
public final class NotchHUDController {
    private let model = NotchHUDModel()
    private let overlaySpace = SkyLightOverlaySpace()
    private weak var engine: FaceUnlockEngine?
    private var panel: LockScreenNotchPanel?
    private var hostingView: NotchHoverHostingView?
    private var isAttachedToOverlaySpace = false
    private var cancellables = Set<AnyCancellable>()
    private var retractTask: Task<Void, Never>?
    private var previewTask: Task<Void, Never>?
    private var isHoldingFeedback = false
    private var isTouchIDPromptActive = false
    private var wasScreenLocked = false
    private var lastHandledTerminalPhase: UnlockPhase?

    public init(engine: FaceUnlockEngine? = nil) {
        let resolved = engine ?? .shared
        self.engine = resolved
        self.wasScreenLocked = resolved.isScreenLocked
        observe(engine: resolved)
    }

    public func showTouchIDScanning() {
        guard engine?.settings.showNotchHUD ?? true else { return }
        previewTask?.cancel()
        retractTask?.cancel()
        isTouchIDPromptActive = true
        isHoldingFeedback = false
        if let style = engine?.settings.hudStyle {
            model.style = style
        }
        presentState(.scanning(faceDetected: false, quality: 0, kind: .touchID))
    }

    public func showTouchIDUnlocked() {
        guard isTouchIDPromptActive || (engine?.settings.showNotchHUD ?? true) else { return }
        isTouchIDPromptActive = false
        isHoldingFeedback = true
        if let style = engine?.settings.hudStyle {
            model.style = style
        }
        presentState(.unlocked(identityName: "Touch ID", latencyMs: 0, kind: .touchID))
        scheduleRetract(after: 0.75)
    }

    public func cancelTouchID() {
        guard isTouchIDPromptActive else { return }
        isTouchIDPromptActive = false
        retractImmediately()
    }

    public func teardown() {
        retractTask?.cancel()
        previewTask?.cancel()
        cancellables.removeAll()
        panel?.orderOut(nil)
        overlaySpace.teardown()
        isAttachedToOverlaySpace = false
        panel = nil
        hostingView = nil
    }

    /// Plays the active HUD style choreography on demand from the Menu Bar or Settings.
    public func previewAnimation() {
        previewTask?.cancel()
        retractTask?.cancel()
        isHoldingFeedback = false
        if let style = engine?.settings.hudStyle {
            model.style = style
        }

        presentState(.scanning(faceDetected: false, quality: 0))
        previewTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 750_000_000)
            guard !Task.isCancelled, let self else { return }
            self.presentState(.scanning(faceDetected: true, quality: 0.85))

            try? await Task.sleep(nanoseconds: 850_000_000)
            guard !Task.isCancelled else { return }
            self.isHoldingFeedback = true
            self.presentState(.unlocked(identityName: "Preview", latencyMs: 142))
            self.scheduleRetract(after: 0.90)
        }
    }

    /// Plays a short Scanning → Failed Shake → Locked Wing preview sequence.
    public func previewFailureAnimation() {
        previewTask?.cancel()
        retractTask?.cancel()
        isHoldingFeedback = false
        if let style = engine?.settings.hudStyle {
            model.style = style
        }

        presentState(.scanning(faceDetected: false, quality: 0))
        previewTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 900_000_000)
            guard !Task.isCancelled, let self else { return }
            self.isHoldingFeedback = true
            self.presentState(.rejected(reason: "Try Again", isSpoof: false))

            try? await Task.sleep(nanoseconds: 1_100_000_000)
            guard !Task.isCancelled else { return }
            if self.model.style == .notchWings {
                self.presentState(.lockedIdle)
                try? await Task.sleep(nanoseconds: 900_000_000)
                guard !Task.isCancelled else { return }
            }
            self.isHoldingFeedback = false
            self.previewTask = nil
            self.retractImmediately()
        }
    }

    private func observe(engine: FaceUnlockEngine) {
        Publishers.CombineLatest4(engine.$phase, engine.$runMode, engine.$telemetry, engine.$settings)
            .combineLatest(engine.$isScreenLocked)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] combined, isLocked in
                let (phase, runMode, telemetry, settings) = combined
                self?.handleUpdate(
                    phase: phase,
                    runMode: runMode,
                    telemetry: telemetry,
                    settings: settings,
                    isScreenLocked: isLocked
                )
            }
            .store(in: &cancellables)
    }

    private func handleUpdate(
        phase: UnlockPhase,
        runMode: EngineRunMode,
        telemetry: ScanTelemetry,
        settings: FaceSettings,
        isScreenLocked: Bool
    ) {
        model.style = settings.hudStyle

        guard settings.showNotchHUD else {
            wasScreenLocked = isScreenLocked
            if !isHoldingFeedback && previewTask == nil && !isTouchIDPromptActive {
                retractImmediately()
            }
            return
        }

        // If user unlocked the Lock Screen externally (e.g. Touch ID) while Face ID was scanning,
        // smoothly complete with a Touch ID unlock confirmation instead of snapping away.
        let unlockedExternally = wasScreenLocked && !isScreenLocked
        wasScreenLocked = isScreenLocked
        if unlockedExternally, case .scanning(_, _, .faceID) = model.state {
            isHoldingFeedback = true
            presentState(.unlocked(identityName: "Touch ID", latencyMs: 0, kind: .touchID))
            scheduleRetract(after: 0.75)
            return
        }

        if isTouchIDPromptActive {
            return
        }

        let eligibleMode = (runMode == .lockScreenUnlock || runMode == .diagnosticScan)

        switch phase {
        case .warmingCamera, .scanning:
            guard eligibleMode else { return }
            lastHandledTerminalPhase = nil
            previewTask?.cancel()
            previewTask = nil
            retractTask?.cancel()
            isHoldingFeedback = false
            presentState(.scanning(faceDetected: telemetry.faceDetected, quality: telemetry.faceQuality, kind: .faceID))

        case .unlocked(let identityName, let latencyMs):
            guard lastHandledTerminalPhase != phase else { return }
            lastHandledTerminalPhase = phase
            previewTask?.cancel()
            previewTask = nil
            isHoldingFeedback = true
            presentState(.unlocked(identityName: identityName, latencyMs: latencyMs, kind: .faceID))
            scheduleRetract(after: 0.85)

        case .rejected(let reason), .failed(let reason):
            guard lastHandledTerminalPhase != phase else { return }
            lastHandledTerminalPhase = phase
            previewTask?.cancel()
            previewTask = nil
            isHoldingFeedback = true
            presentState(.rejected(reason: reason, isSpoof: telemetry.livenessVerdict.isSpoof))
            scheduleRetract(after: 1.25)

        case .idle:
            lastHandledTerminalPhase = nil
            if !isHoldingFeedback && previewTask == nil {
                if isScreenLocked && settings.unlockOnNotchHover && (engine?.isReadyForLockScreenUnlock ?? false) {
                    presentState(.lockedIdle)
                } else {
                    retractImmediately()
                }
            }
        }
    }

    private func presentState(_ newState: NotchHUDDisplayState) {
        let geometry = NotchHUDGeometry.current()
        model.geometry = geometry
        let panel = ensurePanel(frame: geometry.panelFrame)
        // Enable NSTrackingArea hover detection whenever locked & idle/rejected so moving cursor to notch rescans immediately.
        let allowHoverTracking: Bool
        switch newState {
        case .lockedIdle, .rejected:
            allowHoverTracking = (engine?.isScreenLocked ?? false) && (engine?.settings.unlockOnNotchHover ?? false)
        default:
            allowHoverTracking = false
        }
        panel.ignoresMouseEvents = !allowHoverTracking
        if !panel.isVisible {
            panel.setFrame(geometry.panelFrame, display: true)
            panel.orderFrontRegardless()
            isAttachedToOverlaySpace = overlaySpace.attach(window: panel)
        } else if panel.frame != geometry.panelFrame {
            panel.setFrame(geometry.panelFrame, display: true)
        }
        model.state = newState
    }

    private func scheduleRetract(after seconds: TimeInterval) {
        retractTask?.cancel()
        retractTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.isHoldingFeedback = false
            self.previewTask = nil
            if let engine = self.engine,
               engine.isScreenLocked,
               engine.runMode == .idle,
               engine.settings.showNotchHUD,
               engine.settings.unlockOnNotchHover,
               engine.isReadyForLockScreenUnlock {
                self.presentState(.lockedIdle)
            } else {
                self.retractImmediately()
            }
        }
    }

    private func retractImmediately() {
        guard !model.state.isHidden else { return }
        model.state = .hidden
        panel?.ignoresMouseEvents = true
        retractTask?.cancel()
        retractTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 540_000_000)
            guard !Task.isCancelled, let self, self.model.state.isHidden else { return }
            self.panel?.orderOut(nil)
        }
    }

    private func ensurePanel(frame: CGRect) -> LockScreenNotchPanel {
        if let existing = panel {
            return existing
        }
        let p = LockScreenNotchPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.ignoresMouseEvents = true
        p.hidesOnDeactivate = false
        p.isFloatingPanel = true
        p.canBecomeVisibleWithoutLogin = true
        p.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()) + 1)
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.appearance = NSAppearance(named: .darkAqua)

        let hosting = NotchHoverHostingView(rootView: NotchHUDView(model: model))
        hosting.frame = CGRect(origin: .zero, size: frame.size)
        hosting.onHoverEntered = { [weak self] in
            self?.engine?.handleNotchHoverWhileLocked()
        }
        p.contentView = hosting
        self.hostingView = hosting
        self.panel = p
        return p
    }
}
