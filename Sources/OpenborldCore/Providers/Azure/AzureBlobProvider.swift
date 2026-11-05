import Foundation
import Crypto

#if canImport(FoundationNetworking)
// On Linux and Windows, Foundation is split and the URL loading system lives
// in its own module.
import FoundationNetworking
#endif

/// Azure Blob Storage.
///
/// Addresses blobs through whichever credential the connection carries — SAS
/// token appended to the URL, or SharedKey signing per request — so a pasted SAS
/// container URL and a full account key take exactly the same code path from
/// here down.
public final class AzureBlobProvider: StorageProvider, @unchecked Sendable {
    public let connection: Connection
    private let config: AzureConfig
    private let http: HTTPClient

    /// Blocks are staged in parallel; 8 MiB is a good balance between request
    /// overhead and the amount of work lost when one block fails.
    private let blockSize: Int64
    private let maxParallelBlocks: Int

    /// Above this, a blob is uploaded as staged blocks rather than one PUT.
    /// Azure's single-PUT ceiling is 5000 MiB but chunking earlier buys
    /// progress reporting and resume.
    private let singleShotLimit: Int64
    private static let defaultSingleShotLimit: Int64 = 64 * 1024 * 1024
    private static let maxBlocks: Int64 = 50_000

    public init(connection: Connection, secrets: ConnectionSecrets, http: HTTPClient = .shared) throws {
        self.connection = connection
        self.config = try AzureAuth.makeConfig(connection: connection, secrets: secrets)
        self.http = http
        let configured = connection.intSetting(.chunkSizeBytes).map(Int64.init) ?? (8 * 1024 * 1024)
        self.blockSize = max(1024 * 1024, min(configured, 4000 * 1024 * 1024))
        self.maxParallelBlocks = max(1, min(connection.intSetting(.maxConcurrentTransfers) ?? 4, 16))
        self.singleShotLimit = connection.intSetting(.multipartThresholdBytes).map(Int64.init)
            ?? Self.defaultSingleShotLimit
    }

    public var kind: ProviderKind { .azureBlob }

    public var capabilities: ProviderCapabilities {
        var caps: ProviderCapabilities = [
            .createFolder, .delete, .rename, .serverSideCopy,
            .rangeDownload, .chunkedUpload, .metadata,
        ]
        // A container-scoped SAS can't create sibling containers, and only an
        // account key lets us mint a fresh link.
        if !config.isContainerScoped { caps.insert(.createContainer) }
        if config.credential.canMintSAS { caps.insert(.signedURL) }
        return caps
    }

    /// True when the connection's root is a single container, which the UI uses
    /// to label the root crumb with the container's own name.
    public var containerScope: String? { config.containerScope }

    // MARK: - Validate

    public func validate() async throws {
        if let container = config.containerScope {
            // Cheapest proof that both the endpoint and the credential work.
            let request = try makeRequest(
                method: "GET",
                container: container,
                key: "",
                query: [("restype", "container"), ("comp", "list"), ("maxresults", "1")]
            )
            _ = try await http.send(request)
        } else {
            let request = try makeRequest(
                method: "GET",
                container: nil,
                key: "",
                query: [("comp", "list"), ("maxresults", "1")]
            )
            _ = try await http.send(request)
        }
    }

    // MARK: - Listing

    public func list(_ path: RemotePath, cursor: String?, pageSize: Int) async throws -> Listing {
        let (container, key) = config.resolve(path)
        guard let container else {
            return try await listContainers(cursor: cursor, pageSize: pageSize)
        }
        return try await listBlobs(
            container: container,
            prefix: key.isEmpty ? "" : key + "/",
            cursor: cursor,
            pageSize: pageSize
        )
    }

    private func listContainers(cursor: String?, pageSize: Int) async throws -> Listing {
        var query: [(String, String)] = [
            ("comp", "list"),
            ("maxresults", String(min(max(pageSize, 1), 5000))),
        ]
        if let cursor, !cursor.isEmpty { query.append(("marker", cursor)) }

        let request = try makeRequest(method: "GET", container: nil, key: "", query: query)
        let result = try await http.send(request)
        guard let root = XMLLite.parse(result.data) else {
            throw StorageError.provider("Azure returned a container list that couldn't be parsed.")
        }

        var items: [CloudItem] = []
        for node in root.descendants(named: "Container") {
            guard let name = node.string("Name") else { continue }
            let properties = node.child("Properties")
            items.append(CloudItem(
                name: name,
                path: RemotePath(components: [name]),
                kind: .container,
                modified: properties?.string("Last-Modified").flatMap(HTTPDate.parseRFC1123),
                etag: properties?.string("Etag")
            ))
        }

        let marker = root.string("NextMarker")
        return Listing(items: items, nextCursor: marker)
    }

    private func listBlobs(
        container: String,
        prefix: String,
        cursor: String?,
        pageSize: Int
    ) async throws -> Listing {
        var query: [(String, String)] = [
            ("restype", "container"),
            ("comp", "list"),
            // The delimiter is what turns a flat keyspace into one folder level.
            ("delimiter", "/"),
            ("maxresults", String(min(max(pageSize, 1), 5000))),
        ]
        if !prefix.isEmpty { query.append(("prefix", prefix)) }
        if let cursor, !cursor.isEmpty { query.append(("marker", cursor)) }

        let request = try makeRequest(method: "GET", container: container, key: "", query: query)
        let result = try await http.send(request)
        guard let root = XMLLite.parse(result.data) else {
            throw StorageError.provider("Azure returned a blob list that couldn't be parsed.")
        }

        var items: [CloudItem] = []

        for node in root.descendants(named: "BlobPrefix") {
            guard let fullName = node.string("Name") else { continue }
            let name = folderName(fromPrefix: fullName, parentPrefix: prefix)
            guard !name.isEmpty else { continue }
            items.append(CloudItem(
                name: name,
                path: config.path(container: container, key: String(fullName.dropLast())),
                kind: .folder
            ))
        }

        for node in root.descendants(named: "Blob") {
            guard let fullName = node.string("Name") else { continue }
            // Zero-byte `folder/` markers are the directory itself, not a child.
            if fullName == prefix { continue }
            let name = String(fullName.dropFirst(prefix.count))
            guard !name.isEmpty else { continue }

            // Some tools write a `folder/` marker blob; show it as a folder and
            // let the real prefix entry dedupe it below.
            if name.hasSuffix("/") {
                let folder = String(name.dropLast())
                guard !folder.isEmpty else { continue }
                if !items.contains(where: { $0.name == folder && $0.isDirectory }) {
                    items.append(CloudItem(
                        name: folder,
                        path: config.path(container: container, key: String(fullName.dropLast())),
                        kind: .folder
                    ))
                }
                continue
            }

            let properties = node.child("Properties")
            items.append(CloudItem(
                name: name,
                path: config.path(container: container, key: fullName),
                kind: .file,
                size: properties?.int64("Content-Length"),
                modified: properties?.string("Last-Modified").flatMap(HTTPDate.parseRFC1123),
                created: properties?.string("Creation-Time").flatMap(HTTPDate.parseRFC1123),
                etag: properties?.string("Etag"),
                contentType: properties?.string("Content-Type"),
                storageClass: properties?.string("AccessTier")
            ))
        }

        return Listing(items: items, nextCursor: root.string("NextMarker"))
    }

    /// `a/b/c/` under parent `a/b/` is `c`.
    private func folderName(fromPrefix full: String, parentPrefix: String) -> String {
        var name = full
        if name.hasPrefix(parentPrefix) { name.removeFirst(parentPrefix.count) }
        if name.hasSuffix("/") { name.removeLast() }
        return name
    }

    // MARK: - Stat & metadata

    public func stat(_ path: RemotePath) async throws -> CloudItem {
        let (container, key) = config.resolve(path)
        guard let container else { throw StorageError.notFound(path.description) }
        guard !key.isEmpty else {
            return CloudItem.container(name: container, at: path)
        }

        let request = try makeRequest(method: "HEAD", container: container, key: key, query: [])
        guard let result = try await http.sendAllowingNotFound(request) else {
            // Not a blob — it may still be a prefix with children.
            let probe = try await listBlobs(container: container, prefix: key + "/", cursor: nil, pageSize: 1)
            if !probe.items.isEmpty {
                return CloudItem(name: path.name, path: path, kind: .folder)
            }
            throw StorageError.notFound(path.description)
        }

        return CloudItem(
            name: path.name,
            path: path,
            kind: .file,
            size: result.contentLength,
            modified: result.header("Last-Modified").flatMap(HTTPDate.parseRFC1123),
            created: result.header("x-ms-creation-time").flatMap(HTTPDate.parseRFC1123),
            etag: result.header("Etag"),
            contentType: result.header("Content-Type"),
            storageClass: result.header("x-ms-access-tier")
        )
    }

    public func metadata(_ path: RemotePath) async throws -> [(key: String, value: String)] {
        let (container, key) = config.resolve(path)
        guard let container, !key.isEmpty else { return [] }

        let request = try makeRequest(method: "HEAD", container: container, key: key, query: [])
        guard let result = try await http.sendAllowingNotFound(request) else {
            throw StorageError.notFound(path.description)
        }

        var rows: [(key: String, value: String)] = []
        let interesting = [
            ("Content-Type", "Content Type"),
            ("Content-Length", "Size"),
            ("Content-Encoding", "Content Encoding"),
            ("Content-MD5", "Content MD5"),
            ("Cache-Control", "Cache Control"),
            ("Content-Disposition", "Content Disposition"),
            ("Etag", "ETag"),
            ("Last-Modified", "Last Modified"),
            ("x-ms-creation-time", "Created"),
            ("x-ms-blob-type", "Blob Type"),
            ("x-ms-access-tier", "Access Tier"),
            ("x-ms-access-tier-inferred", "Access Tier Inferred"),
            ("x-ms-archive-status", "Archive Status"),
            ("x-ms-lease-state", "Lease State"),
            ("x-ms-lease-status", "Lease Status"),
            ("x-ms-server-encrypted", "Server Encrypted"),
            ("x-ms-encryption-scope", "Encryption Scope"),
            ("x-ms-blob-sequence-number", "Sequence Number"),
            ("x-ms-copy-status", "Copy Status"),
            ("x-ms-copy-source", "Copy Source"),
            ("x-ms-version-id", "Version ID"),
        ]
        for (header, label) in interesting {
            if let value = result.header(header), !value.isEmpty {
                rows.append((key: label, value: value))
            }
        }

        // User-defined metadata arrives as x-ms-meta-* headers.
        var custom: [(String, String)] = []
        for (rawKey, rawValue) in result.response.allHeaderFields {
            guard let header = rawKey as? String, let value = rawValue as? String,
                  header.lowercased().hasPrefix("x-ms-meta-")
            else { continue }
            custom.append((String(header.dropFirst("x-ms-meta-".count)), value))
        }
        for (name, value) in custom.sorted(by: { $0.0 < $1.0 }) {
            rows.append((key: "Metadata · \(name)", value: value))
        }
        return rows
    }

    // MARK: - Mutations

    public func createContainer(named name: String) async throws {
        guard !config.isContainerScoped else {
            throw StorageError.unsupported(
                "This connection is scoped to a single container, so it can't create new ones."
            )
        }
        let request = try makeRequest(
            method: "PUT",
            container: name,
            key: "",
            query: [("restype", "container")]
        )
        _ = try await http.send(request)
    }

    public func createFolder(at path: RemotePath) async throws {
        let (container, key) = config.resolve(path)
        guard let container else {
            try await createContainer(named: path.name)
            return
        }
        guard !key.isEmpty else {
            try await createContainer(named: container)
            return
        }
        // Blob storage has no directories; a zero-byte `prefix/` marker is the
        // convention Azure's own tools use so an empty folder survives a reload.
        var request = try makeRequest(method: "PUT", container: container, key: key + "/", query: [])
        request.setValue("BlockBlob", forHTTPHeaderField: "x-ms-blob-type")
        request.setValue("0", forHTTPHeaderField: "Content-Length")
        try signIfNeeded(&request, contentLength: 0)
        _ = try await http.send(request)
    }

    public func delete(_ item: CloudItem) async throws {
        let (container, key) = config.resolve(item.path)
        guard let container else { throw StorageError.notFound(item.path.description) }

        if key.isEmpty {
            guard item.kind == .container else { throw StorageError.notFound(item.path.description) }
            let request = try makeRequest(
                method: "DELETE",
                container: container,
                key: "",
                query: [("restype", "container")]
            )
            _ = try await http.send(request)
            return
        }

        if item.isDirectory {
            // Remove the marker blob too, if one exists.
            let marker = try makeRequest(method: "DELETE", container: container, key: key + "/", query: [])
            _ = try? await http.sendAllowingNotFound(marker)
            return
        }

        var request = try makeRequest(method: "DELETE", container: container, key: key, query: [])
        request.setValue("include", forHTTPHeaderField: "x-ms-delete-snapshots")
        try signIfNeeded(&request, contentLength: nil)
        _ = try await http.send(request, acceptableStatus: Set(200..<300).union([404]))
    }

    public func copy(_ item: CloudItem, to destination: RemotePath) async throws {
        guard !item.isDirectory else {
            throw StorageError.unsupported("Copy a folder by copying the files inside it.")
        }
        let (sourceContainer, sourceKey) = config.resolve(item.path)
        let (destContainer, destKey) = config.resolve(destination)
        guard let sourceContainer, let destContainer, !sourceKey.isEmpty, !destKey.isEmpty else {
            throw StorageError.invalidConfiguration("That copy source or destination isn't a blob.")
        }

        // The copy source must be a URL Azure itself can fetch, which means it
        // needs its own credential when the account isn't public.
        let sourceURL = try authorizedSourceURL(container: sourceContainer, key: sourceKey)

        var request = try makeRequest(method: "PUT", container: destContainer, key: destKey, query: [])
        request.setValue(sourceURL.absoluteString, forHTTPHeaderField: "x-ms-copy-source")
        request.setValue("0", forHTTPHeaderField: "Content-Length")
        try signIfNeeded(&request, contentLength: 0)
        let result = try await http.send(request)

        // Same-account copies normally complete synchronously, but Azure is
        // entitled to make them async, so a pending copy gets polled.
        if let status = result.header("x-ms-copy-status"), status == "pending" {
            try await awaitCopy(container: destContainer, key: destKey)
        }
    }

    private func awaitCopy(container: String, key: String) async throws {
        let deadline = Date().addingTimeInterval(3600)
        var delay: UInt64 = 300_000_000
        while Date() < deadline {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: delay)
            delay = min(delay * 2, 5_000_000_000)

            let request = try makeRequest(method: "HEAD", container: container, key: key, query: [])
            guard let result = try await http.sendAllowingNotFound(request) else { continue }
            switch result.header("x-ms-copy-status") {
            case "success", .none: return
            case "pending": continue
            case "aborted": throw StorageError.provider("Azure aborted the copy.")
            case "failed":
                throw StorageError.provider(
                    result.header("x-ms-copy-status-description") ?? "The copy failed."
                )
            default: return
            }
        }
        throw StorageError.provider("The copy didn't finish in time.")
    }

    public func move(_ item: CloudItem, to destination: RemotePath) async throws {
        try await copy(item, to: destination)
        try await delete(item)
    }

    // MARK: - Download

    public func download(_ item: CloudItem, to localURL: URL, progress: ProgressHandler?) async throws {
        let (container, key) = config.resolve(item.path)
        guard let container, !key.isEmpty else { throw StorageError.notFound(item.path.description) }

        // Pick up where a previous attempt stopped, if a partial file survived.
        let existing = Self.resumeOffset(for: localURL, expecting: item.size)

        let request = try makeRequest(method: "GET", container: container, key: key, query: [])
        let total = item.size
        try await http.download(request, to: localURL, resumeFrom: existing) { done, _ in
            progress?(existing + done, total)
        }
    }

    public func readStream(_ item: CloudItem) async throws -> AsyncThrowingStream<Data, Error> {
        let (container, key) = config.resolve(item.path)
        guard let container, !key.isEmpty else { throw StorageError.notFound(item.path.description) }
        let request = try makeRequest(method: "GET", container: container, key: key, query: [])
        return http.stream(request)
    }

    public func read(_ item: CloudItem, range: ClosedRange<Int64>?) async throws -> Data {
        let (container, key) = config.resolve(item.path)
        guard let container, !key.isEmpty else { throw StorageError.notFound(item.path.description) }

        var request = try makeRequest(method: "GET", container: container, key: key, query: [], presign: false)
        if let range {
            request.setValue("bytes=\(range.lowerBound)-\(range.upperBound)", forHTTPHeaderField: "Range")
        }
        try signIfNeeded(&request, contentLength: nil)
        let result = try await http.send(request, acceptableStatus: Set(200..<300))
        return result.data
    }

    // MARK: - Upload

    public func upload(
        _ localURL: URL,
        to path: RemotePath,
        contentType: String?,
        progress: ProgressHandler?
    ) async throws -> CloudItem {
        let (container, key) = config.resolve(path)
        guard let container, !key.isEmpty else {
            throw StorageError.invalidConfiguration("Pick a container to upload into.")
        }

        let attributes = try FileManager.default.attributesOfItem(atPath: localURL.path)
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        let type = contentType ?? MIMEType.forFilename(path.name)

        if size <= singleShotLimit {
            try await putBlob(container: container, key: key, file: localURL, size: size,
                              contentType: type, progress: progress)
        } else {
            try await putBlockBlob(container: container, key: key, file: localURL, size: size,
                                   contentType: type, progress: progress)
        }

        return CloudItem(
            name: path.name,
            path: path,
            kind: .file,
            size: size,
            modified: Date(),
            contentType: type
        )
    }

    private func putBlob(
        container: String,
        key: String,
        file: URL,
        size: Int64,
        contentType: String,
        progress: ProgressHandler?
    ) async throws {
        var request = try makeRequest(method: "PUT", container: container, key: key, query: [], presign: false)
        request.setValue("BlockBlob", forHTTPHeaderField: "x-ms-blob-type")
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.setValue(String(size), forHTTPHeaderField: "Content-Length")
        try signIfNeeded(&request, contentLength: size)
        _ = try await http.upload(request, fromFile: file, progress: progress)
    }

    /// Stages the file as blocks, then commits the block list.
    ///
    /// Blocks already staged by an interrupted attempt are discovered up front
    /// and skipped, which is what makes a failed 20 GB upload cheap to retry.
    private func putBlockBlob(
        container: String,
        key: String,
        file: URL,
        size: Int64,
        contentType: String,
        progress: ProgressHandler?
    ) async throws {
        // Azure allows at most 50,000 blocks per blob.
        var chunk = blockSize
        while size / chunk > Self.maxBlocks - 1 { chunk *= 2 }

        let blockCount = Int((size + chunk - 1) / chunk)
        let blockIDs = (0..<blockCount).map { Self.blockID(index: $0) }
        let alreadyStaged = await uncommittedBlocks(container: container, key: key)

        let counter = ByteCounter()
        // Blocks that survived from a previous attempt still count toward the
        // progress bar, or it would start at zero and jump.
        var preCounted: Int64 = 0
        for (index, id) in blockIDs.enumerated() where alreadyStaged.contains(id) {
            preCounted += Self.blockLength(index: index, chunk: chunk, size: size)
        }
        await counter.add(preCounted)
        if let progress { progress(preCounted, size) }

        // Sliding window: keep `maxParallelBlocks` in flight and start the next
        // block as soon as one finishes, rather than waiting for whole batches.
        try await withThrowingTaskGroup(of: Void.self) { group in
            var next = 0
            let window = min(maxParallelBlocks, blockCount)

            for _ in 0..<window {
                let index = next
                next += 1
                group.addTask { [self] in
                    try await uploadOneBlock(
                        container: container, key: key, file: file,
                        index: index, chunk: chunk, size: size,
                        blockID: blockIDs[index], skip: alreadyStaged.contains(blockIDs[index]),
                        counter: counter, progress: progress
                    )
                }
            }

            while try await group.next() != nil {
                guard next < blockCount else { continue }
                let index = next
                next += 1
                group.addTask { [self] in
                    try await uploadOneBlock(
                        container: container, key: key, file: file,
                        index: index, chunk: chunk, size: size,
                        blockID: blockIDs[index], skip: alreadyStaged.contains(blockIDs[index]),
                        counter: counter, progress: progress
                    )
                }
            }
        }

        try await commitBlockList(
            container: container,
            key: key,
            blockIDs: blockIDs,
            contentType: contentType
        )
    }

    private func uploadOneBlock(
        container: String,
        key: String,
        file: URL,
        index: Int,
        chunk: Int64,
        size: Int64,
        blockID: String,
        skip: Bool,
        counter: ByteCounter,
        progress: ProgressHandler?
    ) async throws {
        guard !skip else { return }
        try Task.checkCancellation()
        let offset = Int64(index) * chunk
        let length = Self.blockLength(index: index, chunk: chunk, size: size)
        let data = try Self.readChunk(from: file, offset: offset, length: length)
        try await stageBlock(container: container, key: key, blockID: blockID, data: data)
        let done = await counter.add(length)
        progress?(done, size)
    }

    private func stageBlock(container: String, key: String, blockID: String, data: Data) async throws {
        var request = try makeRequest(
            method: "PUT",
            container: container,
            key: key,
            query: [("comp", "block"), ("blockid", blockID)],
            presign: false
        )
        request.setValue(String(data.count), forHTTPHeaderField: "Content-Length")
        try signIfNeeded(&request, contentLength: Int64(data.count))
        _ = try await http.upload(request, body: data)
    }

    private func commitBlockList(
        container: String,
        key: String,
        blockIDs: [String],
        contentType: String
    ) async throws {
        var xml = #"<?xml version="1.0" encoding="utf-8"?>"# + "\n<BlockList>\n"
        for id in blockIDs { xml += "  <Latest>\(id)</Latest>\n" }
        xml += "</BlockList>"
        let body = Data(xml.utf8)

        var request = try makeRequest(
            method: "PUT",
            container: container,
            key: key,
            query: [("comp", "blocklist")],
            presign: false
        )
        request.setValue("application/xml", forHTTPHeaderField: "Content-Type")
        request.setValue(contentType, forHTTPHeaderField: "x-ms-blob-content-type")
        request.setValue(String(body.count), forHTTPHeaderField: "Content-Length")
        try signIfNeeded(&request, contentLength: Int64(body.count))
        _ = try await http.upload(request, body: body)
    }

    /// Block IDs already staged for this blob but not yet committed.
    private func uncommittedBlocks(container: String, key: String) async -> Set<String> {
        do {
            let request = try makeRequest(
                method: "GET",
                container: container,
                key: key,
                query: [("comp", "blocklist"), ("blocklisttype", "uncommitted")]
            )
            guard let result = try await http.sendAllowingNotFound(request),
                  let root = XMLLite.parse(result.data)
            else { return [] }
            return Set(root.descendants(named: "Block").compactMap { $0.string("Name") })
        } catch {
            // A missing blob, or no permission to inspect it, just means no resume.
            return []
        }
    }

    public func uploadStream(
        _ stream: AsyncThrowingStream<Data, Error>,
        length: Int64?,
        to path: RemotePath,
        contentType: String?,
        progress: ProgressHandler?
    ) async throws -> CloudItem {
        let (container, key) = config.resolve(path)
        guard let container, !key.isEmpty else {
            throw StorageError.invalidConfiguration("Pick a container to upload into.")
        }
        let type = contentType ?? MIMEType.forFilename(path.name)

        // Stage each buffered block as it fills, so a cross-cloud transfer never
        // needs the whole object on disk or in memory.
        var buffer = Data()
        var blockIDs: [String] = []
        var sent: Int64 = 0
        buffer.reserveCapacity(Int(blockSize))

        for try await incoming in stream {
            buffer.append(incoming)
            while Int64(buffer.count) >= blockSize {
                let block = buffer.prefix(Int(blockSize))
                buffer.removeFirst(Int(blockSize))
                let id = Self.blockID(index: blockIDs.count)
                blockIDs.append(id)
                try await stageBlock(container: container, key: key, blockID: id, data: Data(block))
                sent += Int64(block.count)
                progress?(sent, length)
            }
        }

        if blockIDs.isEmpty {
            // Small enough to land in one request.
            var request = try makeRequest(method: "PUT", container: container, key: key, query: [], presign: false)
            request.setValue("BlockBlob", forHTTPHeaderField: "x-ms-blob-type")
            request.setValue(type, forHTTPHeaderField: "Content-Type")
            request.setValue(String(buffer.count), forHTTPHeaderField: "Content-Length")
            try signIfNeeded(&request, contentLength: Int64(buffer.count))
            _ = try await http.upload(request, body: buffer)
            sent = Int64(buffer.count)
            progress?(sent, length ?? sent)
        } else {
            if !buffer.isEmpty {
                let id = Self.blockID(index: blockIDs.count)
                blockIDs.append(id)
                try await stageBlock(container: container, key: key, blockID: id, data: buffer)
                sent += Int64(buffer.count)
                progress?(sent, length)
            }
            try await commitBlockList(container: container, key: key, blockIDs: blockIDs, contentType: type)
        }

        return CloudItem(name: path.name, path: path, kind: .file, size: sent,
                         modified: Date(), contentType: type)
    }

    // MARK: - Sharing

    public func signedURL(for item: CloudItem, expiresIn: TimeInterval) async throws -> URL {
        let (container, key) = config.resolve(item.path)
        guard let container, !key.isEmpty else {
            throw StorageError.unsupported("Only a file can be shared as a link.")
        }

        switch config.credential {
        case .sharedKey(let account, let accountKey):
            let token = AzureAuth.serviceSAS(
                account: account,
                key: accountKey,
                container: container,
                blob: key,
                permissions: "r",
                expires: Date().addingTimeInterval(expiresIn)
            )
            guard let url = URL(string: blobURLString(container: container, key: key) + "?" + token) else {
                throw StorageError.provider("Couldn't build a shareable URL.")
            }
            return url

        case .sas(let token):
            // Can't mint a narrower token without the key, so hand back this
            // connection's own SAS. The UI warns that it carries the same rights.
            guard let url = URL(string: blobURLString(container: container, key: key) + "?" + token) else {
                throw StorageError.provider("Couldn't build a shareable URL.")
            }
            return url
        }
    }

    // MARK: - Request building

    private func blobURLString(container: String, key: String) -> String {
        var string = config.blobEndpoint.absoluteString
        if string.hasSuffix("/") { string.removeLast() }
        string += "/" + container.pathSegmentEncoded
        if !key.isEmpty { string += "/" + key.objectKeyEncoded }
        return string
    }

    /// Builds a request, appending the SAS token when the connection uses one.
    ///
    /// `presign: false` leaves SharedKey signing to the caller, which matters
    /// when the caller still has headers to add — the signature covers them.
    private func makeRequest(
        method: String,
        container: String?,
        key: String,
        query: [(String, String)],
        presign: Bool = true
    ) throws -> URLRequest {
        var string = config.blobEndpoint.absoluteString
        if string.hasSuffix("/") { string.removeLast() }
        if let container { string += "/" + container.pathSegmentEncoded }
        if !key.isEmpty { string += "/" + key.objectKeyEncoded }
        if container == nil, query.isEmpty == false { string += "/" }

        var parts = query.map { "\($0.0.pathSegmentEncoded)=\($0.1.pathSegmentEncoded)" }
        if case .sas(let token) = config.credential, !token.isEmpty {
            parts.append(token)
        }
        if !parts.isEmpty { string += "?" + parts.joined(separator: "&") }

        guard let url = URL(string: string) else {
            throw StorageError.invalidConfiguration("Couldn't build a URL for \(key.isEmpty ? (container ?? "/") : key).")
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(AzureAuth.apiVersion, forHTTPHeaderField: "x-ms-version")
        if presign { try signIfNeeded(&request, contentLength: nil) }
        return request
    }

    private func signIfNeeded(_ request: inout URLRequest, contentLength: Int64?) throws {
        guard case .sharedKey(let account, let key) = config.credential else { return }
        try AzureAuth.signSharedKey(
            request: &request,
            account: account,
            key: key,
            contentLength: contentLength
        )
    }

    /// A source URL Azure's own servers can read, for server-side copy.
    private func authorizedSourceURL(container: String, key: String) throws -> URL {
        let base = blobURLString(container: container, key: key)
        switch config.credential {
        case .sas(let token):
            guard let url = URL(string: base + "?" + token) else {
                throw StorageError.provider("Couldn't build a copy source URL.")
            }
            return url
        case .sharedKey(let account, let accountKey):
            // Same-account copies accept a bare URL, but a short-lived read SAS
            // also works and keeps cross-account copies on the same code path.
            let token = AzureAuth.serviceSAS(
                account: account,
                key: accountKey,
                container: container,
                blob: key,
                permissions: "r",
                expires: Date().addingTimeInterval(3600)
            )
            guard let url = URL(string: base + "?" + token) else {
                throw StorageError.provider("Couldn't build a copy source URL.")
            }
            return url
        }
    }

    // MARK: - Chunk helpers

    /// Block IDs must be equal-length base64 strings, or Azure rejects the list.
    private static func blockID(index: Int) -> String {
        Data(String(format: "openborld-%08d", index).utf8).base64EncodedString()
    }

    private static func blockLength(index: Int, chunk: Int64, size: Int64) -> Int64 {
        let offset = Int64(index) * chunk
        return min(chunk, size - offset)
    }

    /// Reads one block without mapping the whole file.
    private static func readChunk(from file: URL, offset: Int64, length: Int64) throws -> Data {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(offset))
        return try handle.read(upToCount: Int(length)) ?? Data()
    }
}

/// Serialises progress accumulation across parallel block uploads.
actor ByteCounter {
    private var total: Int64 = 0

    @discardableResult
    func add(_ bytes: Int64) -> Int64 {
        total += bytes
        return total
    }

    var value: Int64 { total }
}
