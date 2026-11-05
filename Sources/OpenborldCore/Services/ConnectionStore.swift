import Foundation
import Observation

/// Live state of a connection, shown as a dot next to it in the sidebar.
public enum ConnectionStatus: Equatable, Sendable {
    case idle
    case connecting
    case connected
    case failed(String)

    public var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }

    public var message: String? {
        if case .failed(let message) = self { return message }
        return nil
    }
}

/// The saved connections, their status, and the credential side-channel.
///
/// Settings are plain JSON on disk; secrets never appear in it — they go to the
/// Keychain keyed by connection id.
@MainActor
@Observable
public final class ConnectionStore {
    public private(set) var connections: [Connection] = []
    public private(set) var status: [UUID: ConnectionStatus] = [:]

    /// The built-in "This Mac" connection. Always present, never persisted,
    /// so it can't be deleted or broken by a bad edit.
    public let local: Connection

    private let registry = ProviderRegistry.shared

    /// Set when the connections file existed but could not be read.
    ///
    /// While this is non-nil the store refuses to save, so a bad read can
    /// never be laundered into an empty file by the next write.
    public private(set) var loadFailure: String?

    public init() {
        self.local = LocalProvider.mac().connection

        switch JSONFile.load([Connection].self, from: AppPaths.connectionsFile) {
        case .missing:
            self.connections = []
        case .decoded(let saved):
            self.connections = saved
        case .corrupt(let error, let backup):
            self.connections = []
            let location = backup.map { " A copy was kept at \($0.lastPathComponent)." } ?? ""
            self.loadFailure = "Your saved connections couldn't be read: "
                + "\(error.localizedDescription)\(location) "
                + "Saving is paused so the file isn't overwritten."
        }

        status[local.id] = .connected
    }

    /// Everything selectable in the UI, with the Mac first.
    public var all: [Connection] {
        [local] + connections
    }

    public func connection(id: UUID) -> Connection? {
        id == local.id ? local : connections.first { $0.id == id }
    }

    public func status(of id: UUID) -> ConnectionStatus {
        status[id] ?? .idle
    }

    /// Connections grouped by provider, for the sidebar.
    public var grouped: [(kind: ProviderKind, connections: [Connection])] {
        let groups = Dictionary(grouping: connections, by: \.kind)
        return groups
            .map { (kind: $0.key, connections: $0.value.sorted { $0.name < $1.name }) }
            .sorted { $0.kind.displayName < $1.kind.displayName }
    }

    // MARK: - Mutations

    public func add(_ connection: Connection, secrets: ConnectionSecrets) throws {
        try Keychain.save(secrets, for: connection.id)
        connections.append(connection)
        persist()
    }

    public func update(_ connection: Connection, secrets: ConnectionSecrets?) throws {
        if let secrets {
            try Keychain.save(secrets, for: connection.id)
        }
        if let index = connections.firstIndex(where: { $0.id == connection.id }) {
            connections[index] = connection
        } else {
            connections.append(connection)
        }
        persist()

        // The live provider holds the old credentials and endpoint, so it has
        // to go; the next navigation builds a fresh one.
        let id = connection.id
        status[id] = .idle
        Task {
            await registry.invalidate(id)
            await ListingCache.shared.clear(connection: id)
        }
    }

    public func remove(_ id: UUID) {
        guard id != local.id else { return }
        connections.removeAll { $0.id == id }
        status.removeValue(forKey: id)
        persist()
        try? Keychain.delete(id)
        Task {
            await registry.invalidate(id)
            await ListingCache.shared.clear(connection: id)
        }
    }

    public func rename(_ id: UUID, to name: String) {
        guard let index = connections.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        connections[index].name = trimmed
        persist()
    }

    public func markUsed(_ id: UUID) {
        guard let index = connections.firstIndex(where: { $0.id == id }) else { return }
        connections[index].lastUsedAt = Date()
        // Deliberately not persisted on every navigation; saved on quit instead.
    }

    public func secrets(for id: UUID) -> ConnectionSecrets {
        (try? Keychain.load(id)) ?? ConnectionSecrets()
    }

    // MARK: - Status

    public func setStatus(_ newStatus: ConnectionStatus, for id: UUID) {
        status[id] = newStatus
    }

    /// Re-validates a connection, which is what the sidebar's Reconnect does.
    public func reconnect(_ id: UUID) {
        guard let connection = connection(id: id) else { return }
        status[id] = .connecting
        Task {
            await registry.invalidate(id)
            do {
                let provider = try await registry.provider(for: connection)
                try await provider.validate()
                status[id] = .connected
            } catch {
                status[id] = .failed(TransferManager.describe(error))
            }
        }
    }

    public func persist() {
        // Never overwrite a file we failed to read.
        guard loadFailure == nil else { return }
        let snapshot = connections
        Task.detached(priority: .utility) {
            let target = AppPaths.connectionsFile
            // Keep one generation back. Writing connections is rare and the
            // cost of the copy is nothing against losing an account's details.
            if FileManager.default.fileExists(atPath: target.path) {
                let backup = target.deletingPathExtension().appendingPathExtension("bak.json")
                try? FileManager.default.removeItem(at: backup)
                try? FileManager.default.copyItem(at: target, to: backup)
            }
            try? JSONFile.write(snapshot, to: target)
        }
    }

    /// Clears the read error after the user has dealt with the bad file,
    /// re-enabling saves.
    public func dismissLoadFailure() {
        loadFailure = nil
    }

    /// A unique display name, so three Azure connections don't all read "Azure".
    public func uniqueName(basedOn candidate: String) -> String {
        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmed.isEmpty ? "Connection" : trimmed
        let existing = Set(all.map(\.name))
        guard existing.contains(base) else { return base }
        for suffix in 2...100 {
            let candidate = "\(base) \(suffix)"
            if !existing.contains(candidate) { return candidate }
        }
        return base + " " + UUID().uuidString.prefix(4)
    }
}
