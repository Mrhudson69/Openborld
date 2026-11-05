import Foundation

public typealias ProgressHandler = @Sendable (_ bytesCompleted: Int64, _ bytesTotal: Int64?) -> Void

/// The single surface the UI and transfer engine talk to. Every backend — local
/// disk, Azure, S3, WebDAV — is reached only through this, so adding a provider
/// never requires touching a view.
public protocol StorageProvider: AnyObject, Sendable {
    var connection: Connection { get }
    var kind: ProviderKind { get }
    var capabilities: ProviderCapabilities { get }

    /// Cheap, idempotent credential and reachability check. Used by "Test
    /// Connection" and on first use of a saved connection.
    func validate() async throws

    /// One page of a listing. `cursor` is the provider's own continuation token.
    func list(_ path: RemotePath, cursor: String?, pageSize: Int) async throws -> Listing

    /// Full detail for one item, for providers whose listings are partial.
    func stat(_ path: RemotePath) async throws -> CloudItem

    /// Provider metadata and properties, ordered for display.
    func metadata(_ path: RemotePath) async throws -> [(key: String, value: String)]

    func createFolder(at path: RemotePath) async throws
    func createContainer(named name: String) async throws
    func delete(_ item: CloudItem) async throws

    /// Server-side copy within this connection. Throws `.unsupported` when the
    /// provider can't, which tells the transfer engine to stream instead.
    func copy(_ item: CloudItem, to destination: RemotePath) async throws
    func move(_ item: CloudItem, to destination: RemotePath) async throws

    func download(_ item: CloudItem, to localURL: URL, progress: ProgressHandler?) async throws
    func upload(
        _ localURL: URL,
        to path: RemotePath,
        contentType: String?,
        progress: ProgressHandler?
    ) async throws -> CloudItem

    /// A time-limited URL anyone can fetch: SAS, presigned URL, or share link.
    func signedURL(for item: CloudItem, expiresIn: TimeInterval) async throws -> URL

    /// Read bytes without staging a file — used for previews and small reads.
    func read(_ item: CloudItem, range: ClosedRange<Int64>?) async throws -> Data

    /// Streaming read, for piping one provider straight into another.
    func readStream(_ item: CloudItem) async throws -> AsyncThrowingStream<Data, Error>

    /// Upload from a byte stream of known length, so a cross-provider transfer
    /// never needs a temp file on disk.
    func uploadStream(
        _ stream: AsyncThrowingStream<Data, Error>,
        length: Int64?,
        to path: RemotePath,
        contentType: String?,
        progress: ProgressHandler?
    ) async throws -> CloudItem
}

// MARK: - Defaults

public extension StorageProvider {
    var kind: ProviderKind { connection.kind }

    func stat(_ path: RemotePath) async throws -> CloudItem {
        let parent = path.parent
        let page = try await list(parent, cursor: nil, pageSize: 1000)
        if let hit = page.items.first(where: { $0.name == path.name }) { return hit }
        throw StorageError.notFound(path.description)
    }

    func metadata(_ path: RemotePath) async throws -> [(key: String, value: String)] { [] }

    func createContainer(named name: String) async throws {
        throw StorageError.unsupported("Creating a \(kind.containerNoun.lowercased()) isn't supported by \(kind.displayName).")
    }

    func copy(_ item: CloudItem, to destination: RemotePath) async throws {
        throw StorageError.unsupported("Server-side copy isn't supported by \(kind.displayName).")
    }

    func move(_ item: CloudItem, to destination: RemotePath) async throws {
        try await copy(item, to: destination)
        try await delete(item)
    }

    func signedURL(for item: CloudItem, expiresIn: TimeInterval) async throws -> URL {
        throw StorageError.unsupported("\(kind.displayName) can't generate a shareable link.")
    }

    func read(_ item: CloudItem, range: ClosedRange<Int64>?) async throws -> Data {
        var out = Data()
        for try await chunk in try await readStream(item) { out.append(chunk) }
        if let range {
            let lower = Int(min(Int64(out.count), max(0, range.lowerBound)))
            let upper = Int(min(Int64(out.count), range.upperBound + 1))
            guard lower < upper else { return Data() }
            return out.subdata(in: lower..<upper)
        }
        return out
    }

    func uploadStream(
        _ stream: AsyncThrowingStream<Data, Error>,
        length: Int64?,
        to path: RemotePath,
        contentType: String?,
        progress: ProgressHandler?
    ) async throws -> CloudItem {
        // Fallback: spool to a temp file, then use the file-based upload. Providers
        // that can stream directly override this.
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("openborld-spool-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: temp.path, contents: nil, attributes: nil)
        let handle = try FileHandle(forWritingTo: temp)
        defer {
            try? handle.close()
            try? FileManager.default.removeItem(at: temp)
        }
        for try await chunk in stream { try handle.write(contentsOf: chunk) }
        try handle.close()
        return try await upload(temp, to: path, contentType: contentType, progress: progress)
    }

    /// Walks every page of a listing. Callers get items as soon as each page
    /// lands rather than waiting for a huge directory to finish.
    func enumerate(_ path: RemotePath, pageSize: Int = 1000) -> AsyncThrowingStream<[CloudItem], Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var cursor: String? = nil
                repeat {
                    do {
                        let page = try await list(path, cursor: cursor, pageSize: pageSize)
                        if !page.items.isEmpty { continuation.yield(page.items) }
                        cursor = page.nextCursor
                    } catch {
                        continuation.finish(throwing: error)
                        return
                    }
                } while cursor != nil && !Task.isCancelled
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Depth-first walk yielding only files, with their path relative to `root`.
    /// This is how a folder upload/download/copy gets expanded into transfers.
    func walkFiles(from root: RemotePath) -> AsyncThrowingStream<CloudItem, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var queue: [RemotePath] = [root]
                while !queue.isEmpty, !Task.isCancelled {
                    let dir = queue.removeFirst()
                    do {
                        for try await batch in enumerate(dir) {
                            for item in batch {
                                if item.isDirectory { queue.append(item.path) }
                                else { continuation.yield(item) }
                            }
                        }
                    } catch {
                        continuation.finish(throwing: error)
                        return
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Byte offset a download should restart from.
    ///
    /// A leftover partial file only counts as resumable when we know the real
    /// size and the partial is strictly smaller — otherwise a truncated or
    /// already-complete file would be silently accepted as correct.
    static func resumeOffset(for localURL: URL, expecting total: Int64?) -> Int64 {
        guard let total, total > 0,
              let attributes = try? FileManager.default.attributesOfItem(atPath: localURL.path),
              let size = attributes[.size] as? NSNumber
        else { return 0 }
        let partial = size.int64Value
        return (partial > 0 && partial < total) ? partial : 0
    }

    /// Deletes a folder and everything under it. Object stores get a flat sweep;
    /// real filesystems override this with a single recursive call.
    func deleteRecursively(_ item: CloudItem) async throws {
        guard item.isDirectory else {
            try await delete(item)
            return
        }
        var directories: [RemotePath] = []
        var queue: [RemotePath] = [item.path]
        while !queue.isEmpty {
            let dir = queue.removeFirst()
            directories.append(dir)
            for try await batch in enumerate(dir) {
                for child in batch {
                    if child.isDirectory { queue.append(child.path) }
                    else { try await delete(child) }
                }
            }
        }
        // Deepest first, so a real filesystem never tries to remove a non-empty dir.
        for dir in directories.sorted(by: { $0.depth > $1.depth }) {
            let placeholder = CloudItem(name: dir.name, path: dir, kind: .folder)
            try? await delete(placeholder)
        }
    }
}

// MARK: - Errors

public enum StorageError: LocalizedError, Sendable {
    case unsupported(String)
    case notFound(String)
    case accessDenied(String)
    case authenticationFailed(String)
    case invalidConfiguration(String)
    case conflict(String)
    case network(String)
    case http(status: Int, message: String)
    case cancelled
    case provider(String)

    public var errorDescription: String? {
        switch self {
        case .unsupported(let m): m
        case .notFound(let m): "Not found: \(m)"
        case .accessDenied(let m): "Access denied: \(m)"
        case .authenticationFailed(let m): "Authentication failed: \(m)"
        case .invalidConfiguration(let m): m
        case .conflict(let m): m
        case .network(let m): m
        case .http(let status, let message):
            message.isEmpty ? "Server returned HTTP \(status)." : "HTTP \(status): \(message)"
        case .cancelled: "Cancelled."
        case .provider(let m): m
        }
    }

    /// Whether retrying the same request stands a chance.
    public var isRetryable: Bool {
        switch self {
        case .network: true
        case .http(let status, _): status == 408 || status == 429 || (500...599).contains(status)
        default: false
        }
    }

    public var isAuthFailure: Bool {
        switch self {
        case .authenticationFailed, .accessDenied: true
        case .http(let status, _): status == 401 || status == 403
        default: false
        }
    }
}
