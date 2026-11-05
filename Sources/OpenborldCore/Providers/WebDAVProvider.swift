import Foundation

/// WebDAV, and with it Nextcloud and ownCloud — both of which are WebDAV behind
/// a provider-specific base path.
///
/// Unlike object storage this is a real filesystem: directories exist on their
/// own and MOVE is atomic, so rename and move are single requests rather than
/// copy-then-delete.
public final class WebDAVProvider: StorageProvider, @unchecked Sendable {
    public let connection: Connection
    private let baseURL: URL
    private let authorization: String
    private let http: HTTPClient

    public init(connection: Connection, secrets: ConnectionSecrets, http: HTTPClient = .shared) throws {
        self.connection = connection
        self.http = http

        let username = connection.setting(.username)
        guard let password = secrets[.password], !password.isEmpty else {
            throw StorageError.invalidConfiguration("This connection has no password saved.")
        }
        let token = Data("\(username):\(password)".utf8).base64EncodedString()
        self.authorization = "Basic \(token)"

        self.baseURL = try Self.resolveBaseURL(connection: connection, username: username)
    }

    static func resolveBaseURL(connection: Connection, username: String) throws -> URL {
        var host = connection.setting(.host).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else {
            throw StorageError.invalidConfiguration("Enter the server address.")
        }
        if !host.contains("://") {
            host = (connection.boolSetting(.useTLS, default: true) ? "https://" : "http://") + host
        }
        guard var components = URLComponents(string: host), components.host != nil else {
            throw StorageError.invalidConfiguration("That server address isn't a valid URL.")
        }
        if let port = connection.intSetting(.port) { components.port = port }

        var path = connection.setting(.basePath)
        if path.isEmpty {
            // Nextcloud and ownCloud both expose per-user files at this path;
            // asking the user to know that would be a poor first experience.
            switch connection.kind {
            case .nextcloud, .ownCloud:
                path = "/remote.php/dav/files/\(username)"
            default:
                path = components.path
            }
        }
        if !path.hasPrefix("/"), !path.isEmpty { path = "/" + path }
        while path.hasSuffix("/") { path.removeLast() }
        components.path = path
        components.query = nil

        guard let url = components.url else {
            throw StorageError.invalidConfiguration("Couldn't build the server URL.")
        }
        return url
    }

    public var kind: ProviderKind { connection.kind }

    public var capabilities: ProviderCapabilities {
        [.createFolder, .delete, .rename, .serverSideCopy, .realDirectories,
         .rangeDownload, .metadata]
    }

    // MARK: - Validate

    public func validate() async throws {
        let request = try propfindRequest(for: .root, depth: 0)
        _ = try await http.send(request, acceptableStatus: Set(200..<300).union([207]))
    }

    // MARK: - Listing

    public func list(_ path: RemotePath, cursor: String?, pageSize: Int) async throws -> Listing {
        // WebDAV has no pagination; a Depth:1 PROPFIND returns the whole folder.
        if let cursor, !cursor.isEmpty { return .empty }

        let request = try propfindRequest(for: path, depth: 1)
        let result = try await http.send(request, acceptableStatus: Set(200..<300).union([207]))
        guard let root = XMLLite.parse(result.data) else {
            throw StorageError.provider("The server's folder listing couldn't be parsed.")
        }

        let selfPath = remotePathString(for: path)
        var items: [CloudItem] = []

        for response in root.descendants(named: "response") {
            guard let href = response.string("href") else { continue }
            let decoded = (href.removingPercentEncoding ?? href)
            guard let relative = relativePath(from: decoded) else { continue }
            // The first entry is the folder itself.
            if relative.joined == path.joined { continue }
            _ = selfPath

            let prop = response.firstDescendant(named: "propstat")?.firstDescendant(named: "prop")
            let isCollection = prop?.child("resourcetype")?.child("collection") != nil

            items.append(CloudItem(
                name: relative.name,
                path: relative,
                kind: isCollection ? .folder : .file,
                size: isCollection ? nil : prop?.int64("getcontentlength"),
                modified: prop?.string("getlastmodified").flatMap(HTTPDate.parseRFC1123),
                created: prop?.string("creationdate").flatMap(HTTPDate.parseISO8601),
                etag: prop?.string("getetag")?.replacingOccurrences(of: "\"", with: ""),
                contentType: prop?.string("getcontenttype")
            ))
        }

        return Listing(items: items)
    }

    public func stat(_ path: RemotePath) async throws -> CloudItem {
        let request = try propfindRequest(for: path, depth: 0)
        let result = try await http.send(request, acceptableStatus: Set(200..<300).union([207]))
        guard let root = XMLLite.parse(result.data),
              let response = root.descendants(named: "response").first
        else { throw StorageError.notFound(path.description) }

        let prop = response.firstDescendant(named: "propstat")?.firstDescendant(named: "prop")
        let isCollection = prop?.child("resourcetype")?.child("collection") != nil
        return CloudItem(
            name: path.isRoot ? (baseURL.host ?? "Server") : path.name,
            path: path,
            kind: isCollection ? .folder : .file,
            size: isCollection ? nil : prop?.int64("getcontentlength"),
            modified: prop?.string("getlastmodified").flatMap(HTTPDate.parseRFC1123),
            etag: prop?.string("getetag")?.replacingOccurrences(of: "\"", with: ""),
            contentType: prop?.string("getcontenttype")
        )
    }

    public func metadata(_ path: RemotePath) async throws -> [(key: String, value: String)] {
        let item = try await stat(path)
        var rows: [(key: String, value: String)] = [("Path", path.description)]
        if let type = item.contentType { rows.append(("Content Type", type)) }
        if let size = item.size { rows.append(("Size", ByteFormat.bytes(size))) }
        if let modified = item.modified {
            rows.append(("Modified", DateFormatter.openborldFull.string(from: modified)))
        }
        if let etag = item.etag { rows.append(("ETag", etag)) }
        rows.append(("URL", url(for: path).absoluteString))
        return rows
    }

    // MARK: - Mutations

    public func createFolder(at path: RemotePath) async throws {
        var request = URLRequest(url: url(for: path, directory: true))
        request.httpMethod = "MKCOL"
        apply(&request)
        _ = try await http.send(request, acceptableStatus: Set(200..<300).union([405]))
    }

    public func delete(_ item: CloudItem) async throws {
        var request = URLRequest(url: url(for: item.path, directory: item.isDirectory))
        request.httpMethod = "DELETE"
        apply(&request)
        _ = try await http.send(request, acceptableStatus: Set(200..<300).union([404]))
    }

    public func deleteRecursively(_ item: CloudItem) async throws {
        // DELETE on a collection removes the whole tree.
        try await delete(item)
    }

    public func copy(_ item: CloudItem, to destination: RemotePath) async throws {
        var request = URLRequest(url: url(for: item.path, directory: item.isDirectory))
        request.httpMethod = "COPY"
        request.setValue(
            url(for: destination, directory: item.isDirectory).absoluteString,
            forHTTPHeaderField: "Destination"
        )
        request.setValue(item.isDirectory ? "infinity" : "0", forHTTPHeaderField: "Depth")
        request.setValue("T", forHTTPHeaderField: "Overwrite")
        apply(&request)
        _ = try await http.send(request)
    }

    public func move(_ item: CloudItem, to destination: RemotePath) async throws {
        var request = URLRequest(url: url(for: item.path, directory: item.isDirectory))
        request.httpMethod = "MOVE"
        request.setValue(
            url(for: destination, directory: item.isDirectory).absoluteString,
            forHTTPHeaderField: "Destination"
        )
        request.setValue("T", forHTTPHeaderField: "Overwrite")
        apply(&request)
        _ = try await http.send(request)
    }

    // MARK: - Transfer

    public func download(_ item: CloudItem, to localURL: URL, progress: ProgressHandler?) async throws {
        let existing = Self.resumeOffset(for: localURL, expecting: item.size)

        var request = URLRequest(url: url(for: item.path))
        request.httpMethod = "GET"
        apply(&request)

        let total = item.size
        try await http.download(request, to: localURL, resumeFrom: existing) { done, _ in
            progress?(existing + done, total)
        }
    }

    public func upload(
        _ localURL: URL,
        to path: RemotePath,
        contentType: String?,
        progress: ProgressHandler?
    ) async throws -> CloudItem {
        let attributes = try FileManager.default.attributesOfItem(atPath: localURL.path)
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        let type = contentType ?? MIMEType.forFilename(path.name)

        var request = URLRequest(url: url(for: path))
        request.httpMethod = "PUT"
        request.setValue(type, forHTTPHeaderField: "Content-Type")
        request.setValue(String(size), forHTTPHeaderField: "Content-Length")
        apply(&request)
        _ = try await http.upload(request, fromFile: localURL, progress: progress)

        return CloudItem(name: path.name, path: path, kind: .file,
                         size: size, modified: Date(), contentType: type)
    }

    public func readStream(_ item: CloudItem) async throws -> AsyncThrowingStream<Data, Error> {
        var request = URLRequest(url: url(for: item.path))
        request.httpMethod = "GET"
        apply(&request)
        return http.stream(request)
    }

    public func read(_ item: CloudItem, range: ClosedRange<Int64>?) async throws -> Data {
        var request = URLRequest(url: url(for: item.path))
        request.httpMethod = "GET"
        if let range {
            request.setValue("bytes=\(range.lowerBound)-\(range.upperBound)", forHTTPHeaderField: "Range")
        }
        apply(&request)
        return try await http.send(request, acceptableStatus: Set(200..<300)).data
    }

    // MARK: - Request building

    private func url(for path: RemotePath, directory: Bool = false) -> URL {
        var string = baseURL.absoluteString
        if string.hasSuffix("/") { string.removeLast() }
        for component in path.components {
            string += "/" + component.pathSegmentEncoded
        }
        if directory, !path.isRoot { string += "/" }
        return URL(string: string) ?? baseURL
    }

    private func remotePathString(for path: RemotePath) -> String {
        var string = baseURL.path
        while string.hasSuffix("/") { string.removeLast() }
        for component in path.components { string += "/" + component }
        return string
    }

    /// Turns an href from a PROPFIND response back into a path relative to the
    /// connection's root. Servers vary on whether href is absolute or rooted,
    /// so both shapes are handled.
    private func relativePath(from href: String) -> RemotePath? {
        var path = href
        if path.contains("://"), let url = URL(string: href) { path = url.path }

        var base = baseURL.path
        while base.hasSuffix("/") { base.removeLast() }
        if !base.isEmpty, path.hasPrefix(base) { path.removeFirst(base.count) }

        let components = path.split(separator: "/").map(String.init).filter { !$0.isEmpty }
        return RemotePath(components: components)
    }

    private func propfindRequest(for path: RemotePath, depth: Int) throws -> URLRequest {
        var request = URLRequest(url: url(for: path, directory: true))
        request.httpMethod = "PROPFIND"
        request.setValue(String(depth), forHTTPHeaderField: "Depth")
        request.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        // Asking for named properties rather than allprop keeps the response
        // small; some servers return a great deal under allprop.
        let body = """
        <?xml version="1.0" encoding="utf-8"?>
        <d:propfind xmlns:d="DAV:">
          <d:prop>
            <d:resourcetype/>
            <d:getcontentlength/>
            <d:getlastmodified/>
            <d:getetag/>
            <d:getcontenttype/>
            <d:creationdate/>
          </d:prop>
        </d:propfind>
        """
        request.httpBody = Data(body.utf8)
        apply(&request)
        return request
    }

    private func apply(_ request: inout URLRequest) {
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        request.setValue("Openborld", forHTTPHeaderField: "User-Agent")
    }
}
