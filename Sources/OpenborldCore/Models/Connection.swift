import Foundation

/// A saved storage account. Non-secret settings live here and are persisted to
/// disk as JSON; secrets live in the Keychain under the connection's id and are
/// loaded only when a provider is actually built.
public struct Connection: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var kind: ProviderKind
    /// Non-secret settings — account name, region, endpoint, auth method, etc.
    public var settings: [String: String]
    public var createdAt: Date
    public var lastUsedAt: Date?
    /// Index into `Connection.tagColors`, for a colour chip in the sidebar.
    public var tagColorIndex: Int?

    public init(
        id: UUID = UUID(),
        name: String,
        kind: ProviderKind,
        settings: [String: String] = [:],
        createdAt: Date = Date(),
        lastUsedAt: Date? = nil,
        tagColorIndex: Int? = nil
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.settings = settings
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
        self.tagColorIndex = tagColorIndex
    }

    public subscript(key: SettingKey) -> String? {
        get { settings[key.rawValue] }
        set {
            if let newValue, !newValue.isEmpty { settings[key.rawValue] = newValue }
            else { settings.removeValue(forKey: key.rawValue) }
        }
    }

    public func setting(_ key: SettingKey, default fallback: String = "") -> String {
        settings[key.rawValue] ?? fallback
    }

    public func boolSetting(_ key: SettingKey, default fallback: Bool = false) -> Bool {
        guard let raw = settings[key.rawValue] else { return fallback }
        return raw == "true" || raw == "1" || raw == "yes"
    }

    public func intSetting(_ key: SettingKey) -> Int? {
        settings[key.rawValue].flatMap(Int.init)
    }

    public static let tagColors = [
        "blue", "purple", "pink", "red", "orange", "yellow", "green", "teal", "gray",
    ]
}

/// Keys used in `Connection.settings`. One shared namespace keeps the
/// credential forms and the providers from drifting apart on spelling.
public enum SettingKey: String, Sendable {
    /// Which authentication path to use; values are provider-specific enums
    /// such as `AzureAuthMethod`.
    case authMethod

    // Azure
    case accountName
    case blobEndpoint
    case containerScope      // connection is scoped to this single container
    case sasToken

    // S3 / S3-compatible
    case accessKeyID
    case region
    case endpoint
    case usePathStyle
    case bucketScope

    // Hosts / protocols
    case host
    case port
    case username
    case basePath
    case useTLS
    case allowInsecureTLS

    // Local
    case rootPath
    case showHiddenFiles

    // Transfer tuning (per connection, overriding global defaults)
    case maxConcurrentTransfers
    case chunkSizeBytes
    /// Size above which an upload is split into chunks rather than sent in one request.
    case multipartThresholdBytes
}

/// The secret half of a connection, stored in the Keychain as one JSON blob.
public struct ConnectionSecrets: Codable, Sendable, Hashable {
    public var values: [String: String]

    public init(values: [String: String] = [:]) { self.values = values }

    public subscript(key: SecretKey) -> String? {
        get { values[key.rawValue] }
        set {
            if let newValue, !newValue.isEmpty { values[key.rawValue] = newValue }
            else { values.removeValue(forKey: key.rawValue) }
        }
    }

    public func secret(_ key: SecretKey) -> String? { values[key.rawValue] }

    public var isEmpty: Bool { values.isEmpty }
}

public enum SecretKey: String, Sendable {
    case accountKey
    case connectionString
    case sasToken
    case sasURL
    case secretAccessKey
    case sessionToken
    case password
    case privateKey
    case privateKeyPassphrase
    case refreshToken
    case accessToken
    case applicationKey
}
