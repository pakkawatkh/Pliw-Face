import Foundation
import LocalAuthentication
import Security

public enum KeychainVaultError: LocalizedError, Equatable, Sendable {
    case itemNotFound
    case authenticationCancelled
    case accessControlCreationFailed
    case osStatus(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .itemNotFound:
            return "Keychain item not found."
        case .authenticationCancelled:
            return "Authentication was cancelled."
        case .accessControlCreationFailed:
            return "Unable to create Touch ID Keychain access control."
        case .osStatus(let status):
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
            return "Keychain error: \(message)"
        }
    }
}

/// Thin, thread-safe Security.framework Keychain wrapper scoped to Tiffy Face.
public enum KeychainVault {
    public static let defaultService = "com.local.tiffy-face"

    public static func makeUserPresenceAccessControl() throws -> SecAccessControl {
        var error: Unmanaged<CFError>?
        guard let control = SecAccessControlCreateWithFlags(
            kCFAllocatorDefault,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            .userPresence,
            &error
        ) else {
            throw KeychainVaultError.accessControlCreationFailed
        }
        return control
    }

    public static func exists(account: String, service: String = defaultService) -> Bool {
        let context = LAContext()
        context.interactionNotAllowed = true
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseAuthenticationContext as String: context,
            kSecReturnAttributes as String: true,
        ]
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        return status == errSecSuccess || status == errSecInteractionNotAllowed
    }

    public static func save(
        account: String,
        data: Data,
        service: String = defaultService,
        accessControl: SecAccessControl? = nil
    ) throws {
        // Delete existing item first so access control attributes can be replaced cleanly.
        try? delete(account: account, service: service)

        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
        ]

        if let accessControl {
            query[kSecAttrAccessControl as String] = accessControl
        } else {
            query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        }

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            if status == errSecUserCanceled || status == errSecAuthFailed {
                throw KeychainVaultError.authenticationCancelled
            }
            throw KeychainVaultError.osStatus(status)
        }
    }

    public static func read(
        account: String,
        service: String = defaultService,
        context: LAContext? = nil
    ) throws -> Data {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        if let context {
            query[kSecUseAuthenticationContext as String] = context
        }

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            if status == errSecItemNotFound {
                throw KeychainVaultError.itemNotFound
            }
            if status == errSecUserCanceled || status == errSecAuthFailed {
                throw KeychainVaultError.authenticationCancelled
            }
            throw KeychainVaultError.osStatus(status)
        }
        return data
    }

    public static func delete(account: String, service: String = defaultService) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainVaultError.osStatus(status)
        }
    }
}
