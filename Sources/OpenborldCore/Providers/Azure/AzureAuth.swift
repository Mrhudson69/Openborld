import Foundation
import Crypto

#if canImport(FoundationNetworking)
// On Linux and Windows, Foundation is split and the URL loading system lives
// in its own module.
import FoundationNetworking
#endif

/// How the user chose to authenticate to Azure. Stored in
/// `Connection.settings[.authMethod]`.
public enum AzureAuthMethod: String, CaseIterable, Sendable, Identifiable {
    /// A complete container (or blob-prefix) URL with a SAS token appended. The
    /// fastest path in: no account, no keys, nothing else to fill in.
    case sasURL
    case accountKey
    case connectionString
    case accountURLAndSAS
    /// Azure AD workload identity. Only usable when running on Azure
    /// infrastructure that exposes the IMDS endpoint.
    case managedIdentity

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .sasURL: "SAS URL"
        case .accountKey: "Account Name + Key"
        case .connectionString: "Connection String"
        case .accountURLAndSAS: "Account URL + SAS Token"
        case .managedIdentity: "Managed Identity"
        }
    }

    public var detail: String {
        switch self {
        case .sasURL:
            "Paste a container URL that already includes its SAS token. Nothing else needed."
        case .accountKey:
            "Full access to the storage account using its access key."
        case .connectionString:
            "The connection string from the Azure portal, under Access keys."
        case .accountURLAndSAS:
            "The account's blob endpoint plus a separate SAS token."
        case .managedIdentity:
            "Uses the identity of the Azure host this app runs on. Not available on a local Mac."
        }
    }

    public var isAvailable: Bool { self != .managedIdentity }
}

public enum AzureCredential: Sendable {
    /// Shared key: every request is signed with HMAC-SHA256.
    case sharedKey(account: String, key: Data)
    /// A pre-signed token appended to each URL as a query string.
    case sas(token: String)

    public var canMintSAS: Bool {
        if case .sharedKey = self { return true }
        return false
    }
}

/// Everything the provider needs to address and sign a request, resolved once
/// from whichever auth method the user picked.
public struct AzureConfig: Sendable {
    /// e.g. `https://myaccount.blob.core.windows.net`
    public var blobEndpoint: URL
    public var accountName: String
    public var credential: AzureCredential
    /// When set, the connection is rooted inside this single container and the
    /// user never sees a container list — which is what a SAS container URL gives.
    public var containerScope: String?
    /// Extra key prefix the connection is rooted at, without a trailing slash.
    public var basePrefix: String

    public var isContainerScoped: Bool { containerScope != nil }

    /// Resolves a UI path into (container, blob key).
    ///
    /// Account-scoped: the first component is the container. Container-scoped:
    /// the whole path is a key inside the fixed container.
    public func resolve(_ path: RemotePath) -> (container: String?, key: String) {
        var components = path.components
        if let scope = containerScope {
            let key = (basePrefix.isEmpty ? components : [basePrefix] + components)
                .joined(separator: "/")
            return (scope, key)
        }
        guard let container = components.first else { return (nil, "") }
        components.removeFirst()
        return (container, components.joined(separator: "/"))
    }

    /// Inverse of `resolve`, for turning an API result back into a UI path.
    public func path(container: String, key: String) -> RemotePath {
        var components = key.split(separator: "/").map(String.init)
        if isContainerScoped {
            if !basePrefix.isEmpty {
                let baseComponents = basePrefix.split(separator: "/").map(String.init)
                if Array(components.prefix(baseComponents.count)) == baseComponents {
                    components.removeFirst(baseComponents.count)
                }
            }
            return RemotePath(components: components)
        }
        return RemotePath(components: [container] + components)
    }
}

public enum AzureAuth {
    /// The string-to-sign from the most recent SharedKey signature.
    ///
    /// Kept so a rejected request can be diffed against what the service
    /// expected. A 403 on its own says nothing about which field differed.
    public static let lastStringToSign = Locked("")

    public static let apiVersion = "2023-11-03"
    public static let sasVersion = "2021-12-02"

    // MARK: - Config resolution

    /// Builds a usable config from a saved connection plus its Keychain secrets.
    /// Every validation failure here is a message the user can act on, which is
    /// why the errors name the specific field.
    public static func makeConfig(connection: Connection, secrets: ConnectionSecrets) throws -> AzureConfig {
        let method = AzureAuthMethod(rawValue: connection.setting(.authMethod))
            ?? .sasURL

        switch method {
        case .sasURL:
            guard let raw = secrets[.sasURL] ?? secrets[.sasToken], !raw.isEmpty else {
                throw StorageError.invalidConfiguration("This connection has no SAS URL saved.")
            }
            return try parseSASURL(raw)

        case .accountKey:
            let account = connection.setting(.accountName)
            guard !account.isEmpty else {
                throw StorageError.invalidConfiguration("Enter the storage account name.")
            }
            guard let keyBase64 = secrets[.accountKey], !keyBase64.isEmpty else {
                throw StorageError.invalidConfiguration("This connection has no account key saved.")
            }
            guard let key = Data(base64Encoded: keyBase64.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                throw StorageError.invalidConfiguration(
                    "The account key isn't valid base64. Copy it again from the Azure portal."
                )
            }
            let endpoint = try resolveEndpoint(
                explicit: connection[.blobEndpoint],
                account: account
            )
            return AzureConfig(
                blobEndpoint: endpoint,
                accountName: account,
                credential: .sharedKey(account: account, key: key),
                containerScope: connection[.containerScope],
                basePrefix: ""
            )

        case .connectionString:
            guard let raw = secrets[.connectionString], !raw.isEmpty else {
                throw StorageError.invalidConfiguration("This connection has no connection string saved.")
            }
            var config = try parseConnectionString(raw)
            if let scope = connection[.containerScope] { config.containerScope = scope }
            return config

        case .accountURLAndSAS:
            let urlString = connection.setting(.blobEndpoint)
            guard !urlString.isEmpty, let url = URL(string: urlString), url.host != nil else {
                throw StorageError.invalidConfiguration(
                    "Enter the account's blob endpoint, for example https://myaccount.blob.core.windows.net"
                )
            }
            guard let token = secrets[.sasToken], !token.isEmpty else {
                throw StorageError.invalidConfiguration("This connection has no SAS token saved.")
            }
            let endpoint = normalizeEndpoint(url)
            return AzureConfig(
                blobEndpoint: endpoint,
                accountName: accountName(fromHost: endpoint.host) ?? "",
                credential: .sas(token: normalizeSASToken(token)),
                containerScope: connection[.containerScope],
                basePrefix: ""
            )

        case .managedIdentity:
            throw StorageError.unsupported(
                "Managed Identity needs to run on Azure infrastructure, so it isn't available here. Use a SAS URL or account key instead."
            )
        }
    }

    /// Parses a pasted SAS URL. Accepts an account-level URL, a container URL,
    /// or a container URL with a folder prefix, with or without a leading `?`.
    public static func parseSASURL(_ raw: String) throws -> AzureConfig {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let host = url.host, url.scheme != nil else {
            throw StorageError.invalidConfiguration("That doesn't look like a URL.")
        }
        guard let query = url.query, !query.isEmpty else {
            throw StorageError.invalidConfiguration(
                "That URL has no SAS token. A SAS URL ends with a query string starting with sv=."
            )
        }
        guard query.contains("sig=") else {
            throw StorageError.invalidConfiguration(
                "That URL's query string has no signature (sig=), so it isn't a SAS URL."
            )
        }

        var pathComponents = url.path(percentEncoded: false)
            .split(separator: "/")
            .map { $0.removingPercentEncoding ?? String($0) }

        // Standard Azure carries the account in the hostname. Azurite and
        // path-addressed gateways put it in the first path segment instead.
        var account = accountName(fromHost: host) ?? ""
        var accountIsInPath = false
        if account.isEmpty, let first = pathComponents.first {
            account = first
            pathComponents.removeFirst()
            accountIsInPath = true
        }

        var endpointComponents = URLComponents()
        endpointComponents.scheme = url.scheme
        endpointComponents.host = host
        endpointComponents.port = url.port
        // The account segment has to stay on the endpoint, or every later
        // request addresses `/container` instead of `/account/container`.
        if accountIsInPath {
            endpointComponents.path = "/" + account
        }
        guard let endpoint = endpointComponents.url else {
            throw StorageError.invalidConfiguration("Couldn't read the account endpoint from that URL.")
        }

        let container = pathComponents.first
        let prefix = pathComponents.dropFirst().joined(separator: "/")

        return AzureConfig(
            blobEndpoint: endpoint,
            accountName: account,
            credential: .sas(token: normalizeSASToken(query)),
            containerScope: container,
            basePrefix: prefix
        )
    }

    /// Parses an Azure storage connection string in either of its two shapes:
    /// account key, or an embedded SAS.
    public static func parseConnectionString(_ raw: String) throws -> AzureConfig {
        var fields: [String: String] = [:]
        for pair in raw.split(separator: ";") {
            // Split on the first `=` only: keys and SAS values both contain them.
            guard let separator = pair.firstIndex(of: "=") else { continue }
            let key = pair[pair.startIndex..<separator].trimmingCharacters(in: .whitespaces)
            let value = String(pair[pair.index(after: separator)...])
                .trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, !value.isEmpty else { continue }
            fields[key.lowercased()] = value
        }
        guard !fields.isEmpty else {
            throw StorageError.invalidConfiguration("That connection string couldn't be parsed.")
        }

        let account = fields["accountname"] ?? ""
        let scheme = fields["defaultendpointsprotocol"] ?? "https"
        let suffix = fields["endpointsuffix"] ?? "core.windows.net"

        let endpoint: URL
        if let explicit = fields["blobendpoint"], let url = URL(string: explicit) {
            endpoint = normalizeEndpoint(url)
        } else if !account.isEmpty, let url = URL(string: "\(scheme)://\(account).blob.\(suffix)") {
            endpoint = url
        } else {
            throw StorageError.invalidConfiguration(
                "The connection string needs either AccountName or BlobEndpoint."
            )
        }

        if let sas = fields["sharedaccesssignature"] {
            return AzureConfig(
                blobEndpoint: endpoint,
                accountName: account.isEmpty ? (accountName(fromHost: endpoint.host) ?? "") : account,
                credential: .sas(token: normalizeSASToken(sas)),
                containerScope: nil,
                basePrefix: ""
            )
        }

        guard let keyRaw = fields["accountkey"] else {
            throw StorageError.invalidConfiguration(
                "The connection string needs either AccountKey or SharedAccessSignature."
            )
        }
        guard let key = Data(base64Encoded: keyRaw) else {
            throw StorageError.invalidConfiguration("The AccountKey in that connection string isn't valid base64.")
        }
        guard !account.isEmpty else {
            throw StorageError.invalidConfiguration("The connection string needs AccountName to sign requests.")
        }
        return AzureConfig(
            blobEndpoint: endpoint,
            accountName: account,
            credential: .sharedKey(account: account, key: key),
            containerScope: nil,
            basePrefix: ""
        )
    }

    static func resolveEndpoint(explicit: String?, account: String) throws -> URL {
        if let explicit, !explicit.isEmpty {
            guard let url = URL(string: explicit), url.host != nil else {
                throw StorageError.invalidConfiguration("That blob endpoint isn't a valid URL.")
            }
            return normalizeEndpoint(url)
        }
        guard let url = URL(string: "https://\(account).blob.core.windows.net") else {
            throw StorageError.invalidConfiguration("That account name can't be turned into an endpoint.")
        }
        return url
    }

    /// Strips any path and query so the endpoint is just scheme://host[:port].
    static func normalizeEndpoint(_ url: URL) -> URL {
        var components = URLComponents()
        components.scheme = url.scheme ?? "https"
        components.host = url.host
        components.port = url.port
        // Azurite-style endpoints carry the account in the path; keep it.
        let path = url.path.split(separator: "/").map(String.init)
        if path.count == 1, url.host == "127.0.0.1" || url.host == "localhost" {
            components.path = "/" + path[0]
        }
        return components.url ?? url
    }

    static func accountName(fromHost host: String?) -> String? {
        guard let host, let first = host.split(separator: ".").first,
              host.contains(".blob."), !first.isEmpty
        else { return nil }
        return String(first)
    }

    /// Normalises a SAS token to a bare query string with no leading `?` or `&`.
    public static func normalizeSASToken(_ token: String) -> String {
        var value = token.trimmingCharacters(in: .whitespacesAndNewlines)
        // Users often paste a whole URL into the token field.
        if value.lowercased().hasPrefix("http"), let url = URL(string: value), let query = url.query {
            value = query
        }
        while value.hasPrefix("?") || value.hasPrefix("&") { value.removeFirst() }
        return value
    }

    // MARK: - SharedKey request signing

    /// Signs a request in place with the account key, per Azure's SharedKey
    /// scheme for the Blob service.
    static func signSharedKey(
        request: inout URLRequest,
        account: String,
        key: Data,
        contentLength: Int64?
    ) throws {
        guard let url = request.url else {
            throw StorageError.invalidConfiguration("Can't sign a request with no URL.")
        }

        request.setValue(apiVersion, forHTTPHeaderField: "x-ms-version")
        if request.value(forHTTPHeaderField: "x-ms-date") == nil {
            request.setValue(HTTPDate.rfc1123(Date()), forHTTPHeaderField: "x-ms-date")
        }

        let headers = request.allHTTPHeaderFields ?? [:]
        func header(_ name: String) -> String {
            headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value ?? ""
        }

        // Azure wants an empty string rather than "0" for an absent body.
        let lengthField: String = {
            guard let contentLength, contentLength > 0 else { return "" }
            return String(contentLength)
        }()

        // x-ms-* headers: lowercased, sorted, whitespace-collapsed, one per line.
        let canonicalHeaders = headers
            .filter { $0.key.lowercased().hasPrefix("x-ms-") }
            .map { (key: $0.key.lowercased(), value: collapseWhitespace($0.value)) }
            .sorted { $0.key < $1.key }
            .map { "\($0.key):\($0.value)" }
            .joined(separator: "\n")

        let canonicalResource = canonicalizedResource(url: url, account: account)

        let stringToSign = [
            request.httpMethod ?? "GET",
            header("Content-Encoding"),
            header("Content-Language"),
            lengthField,
            header("Content-MD5"),
            header("Content-Type"),
            "",                                  // Date — superseded by x-ms-date
            header("If-Modified-Since"),
            header("If-Match"),
            header("If-None-Match"),
            header("If-Unmodified-Since"),
            header("Range"),
            canonicalHeaders,
        ].joined(separator: "\n") + "\n" + canonicalResource

        lastStringToSign.set(stringToSign)

        let signature = Data(
            HMAC<SHA256>.authenticationCode(
                for: Data(stringToSign.utf8),
                using: SymmetricKey(data: key)
            )
        ).base64EncodedString()

        request.setValue("SharedKey \(account):\(signature)", forHTTPHeaderField: "Authorization")
    }

    /// `/account/path` followed by one sorted, lowercased line per query parameter.
    private static func canonicalizedResource(url: URL, account: String) -> String {
        // `URL.path` silently drops a trailing slash, so an account-level
        // request signs `/account` while sending `/account/` — a signature
        // mismatch that only shows up against a real service.
        let path = url.path(percentEncoded: false)
        var resource = "/\(account)\(path.isEmpty ? "/" : path)"

        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let queryItems = components.percentEncodedQueryItems, !queryItems.isEmpty
        else { return resource }

        // Repeated parameters are merged into one comma-separated, sorted value.
        var grouped: [String: [String]] = [:]
        for item in queryItems {
            let name = item.name.lowercased()
            let value = (item.value ?? "").removingPercentEncoding ?? (item.value ?? "")
            grouped[name, default: []].append(value)
        }
        for name in grouped.keys.sorted() {
            let values = grouped[name]!.sorted().joined(separator: ",")
            resource += "\n\(name):\(values)"
        }
        return resource
    }

    private static func collapseWhitespace(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" })
            .joined(separator: " ")
    }

    // MARK: - Service SAS minting

    /// Mints a read-only service SAS for one blob, so a file can be shared as a
    /// plain link. Needs the account key; a connection that itself authenticates
    /// with a SAS can only hand back its own token.
    public static func serviceSAS(
        account: String,
        key: Data,
        container: String,
        blob: String,
        permissions: String = "r",
        expires: Date,
        startsAt: Date? = nil
    ) -> String {
        let start = startsAt.map(HTTPDate.iso8601) ?? ""
        let expiry = HTTPDate.iso8601(expires)
        let canonical = "/blob/\(account)/\(container)/\(blob)"

        // Field order is fixed by the SAS version; 2021-12-02 expects these 16.
        let stringToSign = [
            permissions,
            start,
            expiry,
            canonical,
            "",            // signed identifier
            "",            // signed IP
            "https",       // signed protocol
            sasVersion,
            "b",           // signed resource: blob
            "",            // snapshot time
            "",            // encryption scope
            "",            // rscc  Cache-Control
            "",            // rscd  Content-Disposition
            "",            // rsce  Content-Encoding
            "",            // rscl  Content-Language
            "",            // rsct  Content-Type
        ].joined(separator: "\n")

        let signature = Data(
            HMAC<SHA256>.authenticationCode(
                for: Data(stringToSign.utf8),
                using: SymmetricKey(data: key)
            )
        ).base64EncodedString()

        var items: [(String, String)] = [
            ("sv", sasVersion),
            ("sr", "b"),
            ("sp", permissions),
            ("se", expiry),
            ("spr", "https"),
            ("sig", signature),
        ]
        if !start.isEmpty { items.append(("st", start)) }

        return items
            .map { "\($0.0)=\(URIEncoding.encode($0.1))" }
            .joined(separator: "&")
    }
}
