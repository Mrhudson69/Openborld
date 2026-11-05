import Foundation

#if canImport(Security)
import Security
#endif

/// Carries data across the rename from Cirrus to Openborld.
///
/// Without this, renaming the app silently orphans every saved connection and
/// its credentials: the settings move to a new directory and the Keychain
/// items sit under a service name nothing reads any more. A rename should not
/// look like data loss to the person using it.
public enum LegacyMigration {
    private static let legacyFolderName = "Cirrus"
    private static let legacyKeychainService = "dev.cirrus.connections"
    private static let markerName = ".migrated-from-cirrus"

    /// Runs once, before anything reads settings. Safe to call repeatedly.
    public static func runIfNeeded() {
        let marker = AppPaths.support.appendingPathComponent(markerName)
        guard !FileManager.default.fileExists(atPath: marker.path) else { return }

        let movedFiles = migrateSupportFiles()
        let movedSecrets = migrateSecrets()

        try? Data().write(to: marker)
        if movedFiles > 0 || movedSecrets > 0 {
            print("[openborld] migrated \(movedFiles) settings file(s) and \(movedSecrets) credential(s) from Cirrus")
        }
    }

    /// Copies, rather than moves, the old settings: if anything goes wrong the
    /// previous install is still intact and openable.
    private static func migrateSupportFiles() -> Int {
        let fm = FileManager.default
        let legacy = AppPaths.support
            .deletingLastPathComponent()
            .appendingPathComponent(legacyFolderName, isDirectory: true)
        guard fm.fileExists(atPath: legacy.path) else { return 0 }

        var copied = 0
        let names = ["connections.json", "settings.json", "places.json", "history.json"]
        for name in names {
            let source = legacy.appendingPathComponent(name)
            let destination = AppPaths.support.appendingPathComponent(name)
            guard fm.fileExists(atPath: source.path),
                  !fm.fileExists(atPath: destination.path)
            else { continue }
            do {
                try fm.copyItem(at: source, to: destination)
                copied += 1
            } catch {
                continue
            }
        }
        return copied
    }

    /// Re-saves each connection's secrets under the new service name.
    private static func migrateSecrets() -> Int {
        #if canImport(Security)
        guard let connections = JSONFile.read(
            [Connection].self, from: AppPaths.connectionsFile
        ) else { return 0 }

        var moved = 0
        for connection in connections {
            let existing = (try? Secrets.store.load(connection.id)) ?? ConnectionSecrets()
            guard existing.isEmpty else { continue }
            guard let legacy = readLegacyKeychain(connection.id), !legacy.isEmpty else {
                continue
            }
            do {
                try Secrets.store.save(legacy, for: connection.id)
                moved += 1
            } catch {
                continue
            }
        }
        return moved
        #else
        return 0
        #endif
    }

    #if canImport(Security)
    private static func readLegacyKeychain(_ id: UUID) -> ConnectionSecrets? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: legacyKeychainService,
            kSecAttrAccount as String: id.uuidString,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data
        else { return nil }
        return try? JSONDecoder().decode(ConnectionSecrets.self, from: data)
    }
    #endif
}
