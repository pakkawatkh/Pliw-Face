import AppKit
import ApplicationServices
import Foundation
import IOKit.hid
import os

/// Lightweight IOHIDManager listener active ONLY while the Mac is locked so tapping Spacebar triggers a face rescan
/// even while macOS Secure Event Input suppresses CGEventTap. Zero overhead when unlocked.
@MainActor
public final class SpacebarHIDTrigger {
    private static let log = Logger(subsystem: "com.local.pliw-face", category: "SpacebarHID")

    public var onSpacePressed: (() -> Void)?

    private var manager: IOHIDManager?
    private var lastTriggerTime: TimeInterval = 0

    public init() {}

    /// On macOS, Accessibility permission satisfies HID keyboard listening even when `IOHIDCheckAccess` reports unknown.
    public nonisolated static func isInputMonitoringGranted() -> Bool {
        IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted || AXIsProcessTrusted()
    }

    @discardableResult
    public nonisolated static func requestInputMonitoringAccess() -> Bool {
        if isInputMonitoringGranted() {
            return true
        }
        let granted = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        if !granted,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
            DispatchQueue.main.async {
                NSWorkspace.shared.open(url)
            }
        }
        return granted
    }

    public var isListening: Bool {
        manager != nil
    }

    public func startListening() {
        guard manager == nil else { return }

        let hidManager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))

        // Match physical keyboards (built-in MacBook SPI keyboard + external USB/Bluetooth keyboards)
        let keyboardMatch: [String: Int] = [
            kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop,
            kIOHIDDeviceUsageKey: kHIDUsage_GD_Keyboard,
        ]
        IOHIDManagerSetDeviceMatching(hidManager, keyboardMatch as CFDictionary)

        // Filter Spacebar inside the callback (avoiding IOHIDManagerSetInputValueMatching which drops
        // events on Apple Silicon internal SPI keyboards).
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterInputValueCallback(hidManager, { context, _, _, value in
            guard let context else { return }
            let element = IOHIDValueGetElement(value)
            guard IOHIDElementGetUsagePage(element) == UInt32(kHIDPage_KeyboardOrKeypad),
                  IOHIDElementGetUsage(element) == UInt32(kHIDUsage_KeyboardSpacebar),
                  IOHIDValueGetIntegerValue(value) == 1
            else {
                return
            }

            let trigger = Unmanaged<SpacebarHIDTrigger>.fromOpaque(context).takeUnretainedValue()
            Task { @MainActor in
                trigger.handleSpaceDown()
            }
        }, context)

        IOHIDManagerScheduleWithRunLoop(hidManager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)

        // Let IOHIDManagerOpen itself act as ground truth for HID access
        let status = IOHIDManagerOpen(hidManager, IOOptionBits(kIOHIDOptionsTypeNone))
        if status == kIOReturnSuccess {
            self.manager = hidManager
            Self.log.info("IOHIDManagerOpen succeeded — listening for Spacebar on Lock Screen")
        } else {
            Self.log.error("IOHIDManagerOpen failed with status 0x\(String(status, radix: 16), privacy: .public)")
            IOHIDManagerUnscheduleFromRunLoop(hidManager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        }
    }

    public func stopListening() {
        guard let hidManager = manager else { return }
        manager = nil
        IOHIDManagerUnscheduleFromRunLoop(hidManager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        IOHIDManagerClose(hidManager, IOOptionBits(kIOHIDOptionsTypeNone))
        Self.log.info("Stopped Spacebar HID listener")
    }

    private func handleSpaceDown() {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastTriggerTime > 0.7 else { return }
        lastTriggerTime = now
        Self.log.info("Spacebar pressed on Lock Screen — triggering scan")
        onSpacePressed?()
    }
}
