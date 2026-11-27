import ApplicationServices
import CoreGraphics
import Foundation

public enum KeystrokeDriverError: LocalizedError, Equatable, Sendable {
    case accessibilityDenied
    case invalidUTF8Password
    case eventCreationFailed
    case screenNoLongerLocked

    public var errorDescription: String? {
        switch self {
        case .accessibilityDenied:
            return "Accessibility permission is required in System Settings → Privacy & Security → Accessibility."
        case .invalidUTF8Password:
            return "Stored password could not be decoded as UTF-8."
        case .eventCreationFailed:
            return "Unable to synthesize keyboard event."
        case .screenNoLongerLocked:
            return "Screen is no longer locked; aborted password injection."
        }
    }
}

/// Posts Unicode keystrokes via documented macOS Accessibility / CoreGraphics HID tap APIs.
public enum LockScreenKeystrokeDriver {
    public nonisolated static let maxUTF16ChunkSize = 18

    public nonisolated static func isAccessibilityTrusted() -> Bool {
        AXIsProcessTrusted()
    }

    @discardableResult
    public nonisolated static func requestAccessibilityPrompt() -> Bool {
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [promptKey: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// Splits a UTF-16 sequence into safe chunks that never break surrogate pairs (for non-BMP characters).
    public nonisolated static func splitUTF16Safely(_ text: String, maxChunkSize: Int = maxUTF16ChunkSize) -> [[UInt16]] {
        let units = Array(text.utf16)
        guard !units.isEmpty, maxChunkSize > 0 else { return [] }

        var chunks: [[UInt16]] = []
        var index = 0
        while index < units.count {
            var end = min(index + maxChunkSize, units.count)
            // Keep high surrogate paired with its following low surrogate
            if end < units.count, (0xD800...0xDBFF).contains(units[end - 1]), end - index > 1 {
                end -= 1
            }
            chunks.append(Array(units[index..<end]))
            index = end
        }
        return chunks
    }

    /// Clears stray characters in the focused password field, types the password in UTF-16 batches, and presses Return.
    /// Continuously verifies the screen is still locked before every keystroke phase to prevent leaking into unlocked apps.
    /// Zeroes `passwordBytes` in-place via `defer` before returning.
    public nonisolated static func submitPassword(
        _ passwordBytes: inout Data,
        isLockedCheck: @Sendable () -> Bool = { LockScreenMonitor.isScreenActuallyLocked() }
    ) throws {
        defer {
            if !passwordBytes.isEmpty {
                passwordBytes.resetBytes(in: 0..<passwordBytes.count)
            }
        }

        guard isLockedCheck() else {
            throw KeystrokeDriverError.screenNoLongerLocked
        }
        guard isAccessibilityTrusted() else {
            throw KeystrokeDriverError.accessibilityDenied
        }
        guard let decoded = String(data: passwordBytes, encoding: .utf8), !decoded.isEmpty else {
            throw KeystrokeDriverError.invalidUTF8Password
        }

        let source = CGEventSource(stateID: .hidSystemState)
        try clearField(source: source)

        guard isLockedCheck() else {
            throw KeystrokeDriverError.screenNoLongerLocked
        }

        for var chunk in splitUTF16Safely(decoded) {
            guard isLockedCheck() else {
                throw KeystrokeDriverError.screenNoLongerLocked
            }
            try postUnicodeChunk(&chunk, source: source)
        }

        guard isLockedCheck() else {
            throw KeystrokeDriverError.screenNoLongerLocked
        }
        try postVirtualKey(0x24, flags: [], source: source) // Return
    }

    private nonisolated static func clearField(source: CGEventSource?) throws {
        // Positional keys (Cmd+RightArrow then Cmd+Delete) work consistently across all keyboard layouts (TH/EN/etc.)
        try postVirtualKey(0x7C, flags: .maskCommand, source: source)
        try postVirtualKey(0x33, flags: .maskCommand, source: source)
    }

    private nonisolated static func postVirtualKey(_ keyCode: CGKeyCode, flags: CGEventFlags, source: CGEventSource?) throws {
        let cmdKey: CGKeyCode = 0x37
        let useCmd = flags.contains(.maskCommand)

        if useCmd {
            guard let cmdDown = CGEvent(keyboardEventSource: source, virtualKey: cmdKey, keyDown: true) else {
                throw KeystrokeDriverError.eventCreationFailed
            }
            cmdDown.flags = .maskCommand
            cmdDown.post(tap: .cghidEventTap)
            Thread.sleep(forTimeInterval: 0.008)
        }

        guard let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else {
            throw KeystrokeDriverError.eventCreationFailed
        }
        down.flags = flags
        up.flags = flags
        down.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.008)
        up.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.008)

        if useCmd {
            guard let cmdUp = CGEvent(keyboardEventSource: source, virtualKey: cmdKey, keyDown: false) else {
                throw KeystrokeDriverError.eventCreationFailed
            }
            cmdUp.flags = []
            cmdUp.post(tap: .cghidEventTap)
            Thread.sleep(forTimeInterval: 0.008)
        }
    }

    private nonisolated static func postUnicodeChunk(_ chunk: inout [UInt16], source: CGEventSource?) throws {
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else {
            throw KeystrokeDriverError.eventCreationFailed
        }
        chunk.withUnsafeBufferPointer { buf in
            guard let ptr = buf.baseAddress else { return }
            down.keyboardSetUnicodeString(stringLength: buf.count, unicodeString: ptr)
            up.keyboardSetUnicodeString(stringLength: buf.count, unicodeString: ptr)
        }
        down.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.003)
        up.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.003)
    }
}
