import Foundation

#if canImport(FoundationNetworking)
// On Linux and Windows, Foundation is split and the URL loading system lives
// in its own module.
import FoundationNetworking
#endif

/// Builds a provider from a saved connection.
public enum ProviderFactory {
    public static func make(connection: Connection, secrets: ConnectionSecrets) throws -> any StorageProvider {
        switch connection.kind {
        case .local:
            return LocalProvider(connection: connection)
        case .azureBlob:
            return try AzureBlobProvider(connection: connection, secrets: secrets)
        case .s3, .s3Compatible, .backblazeB2, .gcs:
            return try S3Provider(connection: connection, secrets: secrets)
        case .webdav, .nextcloud, .ownCloud:
            return try WebDAVProvider(connection: connection, secrets: secrets)
        default:
            throw StorageError.unsupported(
                "\(connection.kind.displayName) isn't supported yet."
            )
        }
    }
}

/// Keeps one live provider per connection.
///
/// This is the single most important piece of the performance story: because the
/// provider — and with it the signed credential and the `URLSession`'s warm TLS
/// connections — is reused, changing folders costs one request rather than a
/// reconnect and a re-authentication.
public actor ProviderRegistry {
    public static let shared = ProviderRegistry()

    private var providers: [UUID: any StorageProvider] = [:]
    /// In-flight builds, so two folder loads racing on a cold connection don't
    /// each construct and validate a provider.
    private var pending: [UUID: Task<any StorageProvider, Error>] = [:]
    private var validated: Set<UUID> = []

    public init() {}

    /// Returns a ready provider, building and validating one on first use.
    public func provider(for connection: Connection) async throws -> any StorageProvider {
        if let existing = providers[connection.id] { return existing }
        if let inFlight = pending[connection.id] {
            return try await inFlight.value
        }

        let task = Task<any StorageProvider, Error> {
            let secrets = connection.kind == .local
                ? ConnectionSecrets()
                : try Keychain.load(connection.id)
            return try ProviderFactory.make(connection: connection, secrets: secrets)
        }
        pending[connection.id] = task

        do {
            let provider = try await task.value
            pending[connection.id] = nil
            providers[connection.id] = provider
            return provider
        } catch {
            pending[connection.id] = nil
            throw error
        }
    }

    /// Validates once per process, so only the first navigation into a
    /// connection pays for a credential check.
    public func validatedProvider(for connection: Connection) async throws -> any StorageProvider {
        let provider = try await self.provider(for: connection)
        guard !validated.contains(connection.id) else { return provider }
        try await provider.validate()
        validated.insert(connection.id)
        return provider
    }

    /// Call after editing a connection, so the next use picks up new credentials.
    public func invalidate(_ id: UUID) {
        providers[id] = nil
        pending[id]?.cancel()
        pending[id] = nil
        validated.remove(id)
    }

    public func invalidateAll() {
        providers.removeAll()
        pending.values.forEach { $0.cancel() }
        pending.removeAll()
        validated.removeAll()
    }

    /// Builds a throwaway provider for "Test Connection", bypassing the cache so
    /// an edit-in-progress is never mistaken for the saved connection.
    public static func test(connection: Connection, secrets: ConnectionSecrets) async throws {
        let provider = try ProviderFactory.make(connection: connection, secrets: secrets)
        try await provider.validate()
    }
}
