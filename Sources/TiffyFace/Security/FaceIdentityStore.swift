import Foundation

/// Persists enrolled `FaceIdentity` vectors encrypted with AES-256-GCM via `SessionCryptoVault`.
public final class FaceIdentityStore: @unchecked Sendable {
    public static let shared = FaceIdentityStore()

    private let fileURL: URL
    private let vault: SessionCryptoVault

    public init(fileURL: URL? = nil, vault: SessionCryptoVault = .shared) {
        self.vault = vault
        if let customURL = fileURL {
            self.fileURL = customURL
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
            self.fileURL = appSupport
                .appendingPathComponent("TiffyFace", isDirectory: true)
                .appendingPathComponent("identities.enc")
        }
    }

    public var hasEncryptedFile: Bool {
        FileManager.default.fileExists(atPath: fileURL.path)
    }

    public func load() throws -> [FaceIdentity] {
        guard hasEncryptedFile else { return [] }
        let ciphertext = try Data(contentsOf: fileURL)
        let plaintext = try vault.open(ciphertext)
        return try JSONDecoder().decode([FaceIdentity].self, from: plaintext)
    }

    public func save(_ identities: [FaceIdentity]) throws {
        let dir = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let plaintext = try JSONEncoder().encode(identities)
        let sealed = try vault.seal(plaintext)
        try sealed.write(to: fileURL, options: [.atomic])
    }

    public func deleteAll() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}
