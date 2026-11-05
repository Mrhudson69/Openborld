import Foundation
import Crypto

/// Amazon S3 and every S3-compatible endpoint: Backblaze B2, Google Cloud
/// Storage's interop API, MinIO, Wasabi, R2, Ceph.
///
/// One implementation covers them all because the only differences are
/// endpoint shape, addressing style, and region — all of which the connection
/// carries as settings.
public final class S3Provider: StorageProvider, @unchecked Sendable {
    public let connection: Connection
    private let config: S3Config
    private let http: HTTPClient

    private let partSize: Int64
    private let maxParallelParts: Int

    /// Below this a single PUT is cheaper than setting up a multipart upload.
    private let singleShotLimit: Int64
    private static let defaultSingleShotLimit: Int64 = 64 * 1024 * 1024
    /// S3's hard ceiling on parts per upload.
    private static let maxParts: Int64 = 10_000

    public init(connection: Connection, secrets: ConnectionSecrets, http: HTTPClient = .shared) throws {
        self.connection = connection
        self.config = try S3Config.make(connection: connection, secrets: secrets)
        self.http = http
        let configured = connection.intSetting(.chunkSizeBytes).map(Int64.init) ?? (16 * 1024 * 1024)
        // S3 requires every part except the last to be at least 5 MiB; the
        // floor is lifted only when a threshold override says this endpoint is
        // a test double.
        let hasOverride = connection.intSetting(.multipartThresholdBytes) != nil
        self.partSize = hasOverride ? max(1024, configured) : max(5 * 1024 * 1024, configured)
        self.maxParallelParts = max(1, min(connection.intSetting(.maxConcurrentTransfers) ?? 4, 16))
        self.singleShotLimit = connection.intSetting(.multipartThresholdBytes).map(Int64.init)
            ?? Self.defaultSingleShotLimit
    }

    public var kind: ProviderKind { connection.kind }

    public var capabilities: ProviderCapabilities {
        var caps: ProviderCapabilities = [
            .createFolder, .delete, .rename, .serverSideCopy,
            .signedURL, .rangeDownload, .chunkedUpload, .metadata,
        ]
        if !config.isBucketScoped { caps.insert(.createContainer) }
        return caps
    }

    public var bucketScope: String? { config.bucketScope }

    // MARK: - Validate

    public func validate() async throws {
        if let bucket = config.bucketScope {
            let request = try signedRequest(
                method: "GET", bucket: bucket, key: "",
                query: [("list-type", "2"), ("max-keys", "1")]
            )
            _ = try await http.send(request)
        } else {
            let request = try signedRequest(method: "GET", bucket: nil, key: "", query: [])
            _ = try await http.send(request)
        }
    }

    // MARK: - Listing

    public func list(_ path: RemotePath, cursor: String?, pageSize: Int) async throws -> Listing {
        let (bucket, key) = config.resolve(path)
        guard let bucket else { return try await listBuckets() }
        return try await listObjects(
            bucket: bucket,
            prefix: key.isEmpty ? "" : key + "/",
            cursor: cursor,
            pageSize: pageSize
        )
    }

    private func listBuckets() async throws -> Listing {
        let request = try signedRequest(method: "GET", bucket: nil, key: "", query: [])
        let result = try await http.send(request)
        guard let root = XMLLite.parse(result.data) else {
            throw StorageError.provider("The bucket list couldn't be parsed.")
        }
        var items: [CloudItem] = []
        for node in root.descendants(named: "Bucket") {
            guard let name = node.string("Name") else { continue }
            items.append(CloudItem(
                name: name,
                path: RemotePath(components: [name]),
                kind: .container,
                created: node.string("CreationDate").flatMap(HTTPDate.parseISO8601)
            ))
        }
        return Listing(items: items.sorted { $0.name < $1.name })
    }

    private func listObjects(
        bucket: String,
        prefix: String,
        cursor: String?,
        pageSize: Int
    ) async throws -> Listing {
        var query: [(String, String)] = [
            ("list-type", "2"),
            ("delimiter", "/"),
            ("max-keys", String(min(max(pageSize, 1), 1000))),
        ]
        if !prefix.isEmpty { query.append(("prefix", prefix)) }
        if let cursor, !cursor.isEmpty { query.append(("continuation-token", cursor)) }

        let request = try signedRequest(method: "GET", bucket: bucket, key: "", query: query)
        let result = try await http.send(request)
        guard let root = XMLLite.parse(result.data) else {
            throw StorageError.provider("The object list couldn't be parsed.")
        }

        var items: [CloudItem] = []

        for node in root.descendants(named: "CommonPrefixes") {
            guard let full = node.string("Prefix") else { continue }
            var name = full
            if name.hasPrefix(prefix) { name.removeFirst(prefix.count) }
            if name.hasSuffix("/") { name.removeLast() }
            guard !name.isEmpty else { continue }
            items.append(CloudItem(
                name: name,
                path: config.path(bucket: bucket, key: String(full.dropLast())),
                kind: .folder
            ))
        }

        for node in root.descendants(named: "Contents") {
            guard let full = node.string("Key") else { continue }
            if full == prefix { continue }
            var name = full
            if name.hasPrefix(prefix) { name.removeFirst(prefix.count) }
            guard !name.isEmpty else { continue }

            // A key ending in `/` is a folder marker, not a file.
            if name.hasSuffix("/") {
                let folder = String(name.dropLast())
                guard !folder.isEmpty,
                      !items.contains(where: { $0.name == folder && $0.isDirectory })
                else { continue }
                items.append(CloudItem(
                    name: folder,
                    path: config.path(bucket: bucket, key: String(full.dropLast())),
                    kind: .folder
                ))
                continue
            }

            items.append(CloudItem(
                name: name,
                path: config.path(bucket: bucket, key: full),
                kind: .file,
                size: node.int64("Size"),
                modified: node.string("LastModified").flatMap(HTTPDate.parseISO8601),
                etag: node.string("ETag")?.replacingOccurrences(of: "\"", with: ""),
                storageClass: node.string("StorageClass")
            ))
        }

        let truncated = root.bool("IsTruncated") ?? false
        return Listing(
            items: items,
            nextCursor: truncated ? root.string("NextContinuationToken") : nil
        )
    }

    // MARK: - Stat & metadata

    public func stat(_ path: RemotePath) async throws -> CloudItem {
        let (bucket, key) = config.resolve(path)
        guard let bucket else { throw StorageError.notFound(path.description) }
        guard !key.isEmpty else { return CloudItem.container(name: bucket, at: path) }

        let request = try signedRequest(method: "HEAD", bucket: bucket, key: key, query: [])
        guard let result = try await http.sendAllowingNotFound(request) else {
            let probe = try await listObjects(bucket: bucket, prefix: key + "/", cursor: nil, pageSize: 1)
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
            etag: result.header("ETag")?.replacingOccurrences(of: "\"", with: ""),
            contentType: result.header("Content-Type"),
            storageClass: result.header("x-amz-storage-class")
        )
    }

    public func metadata(_ path: RemotePath) async throws -> [(key: String, value: String)] {
        let (bucket, key) = config.resolve(path)
        guard let bucket, !key.isEmpty else { return [] }

        let request = try signedRequest(method: "HEAD", bucket: bucket, key: key, query: [])
        guard let result = try await http.sendAllowingNotFound(request) else {
            throw StorageError.notFound(path.description)
        }

        var rows: [(key: String, value: String)] = []
        let interesting = [
            ("Content-Type", "Content Type"),
            ("Content-Length", "Size"),
            ("Content-Encoding", "Content Encoding"),
            ("Cache-Control", "Cache Control"),
            ("Content-Disposition", "Content Disposition"),
            ("ETag", "ETag"),
            ("Last-Modified", "Last Modified"),
            ("x-amz-storage-class", "Storage Class"),
            ("x-amz-server-side-encryption", "Encryption"),
            ("x-amz-server-side-encryption-aws-kms-key-id", "KMS Key"),
            ("x-amz-version-id", "Version ID"),
            ("x-amz-restore", "Restore Status"),
            ("x-amz-object-lock-mode", "Object Lock"),
            ("x-amz-expiration", "Expiration"),
        ]
        for (header, label) in interesting {
            if let value = result.header(header), !value.isEmpty {
                rows.append((key: label, value: value))
            }
        }

        var custom: [(String, String)] = []
        for (rawKey, rawValue) in result.response.allHeaderFields {
            guard let header = rawKey as? String, let value = rawValue as? String,
                  header.lowercased().hasPrefix("x-amz-meta-")
            else { continue }
            custom.append((String(header.dropFirst("x-amz-meta-".count)), value))
        }
        for (name, value) in custom.sorted(by: { $0.0 < $1.0 }) {
            rows.append((key: "Metadata · \(name)", value: value))
        }
        return rows
    }

    // MARK: - Mutations

    public func createContainer(named name: String) async throws {
        guard !config.isBucketScoped else {
            throw StorageError.unsupported(
                "This connection is scoped to a single bucket, so it can't create new ones."
            )
        }
        // Outside us-east-1 the bucket's region has to be stated in the body.
        var body = Data()
        if config.region != "us-east-1", config.region != "auto" {
            let xml = """
            <?xml version="1.0" encoding="UTF-8"?>
            <CreateBucketConfiguration xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
              <LocationConstraint>\(config.region.xmlEscaped)</LocationConstraint>
            </CreateBucketConfiguration>
            """
            body = Data(xml.utf8)
        }
        var request = try signedRequest(
            method: "PUT", bucket: name, key: "", query: [],
            payload: body.isEmpty ? .empty : .data(body)
        )
        if !body.isEmpty { request.setValue("application/xml", forHTTPHeaderField: "Content-Type") }
        _ = body.isEmpty
            ? try await http.send(request)
            : try await http.upload(request, body: body)
    }

    public func createFolder(at path: RemotePath) async throws {
        let (bucket, key) = config.resolve(path)
        guard let bucket else {
            try await createContainer(named: path.name)
            return
        }
        guard !key.isEmpty else {
            try await createContainer(named: bucket)
            return
        }
        // Zero-byte `prefix/` marker, so an empty folder survives a refresh.
        let request = try signedRequest(
            method: "PUT", bucket: bucket, key: key + "/", query: [], payload: .empty
        )
        _ = try await http.send(request)
    }

    public func delete(_ item: CloudItem) async throws {
        let (bucket, key) = config.resolve(item.path)
        guard let bucket else { throw StorageError.notFound(item.path.description) }

        if key.isEmpty {
            guard item.kind == .container else { throw StorageError.notFound(item.path.description) }
            let request = try signedRequest(method: "DELETE", bucket: bucket, key: "", query: [])
            _ = try await http.send(request)
            return
        }

        let target = item.isDirectory ? key + "/" : key
        let request = try signedRequest(method: "DELETE", bucket: bucket, key: target, query: [])
        _ = try await http.send(request, acceptableStatus: Set(200..<300).union([404]))
    }

    /// Deletes up to 1000 keys in one request. Emptying a large prefix one
    /// DELETE at a time is the slow path every S3 client gets wrong once.
    public func deleteBatch(bucket: String, keys: [String]) async throws {
        guard !keys.isEmpty else { return }
        for chunk in stride(from: 0, to: keys.count, by: 1000).map({
            Array(keys[$0..<min($0 + 1000, keys.count)])
        }) {
            var xml = #"<?xml version="1.0" encoding="UTF-8"?>"# + "\n<Delete><Quiet>true</Quiet>\n"
            for key in chunk { xml += "<Object><Key>\(key.xmlEscaped)</Key></Object>\n" }
            xml += "</Delete>"
            let body = Data(xml.utf8)

            var request = try signedRequest(
                method: "POST", bucket: bucket, key: "", query: [("delete", "")],
                payload: .data(body)
            )
            request.setValue("application/xml", forHTTPHeaderField: "Content-Type")
            request.setValue(
                Data(Insecure.MD5.hash(data: body)).base64EncodedString(),
                forHTTPHeaderField: "Content-MD5"
            )
            // Content-MD5 is part of the signature, so sign after setting it.
            try resign(&request, payload: .data(body))
            _ = try await http.upload(request, body: body)
        }
    }

    public func deleteRecursively(_ item: CloudItem) async throws {
        guard item.isDirectory else {
            try await delete(item)
            return
        }
        let (bucket, key) = config.resolve(item.path)
        guard let bucket else { throw StorageError.notFound(item.path.description) }
        guard !key.isEmpty else {
            // Bucket delete needs the bucket emptied first.
            try await emptyPrefix(bucket: bucket, prefix: "")
            try await delete(item)
            return
        }
        try await emptyPrefix(bucket: bucket, prefix: key + "/")
    }

    /// Walks every key under a prefix — ignoring the `/` delimiter, so one pass
    /// covers the whole subtree — and deletes them in batches.
    private func emptyPrefix(bucket: String, prefix: String) async throws {
        var cursor: String?
        repeat {
            try Task.checkCancellation()
            var query: [(String, String)] = [("list-type", "2"), ("max-keys", "1000")]
            if !prefix.isEmpty { query.append(("prefix", prefix)) }
            if let cursor { query.append(("continuation-token", cursor)) }

            let request = try signedRequest(method: "GET", bucket: bucket, key: "", query: query)
            let result = try await http.send(request)
            guard let root = XMLLite.parse(result.data) else { break }

            let keys = root.descendants(named: "Contents").compactMap { $0.string("Key") }
            try await deleteBatch(bucket: bucket, keys: keys)

            cursor = (root.bool("IsTruncated") ?? false) ? root.string("NextContinuationToken") : nil
        } while cursor != nil
    }

    public func copy(_ item: CloudItem, to destination: RemotePath) async throws {
        guard !item.isDirectory else {
            throw StorageError.unsupported("Copy a folder by copying the files inside it.")
        }
        let (sourceBucket, sourceKey) = config.resolve(item.path)
        let (destBucket, destKey) = config.resolve(destination)
        guard let sourceBucket, let destBucket, !sourceKey.isEmpty, !destKey.isEmpty else {
            throw StorageError.invalidConfiguration("That copy source or destination isn't an object.")
        }

        // A single CopyObject caps out at 5 GB; larger objects need multipart
        // copy, where each part names a byte range of the source.
        if let size = item.size, size > 5 * 1024 * 1024 * 1024 {
            try await multipartCopy(
                sourceBucket: sourceBucket, sourceKey: sourceKey,
                destBucket: destBucket, destKey: destKey, size: size
            )
            return
        }

        var request = try signedRequest(
            method: "PUT", bucket: destBucket, key: destKey, query: [], payload: .empty
        )
        let source = "/\(sourceBucket)/\(sourceKey)".objectKeyEncoded
        request.setValue(source, forHTTPHeaderField: "x-amz-copy-source")
        try resign(&request, payload: .empty)
        let result = try await http.send(request)

        // S3 can answer 200 and then report failure inside the body.
        if let root = XMLLite.parse(result.data), root.name == "Error" {
            throw StorageError.provider(root.string("Message") ?? "The copy failed.")
        }
    }

    private func multipartCopy(
        sourceBucket: String, sourceKey: String,
        destBucket: String, destKey: String, size: Int64
    ) async throws {
        let uploadID = try await createMultipartUpload(
            bucket: destBucket, key: destKey,
            contentType: MIMEType.forFilename(destKey)
        )
        do {
            var chunk: Int64 = max(partSize, 256 * 1024 * 1024)
            while size / chunk > Self.maxParts - 1 { chunk *= 2 }
            let count = Int((size + chunk - 1) / chunk)

            var tags: [(Int, String)] = []
            for index in 0..<count {
                try Task.checkCancellation()
                let start = Int64(index) * chunk
                let end = min(start + chunk, size) - 1

                var request = try signedRequest(
                    method: "PUT", bucket: destBucket, key: destKey,
                    query: [("partNumber", String(index + 1)), ("uploadId", uploadID)],
                    payload: .empty
                )
                request.setValue(
                    "/\(sourceBucket)/\(sourceKey)".objectKeyEncoded,
                    forHTTPHeaderField: "x-amz-copy-source"
                )
                request.setValue("bytes=\(start)-\(end)", forHTTPHeaderField: "x-amz-copy-source-range")
                try resign(&request, payload: .empty)

                let result = try await http.send(request)
                guard let etag = XMLLite.parse(result.data)?.firstDescendant(named: "ETag")?.text else {
                    throw StorageError.provider("A copied part came back without an ETag.")
                }
                tags.append((index + 1, etag))
            }
            try await completeMultipartUpload(
                bucket: destBucket, key: destKey, uploadID: uploadID, parts: tags
            )
        } catch {
            try? await abortMultipartUpload(bucket: destBucket, key: destKey, uploadID: uploadID)
            throw error
        }
    }

    public func move(_ item: CloudItem, to destination: RemotePath) async throws {
        try await copy(item, to: destination)
        try await delete(item)
    }

    // MARK: - Download

    public func download(_ item: CloudItem, to localURL: URL, progress: ProgressHandler?) async throws {
        let (bucket, key) = config.resolve(item.path)
        guard let bucket, !key.isEmpty else { throw StorageError.notFound(item.path.description) }

        let existing = Self.resumeOffset(for: localURL, expecting: item.size)

        // Range is a signed header, so the resume offset has to be known before
        // signing rather than added by the HTTP layer.
        var request = try signedRequest(method: "GET", bucket: bucket, key: key, query: [], payload: .empty)
        if existing > 0 {
            request.setValue("bytes=\(existing)-", forHTTPHeaderField: "Range")
            try resign(&request, payload: .empty)
        }

        let total = item.size
        try await http.download(request, to: localURL, resumeFrom: existing) { done, _ in
            progress?(existing + done, total)
        }
    }

    public func readStream(_ item: CloudItem) async throws -> AsyncThrowingStream<Data, Error> {
        let (bucket, key) = config.resolve(item.path)
        guard let bucket, !key.isEmpty else { throw StorageError.notFound(item.path.description) }
        let request = try signedRequest(method: "GET", bucket: bucket, key: key, query: [])
        return http.stream(request)
    }

    public func read(_ item: CloudItem, range: ClosedRange<Int64>?) async throws -> Data {
        let (bucket, key) = config.resolve(item.path)
        guard let bucket, !key.isEmpty else { throw StorageError.notFound(item.path.description) }
        var request = try signedRequest(method: "GET", bucket: bucket, key: key, query: [], payload: .empty)
        if let range {
            request.setValue("bytes=\(range.lowerBound)-\(range.upperBound)", forHTTPHeaderField: "Range")
            try resign(&request, payload: .empty)
        }
        return try await http.send(request).data
    }

    // MARK: - Upload

    public func upload(
        _ localURL: URL,
        to path: RemotePath,
        contentType: String?,
        progress: ProgressHandler?
    ) async throws -> CloudItem {
        let (bucket, key) = config.resolve(path)
        guard let bucket, !key.isEmpty else {
            throw StorageError.invalidConfiguration("Pick a bucket to upload into.")
        }

        let attributes = try FileManager.default.attributesOfItem(atPath: localURL.path)
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        let type = contentType ?? MIMEType.forFilename(path.name)

        if size <= singleShotLimit {
            var request = try signedRequest(
                method: "PUT", bucket: bucket, key: key, query: [], payload: .unsigned
            )
            request.setValue(type, forHTTPHeaderField: "Content-Type")
            request.setValue(String(size), forHTTPHeaderField: "Content-Length")
            try resign(&request, payload: .unsigned)
            _ = try await http.upload(request, fromFile: localURL, progress: progress)
        } else {
            try await multipartUpload(
                bucket: bucket, key: key, file: localURL,
                size: size, contentType: type, progress: progress
            )
        }

        return CloudItem(
            name: path.name, path: path, kind: .file,
            size: size, modified: Date(), contentType: type
        )
    }

    private func multipartUpload(
        bucket: String, key: String, file: URL,
        size: Int64, contentType: String, progress: ProgressHandler?
    ) async throws {
        var chunk = partSize
        while size / chunk > Self.maxParts - 1 { chunk *= 2 }
        let count = Int((size + chunk - 1) / chunk)

        // Reuse an abandoned upload for this key if one exists, so a retry only
        // re-sends the parts that never landed.
        let resumed = try? await findResumableUpload(bucket: bucket, key: key)
        let uploadID: String
        var existingParts: [Int: String] = [:]
        if let resumed {
            uploadID = resumed.uploadID
            existingParts = resumed.parts
        } else {
            uploadID = try await createMultipartUpload(
                bucket: bucket, key: key, contentType: contentType
            )
        }

        do {
            let collector = PartCollector()
            for (number, etag) in existingParts { await collector.record(number: number, etag: etag) }

            let counter = ByteCounter()
            var preCounted: Int64 = 0
            for number in existingParts.keys {
                preCounted += min(chunk, size - Int64(number - 1) * chunk)
            }
            await counter.add(preCounted)
            progress?(preCounted, size)

            try await withThrowingTaskGroup(of: Void.self) { group in
                var next = 0
                let window = min(maxParallelParts, count)

                for _ in 0..<window {
                    let index = next; next += 1
                    group.addTask { [self] in
                        try await uploadOnePart(
                            bucket: bucket, key: key, uploadID: uploadID, file: file,
                            index: index, chunk: chunk, size: size,
                            skip: existingParts[index + 1] != nil,
                            collector: collector, counter: counter, progress: progress
                        )
                    }
                }
                while try await group.next() != nil {
                    guard next < count else { continue }
                    let index = next; next += 1
                    group.addTask { [self] in
                        try await uploadOnePart(
                            bucket: bucket, key: key, uploadID: uploadID, file: file,
                            index: index, chunk: chunk, size: size,
                            skip: existingParts[index + 1] != nil,
                            collector: collector, counter: counter, progress: progress
                        )
                    }
                }
            }

            let parts = await collector.sorted()
            try await completeMultipartUpload(
                bucket: bucket, key: key, uploadID: uploadID, parts: parts
            )
        } catch {
            if !(error is CancellationError) {
                try? await abortMultipartUpload(bucket: bucket, key: key, uploadID: uploadID)
            }
            throw error
        }
    }

    private func uploadOnePart(
        bucket: String, key: String, uploadID: String, file: URL,
        index: Int, chunk: Int64, size: Int64, skip: Bool,
        collector: PartCollector, counter: ByteCounter, progress: ProgressHandler?
    ) async throws {
        guard !skip else { return }
        try Task.checkCancellation()
        let offset = Int64(index) * chunk
        let length = min(chunk, size - offset)
        let data = try Self.readChunk(from: file, offset: offset, length: length)

        var request = try signedRequest(
            method: "PUT", bucket: bucket, key: key,
            query: [("partNumber", String(index + 1)), ("uploadId", uploadID)],
            payload: .data(data)
        )
        request.setValue(String(data.count), forHTTPHeaderField: "Content-Length")
        let result = try await http.upload(request, body: data)
        guard let etag = result.header("ETag") else {
            throw StorageError.provider("Part \(index + 1) came back without an ETag.")
        }
        await collector.record(number: index + 1, etag: etag)
        let done = await counter.add(length)
        progress?(done, size)
    }

    private func createMultipartUpload(bucket: String, key: String, contentType: String) async throws -> String {
        var request = try signedRequest(
            method: "POST", bucket: bucket, key: key, query: [("uploads", "")], payload: .empty
        )
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        try resign(&request, payload: .empty)
        let result = try await http.send(request)
        guard let id = XMLLite.parse(result.data)?.string("UploadId") else {
            throw StorageError.provider("S3 didn't return an upload ID.")
        }
        return id
    }

    private func completeMultipartUpload(
        bucket: String, key: String, uploadID: String, parts: [(Int, String)]
    ) async throws {
        var xml = #"<?xml version="1.0" encoding="UTF-8"?>"# + "\n<CompleteMultipartUpload>\n"
        for (number, etag) in parts.sorted(by: { $0.0 < $1.0 }) {
            let quoted = etag.hasPrefix("\"") ? etag : "\"\(etag)\""
            xml += "<Part><PartNumber>\(number)</PartNumber><ETag>\(quoted.xmlEscaped)</ETag></Part>\n"
        }
        xml += "</CompleteMultipartUpload>"
        let body = Data(xml.utf8)

        var request = try signedRequest(
            method: "POST", bucket: bucket, key: key,
            query: [("uploadId", uploadID)], payload: .data(body)
        )
        request.setValue("application/xml", forHTTPHeaderField: "Content-Type")
        try resign(&request, payload: .data(body))
        let result = try await http.upload(request, body: body)

        // Complete can return 200 with an error document in the body.
        if let root = XMLLite.parse(result.data), root.name == "Error" {
            throw StorageError.provider(root.string("Message") ?? "Completing the upload failed.")
        }
    }

    private func abortMultipartUpload(bucket: String, key: String, uploadID: String) async throws {
        let request = try signedRequest(
            method: "DELETE", bucket: bucket, key: key, query: [("uploadId", uploadID)]
        )
        _ = try await http.send(request, acceptableStatus: Set(200..<300).union([404]))
    }

    /// Finds an in-progress multipart upload for this key and the parts it
    /// already holds, so an interrupted upload can continue.
    private func findResumableUpload(
        bucket: String, key: String
    ) async throws -> (uploadID: String, parts: [Int: String])? {
        let listRequest = try signedRequest(
            method: "GET", bucket: bucket, key: "",
            query: [("uploads", ""), ("prefix", key), ("max-uploads", "100")]
        )
        guard let result = try? await http.send(listRequest),
              let root = XMLLite.parse(result.data)
        else { return nil }

        let candidates = root.descendants(named: "Upload")
            .filter { $0.string("Key") == key }
            .compactMap { node -> (String, Date)? in
                guard let id = node.string("UploadId") else { return nil }
                return (id, node.string("Initiated").flatMap(HTTPDate.parseISO8601) ?? .distantPast)
            }
        guard let newest = candidates.max(by: { $0.1 < $1.1 })?.0 else { return nil }

        var parts: [Int: String] = [:]
        var marker: String?
        repeat {
            var query: [(String, String)] = [("uploadId", newest), ("max-parts", "1000")]
            if let marker { query.append(("part-number-marker", marker)) }
            let request = try signedRequest(method: "GET", bucket: bucket, key: key, query: query)
            guard let result = try? await http.send(request),
                  let root = XMLLite.parse(result.data)
            else { break }
            for node in root.descendants(named: "Part") {
                guard let number = node.string("PartNumber").flatMap(Int.init),
                      let etag = node.string("ETag")
                else { continue }
                parts[number] = etag
            }
            marker = (root.bool("IsTruncated") ?? false) ? root.string("NextPartNumberMarker") : nil
        } while marker != nil

        return (newest, parts)
    }

    public func uploadStream(
        _ stream: AsyncThrowingStream<Data, Error>,
        length: Int64?,
        to path: RemotePath,
        contentType: String?,
        progress: ProgressHandler?
    ) async throws -> CloudItem {
        let (bucket, key) = config.resolve(path)
        guard let bucket, !key.isEmpty else {
            throw StorageError.invalidConfiguration("Pick a bucket to upload into.")
        }
        let type = contentType ?? MIMEType.forFilename(path.name)

        var buffer = Data()
        buffer.reserveCapacity(Int(partSize))
        var parts: [(Int, String)] = []
        var uploadID: String?
        var sent: Int64 = 0

        do {
            for try await incoming in stream {
                buffer.append(incoming)
                while Int64(buffer.count) >= partSize {
                    if uploadID == nil {
                        uploadID = try await createMultipartUpload(
                            bucket: bucket, key: key, contentType: type
                        )
                    }
                    let part = Data(buffer.prefix(Int(partSize)))
                    buffer.removeFirst(Int(partSize))
                    let number = parts.count + 1
                    let etag = try await uploadStreamedPart(
                        bucket: bucket, key: key, uploadID: uploadID!, number: number, data: part
                    )
                    parts.append((number, etag))
                    sent += Int64(part.count)
                    progress?(sent, length)
                }
            }

            if let id = uploadID {
                if !buffer.isEmpty {
                    let number = parts.count + 1
                    let etag = try await uploadStreamedPart(
                        bucket: bucket, key: key, uploadID: id, number: number, data: buffer
                    )
                    parts.append((number, etag))
                    sent += Int64(buffer.count)
                    progress?(sent, length)
                }
                try await completeMultipartUpload(
                    bucket: bucket, key: key, uploadID: id, parts: parts
                )
            } else {
                // Small enough that one PUT beats a multipart handshake.
                var request = try signedRequest(
                    method: "PUT", bucket: bucket, key: key, query: [], payload: .data(buffer)
                )
                request.setValue(type, forHTTPHeaderField: "Content-Type")
                try resign(&request, payload: .data(buffer))
                _ = try await http.upload(request, body: buffer)
                sent = Int64(buffer.count)
                progress?(sent, length ?? sent)
            }
        } catch {
            if let id = uploadID {
                try? await abortMultipartUpload(bucket: bucket, key: key, uploadID: id)
            }
            throw error
        }

        return CloudItem(name: path.name, path: path, kind: .file,
                         size: sent, modified: Date(), contentType: type)
    }

    private func uploadStreamedPart(
        bucket: String, key: String, uploadID: String, number: Int, data: Data
    ) async throws -> String {
        var request = try signedRequest(
            method: "PUT", bucket: bucket, key: key,
            query: [("partNumber", String(number)), ("uploadId", uploadID)],
            payload: .data(data)
        )
        request.setValue(String(data.count), forHTTPHeaderField: "Content-Length")
        let result = try await http.upload(request, body: data)
        guard let etag = result.header("ETag") else {
            throw StorageError.provider("Part \(number) came back without an ETag.")
        }
        return etag
    }

    // MARK: - Sharing

    public func signedURL(for item: CloudItem, expiresIn: TimeInterval) async throws -> URL {
        let (bucket, key) = config.resolve(item.path)
        guard let bucket, !key.isEmpty else {
            throw StorageError.unsupported("Only an object can be shared as a link.")
        }
        let url = try config.url(bucket: bucket, key: key, query: [])
        return try SigV4.presignedURL(
            url: url,
            credentials: config.credentials,
            region: config.region,
            expiresIn: expiresIn
        )
    }

    // MARK: - Request building

    /// How the body should be represented in the signature.
    private enum Payload {
        case empty
        case data(Data)
        /// Body is a file we don't want to hash; `UNSIGNED-PAYLOAD` relies on TLS.
        case unsigned

        var hash: String {
            switch self {
            case .empty: SigV4.emptyBodySHA256
            case .data(let data): SigV4.sha256Hex(data)
            case .unsigned: SigV4.unsignedPayload
            }
        }
    }

    private func signedRequest(
        method: String,
        bucket: String?,
        key: String,
        query: [(String, String)],
        payload: Payload = .empty
    ) throws -> URLRequest {
        let url = try config.url(bucket: bucket, key: key, query: query)
        var request = URLRequest(url: url)
        request.httpMethod = method
        try SigV4.sign(
            request: &request,
            credentials: config.credentials,
            region: config.region,
            payloadHash: payload.hash
        )
        return request
    }

    /// Re-signs after headers were added, since SigV4 covers `x-amz-*`,
    /// `Content-Type`, and `Content-MD5`.
    private func resign(_ request: inout URLRequest, payload: Payload) throws {
        request.setValue(nil, forHTTPHeaderField: "Authorization")
        try SigV4.sign(
            request: &request,
            credentials: config.credentials,
            region: config.region,
            payloadHash: payload.hash
        )
    }

    private static func readChunk(from file: URL, offset: Int64, length: Int64) throws -> Data {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(offset))
        return try handle.read(upToCount: Int(length)) ?? Data()
    }
}

/// Collects part ETags from parallel uploads.
actor PartCollector {
    private var parts: [Int: String] = [:]

    func record(number: Int, etag: String) {
        parts[number] = etag
    }

    func sorted() -> [(Int, String)] {
        parts.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
    }
}
