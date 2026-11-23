import CryptoKit
import Foundation
import LocalAuthentication

public enum SessionVaultError: LocalizedError, Equatable, Sendable {
    case emptyPassword
    case sessionLocked
    case encryptionFailed
    case decryptionFailed
    case authenticationCancelled
    case orphanedEncryptedData

    public var errorDescription: String? {
        switch self {
        case .emptyPassword:
            return "Mac login password cannot be empty."
        case .sessionLocked:
            return "Session is locked. Authorize with Touch ID first."
        case .encryptionFailed:
            return "Failed to encrypt data with AES-256-GCM."
        case .decryptionFailed:
            return "Failed to decrypt protected data."
        case .authenticationCancelled:
            return "Touch ID authentication was cancelled."
        case .orphanedEncryptedData:
            return "Encrypted data exists without a matching session key. Reset stored credentials to start fresh."
        }
    }
}

/// 2-tier encryption vault:
/// - Tier 1: A 256-bit AES session key stored in Keychain gated by Touch ID (`userPresence`), held in RAM only while armed.
/// - Tier 2: AES-256-GCM sealed blobs for the Mac login password and enrolled face templates.
public final class SessionCryptoVault: @unchecked Sendable {
    public static let shared = SessionCryptoVault()

    private let service: String
    private let sessionKeyAccount = "session_aes256_key"
    private let passwordBlobAccount = "encrypted_login_password"

    private let lock = NSLock()
    private var cachedKey: SymmetricKey?
    private var lastActivityDate: Date?

    public init(service: String = KeychainVault.defaultService) {
        self.service = service
    }

    public var isSessionArmed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cachedKey != nil
    }

    public var lastActivityAt: Date? {
        lock.lock()
        defer { lock.unlock() }
        return lastActivityDate
    }

    public func hasStoredPassword() -> Bool {
        KeychainVault.exists(account: passwordBlobAccount, service: service)
    }

    /// Injects an ephemeral in-memory key for isolated unit tests (never touches Keychain).
    public func armForTesting(with key: SymmetricKey = SymmetricKey(size: .bits256)) {
        lock.lock()
        cachedKey = key
        lastActivityDate = Date()
        lock.unlock()
    }

    /// Prompts Touch ID (or device password) once to unwrap the 256-bit session key into RAM.
    public func armSession(reason: String = "Arm Tiffy Face unlock session") throws {
        if isSessionArmed {
            touchActivity()
            return
        }

        if KeychainVault.exists(account: sessionKeyAccount, service: service) {
            let context = LAContext()
            context.localizedReason = reason
            do {
                let rawKey = try KeychainVault.read(account: sessionKeyAccount, service: service, context: context)
                setCachedKey(SymmetricKey(data: rawKey))
                return
            } catch KeychainVaultError.authenticationCancelled {
                throw SessionVaultError.authenticationCancelled
            }
        }

        // Refuse to silently overwrite an unrecoverable key if encrypted blobs already exist.
        if hasStoredPassword() {
            throw SessionVaultError.orphanedEncryptedData
        }

        // First-time setup: create a fresh 256-bit key gated by userPresence (Touch ID / password).
        let newKey = SymmetricKey(size: .bits256)
        let keyBytes = newKey.withUnsafeBytes { Data($0) }

        if let accessControl = try? KeychainVault.makeUserPresenceAccessControl() {
            try KeychainVault.save(
                account: sessionKeyAccount,
                data: keyBytes,
                service: service,
                accessControl: accessControl
            )
            // Verify user presence with a gated read-back before arming RAM cache.
            let verifyContext = LAContext()
            verifyContext.localizedReason = reason
            do {
                let verified = try KeychainVault.read(account: sessionKeyAccount, service: service, context: verifyContext)
                setCachedKey(SymmetricKey(data: verified))
            } catch KeychainVaultError.authenticationCancelled {
                try? KeychainVault.delete(account: sessionKeyAccount, service: service)
                throw SessionVaultError.authenticationCancelled
            }
        } else {
            // Fallback for ad-hoc signed local builds if Secure Enclave ACL is unavailable
            let context = LAContext()
            var authError: NSError?
            if context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &authError) {
                let semaphore = DispatchSemaphore(value: 0)
                var passed = false
                context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { ok, _ in
                    passed = ok
                    semaphore.signal()
                }
                semaphore.wait()
                guard passed else {
                    throw SessionVaultError.authenticationCancelled
                }
            }
            try KeychainVault.save(account: sessionKeyAccount, data: keyBytes, service: service, accessControl: nil)
            setCachedKey(newKey)
        }
    }

    public func disarmSession() {
        setCachedKey(nil)
    }

    /// Checks whether the armed session has exceeded the configured idle timeout and disarms if expired.
    @discardableResult
    public func enforceIdleTimeout(_ timeout: TimeInterval?) -> Bool {
        guard let timeout, timeout > 0 else { return false }
        lock.lock()
        defer { lock.unlock() }
        guard cachedKey != nil, let last = lastActivityDate else { return false }
        if Date().timeIntervalSince(last) >= timeout {
            cachedKey = nil
            lastActivityDate = nil
            return true
        }
        return false
    }

    // MARK: - AES-256-GCM Seal / Open

    public func seal(_ plaintext: Data) throws -> Data {
        guard let key = currentKey() else { throw SessionVaultError.sessionLocked }
        do {
            let box = try AES.GCM.seal(plaintext, using: key)
            guard let combined = box.combined else { throw SessionVaultError.encryptionFailed }
            return combined
        } catch {
            throw SessionVaultError.encryptionFailed
        }
    }

    public func open(_ combinedCiphertext: Data) throws -> Data {
        guard let key = currentKey() else { throw SessionVaultError.sessionLocked }
        do {
            let box = try AES.GCM.SealedBox(combined: combinedCiphertext)
            let data = try AES.GCM.open(box, using: key)
            touchActivity()
            return data
        } catch {
            throw SessionVaultError.decryptionFailed
        }
    }

    // MARK: - Password Operations

    public func savePassword(_ passwordBytes: Data) throws {
        guard !passwordBytes.isEmpty else { throw SessionVaultError.emptyPassword }
        let sealed = try seal(passwordBytes)
        try KeychainVault.save(account: passwordBlobAccount, data: sealed, service: service)
        touchActivity()
    }

    /// Returns decrypted password bytes. Callers MUST wipe the returned Data via `resetBytes(in:)` immediately after use.
    public func readPassword() throws -> Data {
        guard isSessionArmed else { throw SessionVaultError.sessionLocked }
        let sealed = try KeychainVault.read(account: passwordBlobAccount, service: service)
        return try open(sealed)
    }

    public func deleteAllCredentials() throws {
        try KeychainVault.delete(account: passwordBlobAccount, service: service)
        try KeychainVault.delete(account: sessionKeyAccount, service: service)
        disarmSession()
    }

    // MARK: - Private Helpers

    private func currentKey() -> SymmetricKey? {
        lock.lock()
        defer { lock.unlock() }
        return cachedKey
    }

    private func setCachedKey(_ key: SymmetricKey?) {
        lock.lock()
        cachedKey = key
        lastActivityDate = key != nil ? Date() : nil
        lock.unlock()
    }

    private func touchActivity() {
        lock.lock()
        if cachedKey != nil {
            lastActivityDate = Date()
        }
        lock.unlock()
    }
}
