import AppKit
import CoreGraphics
import Foundation

public enum LockEvent: Equatable, Sendable {
    case locked
    case unlocked
    case willSleep
    case wokeUp
}

/// Zero-polling, event-driven macOS lock & wake monitor paired with an authoritative CoreGraphics session check.
@MainActor
public final class LockScreenMonitor {
    public private(set) var isSleeping: Bool = false
    public var onEvent: ((LockEvent) -> Void)?

    private var distributedTokens: [NSObjectProtocol] = []
    private var workspaceTokens: [NSObjectProtocol] = []
    private var isStarted = false

    public init() {}

    /// Authoritative lock state queried directly from CoreGraphics Session Server (cannot be spoofed by notifications).
    public nonisolated static func isScreenActuallyLocked() -> Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else {
            return false
        }
        return (session["CGSSessionScreenIsLocked"] as? Bool) ?? false
    }

    public func start() {
        guard !isStarted else { return }
        isStarted = true

        let dnc = DistributedNotificationCenter.default()
        distributedTokens.append(
            dnc.addObserver(forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.onEvent?(.locked)
                }
            }
        )
        distributedTokens.append(
            dnc.addObserver(forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.onEvent?(.unlocked)
                }
            }
        )
        distributedTokens.append(
            dnc.addObserver(forName: Notification.Name("com.apple.screensaver.didstop"), object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.isSleeping = false
                    self?.onEvent?(.wokeUp)
                }
            }
        )

        let wnc = NSWorkspace.shared.notificationCenter
        workspaceTokens.append(
            wnc.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.isSleeping = true
                    self?.onEvent?(.willSleep)
                }
            }
        )
        workspaceTokens.append(
            wnc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.isSleeping = false
                    self?.onEvent?(.wokeUp)
                }
            }
        )
        workspaceTokens.append(
            wnc.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.isSleeping = false
                    self?.onEvent?(.wokeUp)
                }
            }
        )
    }

    public func stop() {
        guard isStarted else { return }
        isStarted = false

        let dnc = DistributedNotificationCenter.default()
        for token in distributedTokens {
            dnc.removeObserver(token)
        }
        distributedTokens.removeAll()

        let wnc = NSWorkspace.shared.notificationCenter
        for token in workspaceTokens {
            wnc.removeObserver(token)
        }
        workspaceTokens.removeAll()
    }
}
