import AppKit
import CoreGraphics
import Foundation
import os

/// Lightweight Lock-Screen-only cursor hover detector for the top-center Notch hit zone.
/// Checks both Quartz (`CGEvent`) and AppKit (`NSEvent.mouseLocation`) coordinates for maximum reliability
/// on the Lock Screen, and stops completely when unlocked (zero idle CPU overhead).
@MainActor
public final class NotchHoverTrigger {
    private static let log = Logger(subsystem: "com.local.pliw-face", category: "NotchHover")

    public var onNotchHovered: (() -> Void)?

    private var timer: Timer?
    private var wasInsideNotch = false
    private var lastTriggerUptime: TimeInterval = 0

    public var isListening: Bool { timer != nil }

    public init() {}

    /// Computes the Notch hit-zone rectangle in Quartz global coordinates (origin top-left of main screen).
    public nonisolated static func notchHitZoneQuartz(
        screenFrame: CGRect,
        safeTop: CGFloat,
        leftAuxWidth: CGFloat,
        rightAuxWidth: CGFloat
    ) -> CGRect {
        let hasNotch = safeTop > 0
        let rawNotchWidth = hasNotch ? max(0, screenFrame.width - leftAuxWidth - rightAuxWidth) : 132
        let baseWidth = hasNotch ? max(150, min(260, rawNotchWidth > 0 ? rawNotchWidth : 186)) : 132
        let hitWidth = baseWidth + 64
        let hitHeight = hasNotch ? max(safeTop + 18, 54) : 50
        let x = screenFrame.midX - hitWidth * 0.5
        return CGRect(x: x, y: 0, width: hitWidth, height: hitHeight)
    }

    /// Converts an AppKit bottom-left screen coordinate (`NSEvent.mouseLocation`) to Quartz top-left space.
    public nonisolated static func convertAppKitToQuartz(
        pointAppKit: CGPoint,
        screenFrame: CGRect
    ) -> CGPoint {
        CGPoint(x: pointAppKit.x, y: screenFrame.maxY - pointAppKit.y)
    }

    /// Pure point-in-zone check for unit testing.
    public nonisolated static func isPointInsideNotchZone(
        pointQuartz: CGPoint,
        screenFrame: CGRect,
        safeTop: CGFloat,
        leftAuxWidth: CGFloat,
        rightAuxWidth: CGFloat
    ) -> Bool {
        let zone = notchHitZoneQuartz(
            screenFrame: screenFrame,
            safeTop: safeTop,
            leftAuxWidth: leftAuxWidth,
            rightAuxWidth: rightAuxWidth
        )
        return zone.contains(pointQuartz)
    }

    public func startListening() {
        guard timer == nil else { return }
        wasInsideNotch = isCursorCurrentlyInNotch()
        timer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.pollCursor()
            }
        }
    }

    public func stopListening() {
        timer?.invalidate()
        timer = nil
        wasInsideNotch = false
    }

    /// Belt-and-suspenders hook called from `NotchHUDController`'s `NSTrackingArea` `mouseEntered`.
    public func notifyHoverEnteredFromTrackingArea() {
        Self.log.info("Notch NSTrackingArea mouseEntered")
        fireTriggerIfDebounced()
    }

    private func pollCursor() {
        let inside = isCursorCurrentlyInNotch()
        if inside && !wasInsideNotch {
            Self.log.info("Notch cursor rising-edge entered")
            fireTriggerIfDebounced()
        }
        wasInsideNotch = inside
    }

    private func fireTriggerIfDebounced() {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastTriggerUptime >= 0.6 else { return }
        lastTriggerUptime = now
        onNotchHovered?()
    }

    private func isCursorCurrentlyInNotch() -> Bool {
        let screen = NSScreen.main ?? NSScreen.screens.first
        let frame = screen?.frame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let safeTop = screen?.safeAreaInsets.top ?? 0
        let leftW = screen?.auxiliaryTopLeftArea?.width ?? 0
        let rightW = screen?.auxiliaryTopRightArea?.width ?? 0

        if let cgLoc = CGEvent(source: nil)?.location,
           Self.isPointInsideNotchZone(
               pointQuartz: cgLoc,
               screenFrame: frame,
               safeTop: safeTop,
               leftAuxWidth: leftW,
               rightAuxWidth: rightW
           ) {
            return true
        }

        let appKitQuartz = Self.convertAppKitToQuartz(pointAppKit: NSEvent.mouseLocation, screenFrame: frame)
        return Self.isPointInsideNotchZone(
            pointQuartz: appKitQuartz,
            screenFrame: frame,
            safeTop: safeTop,
            leftAuxWidth: leftW,
            rightAuxWidth: rightW
        )
    }
}
