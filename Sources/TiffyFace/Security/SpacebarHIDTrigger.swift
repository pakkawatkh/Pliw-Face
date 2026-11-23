import AppKit
import Foundation
import IOKit.hid

/// Lightweight IOHIDManager listener active ONLY while the Mac is locked so tapping Spacebar triggers a face rescan
/// even while macOS Secure Event Input suppresses CGEventTap. Zero overhead when unlocked.
@MainActor
public final class SpacebarHIDTrigger {
    public var onSpacePressed: (() -> Void)?

    private var manager: IOHIDManager?
    private var lastTriggerTime: TimeInterval = 0

    public init() {}

    public nonisolated static func isInputMonitoringGranted() -> Bool {
        IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
    }

    /// Requests macOS Input Monitoring permission for Spacebar detection on the Lock Screen.
    /// If already denied, opens System Settings directly to Privacy & Security → Input Monitoring.
    @discardableResult
    public nonisolated static func requestInputMonitoringAccess() -> Bool {
        let current = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)
        if current == kIOHIDAccessTypeGranted {
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
        guard Self.isInputMonitoringGranted() else {
            return
        }

        let hidManager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))

        // Match physical keyboards (built-in MacBook keyboard + external USB/Bluetooth keyboards)
        let keyboardMatch: [String: Int] = [
            kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop,
            kIOHIDDeviceUsageKey: kHIDUsage_GD_Keyboard,
        ]
        IOHIDManagerSetDeviceMatching(hidManager, keyboardMatch as CFDictionary)

        // Kernel-side element filter: wake callback ONLY for Spacebar (Usage Page 0x07, Usage 0x2C)
        let spacebarMatch: [String: Int] = [
            kIOHIDElementUsagePageKey: kHIDPage_KeyboardOrKeypad,
            kIOHIDElementUsageKey: 0x2C,
        ]
        IOHIDManagerSetInputValueMatching(hidManager, spacebarMatch as CFDictionary)

        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterInputValueCallback(hidManager, { context, _, _, value in
            guard let context else { return }
            let element = IOHIDValueGetElement(value)
            let usagePage = IOHIDElementGetUsagePage(element)
            let usage = IOHIDElementGetUsage(element)
            let pressed = IOHIDValueGetIntegerValue(value)

            // HID Keyboard Usage Page 0x07, Spacebar = 0x2C, keyDown = 1
            guard usagePage == kHIDPage_KeyboardOrKeypad, usage == 0x2C, pressed == 1 else {
                return
            }

            let trigger = Unmanaged<SpacebarHIDTrigger>.fromOpaque(context).takeUnretainedValue()
            Task { @MainActor in
                trigger.handleSpaceDown()
            }
        }, context)

        IOHIDManagerScheduleWithRunLoop(hidManager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        let status = IOHIDManagerOpen(hidManager, IOOptionBits(kIOHIDOptionsTypeNone))
        if status == kIOReturnSuccess {
            self.manager = hidManager
        } else {
            IOHIDManagerUnscheduleFromRunLoop(hidManager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        }
    }

    public func stopListening() {
        guard let hidManager = manager else { return }
        manager = nil
        IOHIDManagerUnscheduleFromRunLoop(hidManager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        IOHIDManagerClose(hidManager, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    private func handleSpaceDown() {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastTriggerTime > 0.8 else { return }
        lastTriggerTime = now
        onSpacePressed?()
    }
}
