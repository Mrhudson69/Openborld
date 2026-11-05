import Foundation
import Crypto

#if canImport(FoundationNetworking)
// On Linux and Windows, Foundation is split and the URL loading system lives
// in its own module.
import FoundationNetworking
#endif

/// AWS Signature Version 4.
///
/// Hand-rolled rather than pulled from the AWS SDK: the SDK is a large
/// dependency for what amounts to a few hundred lines, and SigV4 is also what
/// unlocks every S3-compatible provider — Backblaze, Google's interop endpoint,
/// MinIO, Wasabi, R2 — through the same code.
public enum SigV4 {
    /// The canonical request from the most recent signature, for diffing
    /// against a service that rejected it.
    public static let lastCanonicalRequest = Locked("")

    static let algorithm = "AWS4-HMAC-SHA256"
    static let unsignedPayload = "UNSIGNED-PAYLOAD"
    static let emptyBodySHA256 =
        "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

    public struct Credentials: Sendable {
        public var accessKeyID: String
        public var secretAccessKey: String
        public var sessionToken: String?

        public init(accessKeyID: String, secretAccessKey: String, sessionToken: String? = nil) {
            self.accessKeyID = accessKeyID
            self.secretAccessKey = secretAccessKey
            self.sessionToken = sessionToken
        }
    }

    /// Signs a request in place using the `Authorization` header form.
    ///
    /// `payloadHash` is the hex SHA-256 of the body, or `UNSIGNED-PAYLOAD` when
    /// the body is a file we'd rather not read twice just to hash it — allowed
    /// because the connection is TLS.
    static func sign(
        request: inout URLRequest,
        credentials: Credentials,
        region: String,
        service: String = "s3",
        payloadHash: String,
        now: Date = Date()
    ) throws {
        guard let url = request.url, let host = url.host else {
            throw StorageError.invalidConfiguration("Can't sign a request without a host.")
        }

        let timestamp = HTTPDate.iso8601Basic(now)
        let day = HTTPDate.yyyymmdd(now)

        request.setValue(host + (url.port.map { ":\($0)" } ?? ""), forHTTPHeaderField: "Host")
        request.setValue(timestamp, forHTTPHeaderField: "x-amz-date")
        request.setValue(payloadHash, forHTTPHeaderField: "x-amz-content-sha256")
        if let token = credentials.sessionToken, !token.isEmpty {
            request.setValue(token, forHTTPHeaderField: "x-amz-security-token")
        }

        let headers = request.allHTTPHeaderFields ?? [:]
        // Sign host, x-amz-*, and content-type. Anything else risks a mismatch
        // when URLSession rewrites a header we don't control.
        let signable = headers.filter { key, _ in
            let lower = key.lowercased()
            return lower == "host" || lower == "content-type" || lower == "content-md5"
                || lower.hasPrefix("x-amz-")
        }
        let sorted = signable
            .map { (name: $0.key.lowercased(), value: trim($0.value)) }
            .sorted { $0.name < $1.name }

        let canonicalHeaders = sorted.map { "\($0.name):\($0.value)\n" }.joined()
        let signedHeaders = sorted.map(\.name).joined(separator: ";")

        let canonicalRequest = [
            request.httpMethod ?? "GET",
            canonicalURI(url),
            canonicalQuery(url),
            canonicalHeaders,
            signedHeaders,
            payloadHash,
        ].joined(separator: "\n")

        lastCanonicalRequest.set(canonicalRequest)

        let scope = "\(day)/\(region)/\(service)/aws4_request"
        let stringToSign = [
            algorithm,
            timestamp,
            scope,
            sha256Hex(Data(canonicalRequest.utf8)),
        ].joined(separator: "\n")

        let signingKey = derivedKey(
            secret: credentials.secretAccessKey,
            day: day,
            region: region,
            service: service
        )
        let signature = hmac(key: signingKey, data: Data(stringToSign.utf8)).hexString

        request.setValue(
            "\(algorithm) Credential=\(credentials.accessKeyID)/\(scope), "
                + "SignedHeaders=\(signedHeaders), Signature=\(signature)",
            forHTTPHeaderField: "Authorization"
        )
    }

    /// Builds a presigned GET URL — a link anyone can open until it expires.
    static func presignedURL(
        url: URL,
        method: String = "GET",
        credentials: Credentials,
        region: String,
        service: String = "s3",
        expiresIn: TimeInterval,
        now: Date = Date()
    ) throws -> URL {
        guard let host = url.host else {
            throw StorageError.invalidConfiguration("Can't presign a URL without a host.")
        }
        let timestamp = HTTPDate.iso8601Basic(now)
        let day = HTTPDate.yyyymmdd(now)
        let scope = "\(day)/\(region)/\(service)/aws4_request"
        let hostHeader = host + (url.port.map { ":\($0)" } ?? "")

        var items: [(String, String)] = [
            ("X-Amz-Algorithm", algorithm),
            ("X-Amz-Credential", "\(credentials.accessKeyID)/\(scope)"),
            ("X-Amz-Date", timestamp),
            ("X-Amz-Expires", String(Int(max(1, min(expiresIn, 604_800))))),
            ("X-Amz-SignedHeaders", "host"),
        ]
        if let token = credentials.sessionToken, !token.isEmpty {
            items.append(("X-Amz-Security-Token", token))
        }
        // Preserve any query already on the URL, e.g. a response-content-type.
        if let existing = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems {
            for item in existing { items.append((item.name, item.value ?? "")) }
        }

        let canonicalQueryString = URIEncoding.canonicalQuery(items)
        let canonicalRequest = [
            method,
            canonicalURI(url),
            canonicalQueryString,
            "host:\(hostHeader)\n",
            "host",
            unsignedPayload,
        ].joined(separator: "\n")

        let stringToSign = [
            algorithm, timestamp, scope, sha256Hex(Data(canonicalRequest.utf8)),
        ].joined(separator: "\n")

        let signingKey = derivedKey(
            secret: credentials.secretAccessKey, day: day, region: region, service: service
        )
        let signature = hmac(key: signingKey, data: Data(stringToSign.utf8)).hexString

        var base = url.absoluteString
        if let hashIndex = base.firstIndex(of: "?") { base = String(base[base.startIndex..<hashIndex]) }
        let final = base + "?" + canonicalQueryString + "&X-Amz-Signature=" + signature
        guard let result = URL(string: final) else {
            throw StorageError.provider("Couldn't build a presigned URL.")
        }
        return result
    }

    // MARK: - Canonicalisation

    /// The path, percent-encoded per segment with separators preserved. S3
    /// expects single encoding here, which is why this doesn't reuse whatever
    /// escaping the URL already carries.
    private static func canonicalURI(_ url: URL) -> String {
        // Must preserve a trailing slash: `PUT /bucket/` is a different
        // canonical request from `PUT /bucket`, and `URL.path` drops it.
        let path = url.path(percentEncoded: false)
        guard !path.isEmpty else { return "/" }
        let segments = path.split(separator: "/", omittingEmptySubsequences: false)
        let encoded = segments.map { URIEncoding.encode(String($0), encodeSlash: true) }
        let joined = encoded.joined(separator: "/")
        return joined.hasPrefix("/") ? joined : "/" + joined
    }

    private static func canonicalQuery(_ url: URL) -> String {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = components.percentEncodedQueryItems, !items.isEmpty
        else { return "" }
        // Decode then re-encode: the incoming escaping may not match SigV4's rules.
        let pairs = items.map { item -> (String, String) in
            let name = item.name.removingPercentEncoding ?? item.name
            let value = (item.value ?? "").removingPercentEncoding ?? (item.value ?? "")
            return (name, value)
        }
        return URIEncoding.canonicalQuery(pairs)
    }

    private static func trim(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0 == " " || $0 == "\t" })
            .joined(separator: " ")
    }

    // MARK: - Crypto

    static func sha256Hex(_ data: Data) -> String {
        Data(SHA256.hash(data: data)).hexString
    }

    private static func hmac(key: Data, data: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: key)))
    }

    private static func derivedKey(
        secret: String, day: String, region: String, service: String
    ) -> Data {
        var key = hmac(key: Data("AWS4\(secret)".utf8), data: Data(day.utf8))
        key = hmac(key: key, data: Data(region.utf8))
        key = hmac(key: key, data: Data(service.utf8))
        return hmac(key: key, data: Data("aws4_request".utf8))
    }
}

/// Resolved addressing and credentials for an S3-family connection.
public struct S3Config: Sendable {
    public var endpoint: URL
    public var region: String
    public var credentials: SigV4.Credentials
    /// Path-style puts the bucket in the path rather than the hostname. Required
    /// by most non-AWS endpoints and by any bucket whose name isn't DNS-safe.
    public var usePathStyle: Bool
    /// When set, the connection is rooted inside this one bucket.
    public var bucketScope: String?

    public init(
        endpoint: URL,
        region: String,
        credentials: SigV4.Credentials,
        usePathStyle: Bool,
        bucketScope: String? = nil
    ) {
        self.endpoint = endpoint
        self.region = region
        self.credentials = credentials
        self.usePathStyle = usePathStyle
        self.bucketScope = bucketScope
    }

    public var isBucketScoped: Bool { bucketScope != nil }

    public func resolve(_ path: RemotePath) -> (bucket: String?, key: String) {
        if let scope = bucketScope {
            return (scope, path.joined)
        }
        guard let bucket = path.first else { return (nil, "") }
        return (bucket, path.droppingFirst.joined)
    }

    public func path(bucket: String, key: String) -> RemotePath {
        let components = key.split(separator: "/").map(String.init)
        return isBucketScoped
            ? RemotePath(components: components)
            : RemotePath(components: [bucket] + components)
    }

    /// Builds the URL for a bucket/key under the connection's addressing style.
    public func url(bucket: String?, key: String, query: [(String, String)]) throws -> URL {
        var string: String
        if let bucket, !usePathStyle {
            guard let scheme = endpoint.scheme, let host = endpoint.host else {
                throw StorageError.invalidConfiguration("The endpoint is missing a scheme or host.")
            }
            string = "\(scheme)://\(bucket).\(host)"
            if let port = endpoint.port { string += ":\(port)" }
        } else {
            string = endpoint.absoluteString
            if string.hasSuffix("/") { string.removeLast() }
            if let bucket { string += "/" + bucket.pathSegmentEncoded }
        }
        string += "/"
        if !key.isEmpty { string += key.objectKeyEncoded }

        if !query.isEmpty {
            string += "?" + query
                .map { $0.1.isEmpty ? URIEncoding.encode($0.0) : "\(URIEncoding.encode($0.0))=\(URIEncoding.encode($0.1))" }
                .joined(separator: "&")
        }
        guard let url = URL(string: string) else {
            throw StorageError.invalidConfiguration("Couldn't build a URL for \(key).")
        }
        return url
    }

    public static func make(connection: Connection, secrets: ConnectionSecrets) throws -> S3Config {
        let accessKey = connection.setting(.accessKeyID)
        guard !accessKey.isEmpty else {
            throw StorageError.invalidConfiguration("Enter the access key ID.")
        }
        guard let secret = secrets[.secretAccessKey] ?? secrets[.applicationKey], !secret.isEmpty else {
            throw StorageError.invalidConfiguration("This connection has no secret key saved.")
        }

        let region = connection.setting(.region, default: defaultRegion(for: connection.kind))
        let endpoint = try resolveEndpoint(connection: connection, region: region)
        // AWS prefers virtual-hosted addressing; nearly everything else needs
        // path style, so that's the default outside AWS.
        let pathStyleDefault = connection.kind != .s3
        return S3Config(
            endpoint: endpoint,
            region: region,
            credentials: SigV4.Credentials(
                accessKeyID: accessKey,
                secretAccessKey: secret,
                sessionToken: secrets[.sessionToken]
            ),
            usePathStyle: connection.boolSetting(.usePathStyle, default: pathStyleDefault),
            bucketScope: connection[.bucketScope]
        )
    }

    private static func defaultRegion(for kind: ProviderKind) -> String {
        switch kind {
        case .gcs: "auto"
        case .backblazeB2: "us-west-004"
        default: "us-east-1"
        }
    }

    private static func resolveEndpoint(connection: Connection, region: String) throws -> URL {
        if let explicit = connection[.endpoint], !explicit.isEmpty {
            var value = explicit.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.contains("://") { value = "https://" + value }
            guard let url = URL(string: value), url.host != nil else {
                throw StorageError.invalidConfiguration("That endpoint isn't a valid URL.")
            }
            return url
        }

        let host: String
        switch connection.kind {
        case .s3:
            host = region == "us-east-1" ? "s3.amazonaws.com" : "s3.\(region).amazonaws.com"
        case .gcs:
            host = "storage.googleapis.com"
        case .backblazeB2:
            host = "s3.\(region).backblazeb2.com"
        default:
            throw StorageError.invalidConfiguration(
                "Enter the storage endpoint, for example https://s3.example.com"
            )
        }
        guard let url = URL(string: "https://\(host)") else {
            throw StorageError.invalidConfiguration("Couldn't build an endpoint for \(region).")
        }
        return url
    }
}
