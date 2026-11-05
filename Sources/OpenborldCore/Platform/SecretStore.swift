import Foundation
import Crypto

#if canImport(Security)
import Security
#endif

/// Where connection credentials live.
///
/// The guarantees differ by platform and the difference is not cosmetic, so it
/// is stated rather than hidden: the macOS Keychain is protected by the user's
/// login and the Secure Enclave-backed keybag, while the portable fallback is
/// an encrypted file whose key sits on the same disk. `protectionDescription`
/// exists so the UI can tell the user which one they have.
public protocol SecretStore: Sendable {
    func save(_ secrets: ConnectionSecrets, for id: UUID) throws
    func load(_ id: UUID) throws -> ConnectionSecrets
    func delete(_ id: UUID) throws

    /// One sentence describing how strongly secrets are protected here.
    var protectionDescription: String { get }
}

public enum Secrets {
    /// The store for this platform. macOS gets the Keychain; everywhere else
    /// gets the encrypted file store.
    public static let store: any SecretStore = {
        #if canImport(Security)
        return KeychainSecretStore()
        #else
        return EncryptedFileSecretStore()
        #endif
    }()
}

// MARK: - Apple Keychain

#if canImport(Security)

public struct KeychainSecretStore: SecretStore {
    public static let service = "dev.openborld.connections"

    public init() {}

    public var protectionDescription: String {
        "Stored in your login Keychain, protected by macOS."
    }

    public func save(_ secrets: ConnectionSecrets, for id: UUID) throws {
        guard !secrets.isEmpty else {
            try delete(id)
            return
        }
        let data = try JSONEncoder().encode(secrets)

        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: id.uuidString,
        ]
        let update: [String: Any] = [
            kSecValueData as String: data,
            // Readable after first unlock, and never synced off this device.
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]

        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            query.merge(update) { current, _ in current }
            let addStatus = SecItemAdd(query as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw Self.error(addStatus, "save") }
            return
        }
        guard status == errSecSuccess else { throw Self.error(status, "update") }
    }

    public func load(_ id: UUID) throws -> ConnectionSecrets {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: id.uuidString,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return ConnectionSecrets() }
        guard status == errSecSuccess, let data = item as? Data else {
            throw Self.error(status, "read")
        }
        return (try? JSONDecoder().decode(ConnectionSecrets.self, from: data))
            ?? ConnectionSecrets()
    }

    public func delete(_ id: UUID) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: id.uuidString,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw Self.error(status, "delete")
        }
    }

    private static func error(_ status: OSStatus, _ action: String) -> StorageError {
        if status == errSecUserCanceled || status == errSecAuthFailed {
            return .accessDenied(
                "Keychain access was denied, so the credentials couldn't be \(action)d."
            )
        }
        let detail = SecCopyErrorMessageString(status, nil) as String?
        return .provider("Keychain \(action) failed: \(detail ?? "status \(status)").")
    }
}

#endif

// MARK: - Portable encrypted file

/// Credentials in an AES-GCM encrypted file, for platforms with no system
/// keychain binding.
///
/// This is weaker than a real keychain and the difference matters: the key file
/// sits beside the data, so anything running as this user can read both. It
/// protects against a stolen backup or a careless file share, not against local
/// malware. The file permissions are tightened to owner-only on POSIX.
public struct EncryptedFileSecretStore: SecretStore {
    private let directory: URL

    public init(directory: URL? = nil) {
        self.directory = directory ?? AppPaths.support.appendingPathComponent(
            "secrets", isDirectory: true
        )
    }

    public var protectionDescription: String {
        "Stored in an encrypted file readable only by your user account. "
            + "This is weaker than a system keychain."
    }

    private var keyURL: URL { directory.appendingPathComponent("master.key") }

    private func vaultURL(_ id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).bin")
    }

    public func save(_ secrets: ConnectionSecrets, for id: UUID) throws {
        guard !secrets.isEmpty else {
            try delete(id)
            return
        }
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let key = try masterKey()
        let plaintext = try JSONEncoder().encode(secrets)
        let sealed = try AES.GCM.seal(plaintext, using: key)
        guard let combined = sealed.combined else {
            throw StorageError.provider("Couldn't encrypt the credentials.")
        }
        try combined.write(to: vaultURL(id), options: .atomic)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: vaultURL(id).path
        )
    }

    public func load(_ id: UUID) throws -> ConnectionSecrets {
        let url = vaultURL(id)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return ConnectionSecrets()
        }
        let key = try masterKey()
        let combined = try Data(contentsOf: url)
        do {
            let box = try AES.GCM.SealedBox(combined: combined)
            let plaintext = try AES.GCM.open(box, using: key)
            return try JSONDecoder().decode(ConnectionSecrets.self, from: plaintext)
        } catch {
            throw StorageError.provider(
                "The stored credentials for this connection couldn't be decrypted. "
                    + "Re-enter them to replace the damaged file."
            )
        }
    }

    public func delete(_ id: UUID) throws {
        let url = vaultURL(id)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    /// Loads the machine-local key, creating one on first use.
    private func masterKey() throws -> SymmetricKey {
        let fm = FileManager.default
        if let data = try? Data(contentsOf: keyURL), data.count == 32 {
            return SymmetricKey(data: data)
        }
        try fm.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let key = SymmetricKey(size: .bits256)
        let data = key.withUnsafeBytes { Data($0) }
        try data.write(to: keyURL, options: [.atomic])
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyURL.path)
        return key
    }
}

// MARK: - Compatibility

/// Retained so existing call sites keep working after the rename to a
/// pluggable store.
public enum Keychain {
    public static func save(_ secrets: ConnectionSecrets, for id: UUID) throws {
        try Secrets.store.save(secrets, for: id)
    }

    public static func load(_ id: UUID) throws -> ConnectionSecrets {
        try Secrets.store.load(id)
    }

    public static func delete(_ id: UUID) throws {
        try Secrets.store.delete(id)
    }
}
