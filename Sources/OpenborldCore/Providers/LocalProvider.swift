import Foundation

/// The user's own Mac, presented through the same interface as every cloud
/// backend. That's what lets the dual-pane view treat "local to Azure" as an
/// ordinary transfer rather than a special case.
public final class LocalProvider: StorageProvider, @unchecked Sendable {
    public let connection: Connection
    private let root: URL
    private let fm = FileManager.default

    /// Chunk size for streaming reads — large enough to keep syscall overhead
    /// invisible, small enough that memory stays flat on huge files.
    private static let streamChunk = 4 * 1024 * 1024

    public init(connection: Connection) {
        self.connection = connection
        let configured = connection.setting(.rootPath)
        self.root = configured.isEmpty
            ? fm.homeDirectoryForCurrentUser
            : URL(fileURLWithPath: (configured as NSString).expandingTildeInPath)
    }

    public static func mac() -> LocalProvider {
        LocalProvider(connection: Connection(
            id: LocalProvider.macConnectionID,
            name: "This Mac",
            kind: .local,
            // Rooted at the filesystem root so no volume or path is out of
            // reach; the sidebar's favourites start the user at their home folder.
            settings: [SettingKey.rootPath.rawValue: "/"]
        ))
    }

    /// Fixed id so the built-in local connection keeps its favourites and
    /// cached listings across launches.
    public static let macConnectionID = UUID(uuidString: "00000000-0000-0000-0000-0000000010CA")!

    public var kind: ProviderKind { .local }
    public var capabilities: ProviderCapabilities { .filesystem }

    /// Whether a local delete is recoverable. Only macOS has a Trash to put
    /// the file in; the confirmation wording depends on this.
    public static var deleteIsRecoverable: Bool {
        #if os(macOS)
        true
        #else
        false
        #endif
    }

    public var rootURL: URL { root }

    public func url(for path: RemotePath) -> URL {
        path.components.reduce(root) { $0.appendingPathComponent($1) }
    }

    /// Maps a filesystem URL back to a path, when it's inside this root.
    public func path(for url: URL) -> RemotePath? {
        let rootComponents = root.standardizedFileURL.pathComponents
        let components = url.standardizedFileURL.pathComponents
        guard components.count >= rootComponents.count,
              Array(components.prefix(rootComponents.count)) == rootComponents
        else { return nil }
        return RemotePath(components: Array(components.dropFirst(rootComponents.count)))
    }

    public func validate() async throws {
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw StorageError.notFound("The folder \(root.path) doesn't exist.")
        }
        guard fm.isReadableFile(atPath: root.path) else {
            throw StorageError.accessDenied(
                "macOS is blocking access to \(root.lastPathComponent). Grant access in System Settings › Privacy & Security › Files and Folders."
            )
        }
    }

    // MARK: - Listing

    public func list(_ path: RemotePath, cursor: String?, pageSize: Int) async throws -> Listing {
        let directory = url(for: path)
        // `contentTypeKey` and `isPackageKey` are Apple-only resource keys.
        var keys: [URLResourceKey] = [
            .isDirectoryKey, .fileSizeKey, .contentModificationDateKey,
            .creationDateKey, .isSymbolicLinkKey, .isHiddenKey,
        ]
        #if os(macOS) || os(iOS)
        keys += [.contentTypeKey, .isPackageKey]
        #endif

        let contents: [URL]
        do {
            contents = try fm.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: keys,
                options: [.skipsSubdirectoryDescendants]
            )
        } catch let error as NSError {
            throw Self.translate(error, path: directory.path)
        }

        // Paging a local directory keeps the first screen instant even in a
        // folder with a hundred thousand files.
        let offset = Int(cursor ?? "0") ?? 0
        let slice = contents.dropFirst(offset).prefix(pageSize)
        var items: [CloudItem] = []
        items.reserveCapacity(slice.count)

        for entry in slice {
            let values = try? entry.resourceValues(forKeys: Set(keys))
            if values?.isHidden == true, !showHidden { continue }
            #if os(macOS) || os(iOS)
            let isDirectory = (values?.isDirectory ?? false) && (values?.isPackage != true)
            let contentType = values?.contentType?.preferredMIMEType
            #else
            let isDirectory = values?.isDirectory ?? false
            let contentType = MIMEType.forFilename(entry.lastPathComponent)
            #endif
            items.append(CloudItem(
                name: entry.lastPathComponent,
                path: path.appending(entry.lastPathComponent),
                kind: isDirectory ? .folder : .file,
                size: isDirectory ? nil : values?.fileSize.map(Int64.init),
                modified: values?.contentModificationDate,
                created: values?.creationDate,
                contentType: contentType,
                permissions: Self.permissionString(for: entry),
                isSymlink: values?.isSymbolicLink ?? false
            ))
        }

        let consumed = offset + slice.count
        return Listing(
            items: items,
            nextCursor: consumed < contents.count ? String(consumed) : nil
        )
    }

    private var showHidden: Bool {
        connection.boolSetting(.showHiddenFiles)
    }

    public func stat(_ path: RemotePath) async throws -> CloudItem {
        let entry = url(for: path)
        var keys: Set<URLResourceKey> = [
            .isDirectoryKey, .fileSizeKey, .contentModificationDateKey,
            .creationDateKey, .isSymbolicLinkKey,
        ]
        #if os(macOS) || os(iOS)
        keys.insert(.contentTypeKey)
        #endif
        guard let values = try? entry.resourceValues(forKeys: keys) else {
            throw StorageError.notFound(path.description)
        }
        let isDirectory = values.isDirectory ?? false
        return CloudItem(
            name: path.isRoot ? root.lastPathComponent : path.name,
            path: path,
            kind: isDirectory ? .folder : .file,
            size: isDirectory ? nil : values.fileSize.map(Int64.init),
            modified: values.contentModificationDate,
            created: values.creationDate,
            contentType: statContentType(values, name: path.name),
            permissions: Self.permissionString(for: entry),
            isSymlink: values.isSymbolicLink ?? false
        )
    }

    private func statContentType(_ values: URLResourceValues, name: String) -> String? {
        #if os(macOS) || os(iOS)
        return values.contentType?.preferredMIMEType
        #else
        return MIMEType.forFilename(name)
        #endif
    }

    public func metadata(_ path: RemotePath) async throws -> [(key: String, value: String)] {
        let entry = url(for: path)
        guard let attributes = try? fm.attributesOfItem(atPath: entry.path) else { return [] }
        var rows: [(key: String, value: String)] = [("Path", entry.path)]

        if let size = attributes[.size] as? NSNumber {
            rows.append(("Size", ByteFormat.bytes(size.int64Value)))
        }
        if let type = attributes[.type] as? FileAttributeType {
            rows.append(("Kind", Self.describe(type)))
        }
        if let created = attributes[.creationDate] as? Date {
            rows.append(("Created", DateFormatter.openborldFull.string(from: created)))
        }
        if let modified = attributes[.modificationDate] as? Date {
            rows.append(("Modified", DateFormatter.openborldFull.string(from: modified)))
        }
        if let owner = attributes[.ownerAccountName] as? String {
            rows.append(("Owner", owner))
        }
        if let group = attributes[.groupOwnerAccountName] as? String {
            rows.append(("Group", group))
        }
        if let permissions = attributes[.posixPermissions] as? NSNumber {
            rows.append(("Permissions", String(permissions.intValue, radix: 8)))
        }
        if let flags = attributes[.immutable] as? Bool, flags {
            rows.append(("Locked", "Yes"))
        }
        return rows
    }

    // MARK: - Mutations

    public func createFolder(at path: RemotePath) async throws {
        do {
            try fm.createDirectory(at: url(for: path), withIntermediateDirectories: true)
        } catch let error as NSError {
            throw Self.translate(error, path: path.description)
        }
    }

    public func delete(_ item: CloudItem) async throws {
        let target = url(for: item.path)
        guard fm.fileExists(atPath: target.path) else { return }
        #if os(macOS)
        do {
            // Trash rather than unlink: a mistaken delete on the user's own Mac
            // should be recoverable from Finder.
            try fm.trashItem(at: target, resultingItemURL: nil)
            return
        } catch {
            // Fall through: some volumes have no trash.
        }
        #endif

        do {
            try fm.removeItem(at: target)
        } catch let error as NSError {
            throw Self.translate(error, path: item.path.description)
        }
    }

    public func deleteRecursively(_ item: CloudItem) async throws {
        // The filesystem already removes a tree in one call.
        try await delete(item)
    }

    public func copy(_ item: CloudItem, to destination: RemotePath) async throws {
        let source = url(for: item.path)
        let target = url(for: destination)
        try fm.createDirectory(
            at: target.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
        do {
            // APFS makes this a clone: instant and free, whatever the file size.
            try fm.copyItem(at: source, to: target)
        } catch let error as NSError {
            throw Self.translate(error, path: destination.description)
        }
    }

    public func move(_ item: CloudItem, to destination: RemotePath) async throws {
        let source = url(for: item.path)
        let target = url(for: destination)
        try fm.createDirectory(
            at: target.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        do {
            try fm.moveItem(at: source, to: target)
        } catch let error as NSError {
            throw Self.translate(error, path: destination.description)
        }
    }

    // MARK: - Transfer

    public func download(_ item: CloudItem, to localURL: URL, progress: ProgressHandler?) async throws {
        try await copyFile(from: url(for: item.path), to: localURL, progress: progress)
    }

    public func upload(
        _ localURL: URL,
        to path: RemotePath,
        contentType: String?,
        progress: ProgressHandler?
    ) async throws -> CloudItem {
        let target = url(for: path)
        try await copyFile(from: localURL, to: target, progress: progress)
        return try await stat(path)
    }

    /// Clones when the two paths are on the same volume, streams when they
    /// aren't. The clone path is why a local duplicate of a 10 GB file is instant.
    private func copyFile(from source: URL, to target: URL, progress: ProgressHandler?) async throws {
        try fm.createDirectory(
            at: target.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let size = (try? fm.attributesOfItem(atPath: source.path)[.size] as? NSNumber)?.int64Value

        if fm.fileExists(atPath: target.path) { try? fm.removeItem(at: target) }
        do {
            try fm.copyItem(at: source, to: target)
            progress?(size ?? 0, size)
        } catch let error as NSError {
            throw Self.translate(error, path: target.path)
        }
    }

    public func readStream(_ item: CloudItem) async throws -> AsyncThrowingStream<Data, Error> {
        let source = url(for: item.path)
        return AsyncThrowingStream { continuation in
            let task = Task.detached(priority: .utility) {
                do {
                    let handle = try FileHandle(forReadingFrom: source)
                    defer { try? handle.close() }
                    while !Task.isCancelled {
                        guard let chunk = try handle.read(upToCount: Self.streamChunk),
                              !chunk.isEmpty
                        else { break }
                        continuation.yield(chunk)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func read(_ item: CloudItem, range: ClosedRange<Int64>?) async throws -> Data {
        let source = url(for: item.path)
        let handle = try FileHandle(forReadingFrom: source)
        defer { try? handle.close() }
        guard let range else {
            return try handle.readToEnd() ?? Data()
        }
        try handle.seek(toOffset: UInt64(max(0, range.lowerBound)))
        let length = Int(range.upperBound - range.lowerBound + 1)
        return try handle.read(upToCount: length) ?? Data()
    }

    public func uploadStream(
        _ stream: AsyncThrowingStream<Data, Error>,
        length: Int64?,
        to path: RemotePath,
        contentType: String?,
        progress: ProgressHandler?
    ) async throws -> CloudItem {
        let target = url(for: path)
        try fm.createDirectory(
            at: target.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        // Write beside the destination and rename on success, so an interrupted
        // download never leaves a half file where a good one used to be.
        let staging = target.deletingLastPathComponent()
            .appendingPathComponent(".\(target.lastPathComponent).openborld-part")
        fm.createFile(atPath: staging.path, contents: nil, attributes: nil)
        let handle = try FileHandle(forWritingTo: staging)
        var written: Int64 = 0
        do {
            for try await chunk in stream {
                try handle.write(contentsOf: chunk)
                written += Int64(chunk.count)
                progress?(written, length)
            }
            try handle.close()
        } catch {
            try? handle.close()
            try? fm.removeItem(at: staging)
            throw error
        }
        if fm.fileExists(atPath: target.path) { try? fm.removeItem(at: target) }
        try fm.moveItem(at: staging, to: target)
        return try await stat(path)
    }

    public func signedURL(for item: CloudItem, expiresIn: TimeInterval) async throws -> URL {
        url(for: item.path)
    }

    // MARK: - Helpers

    private static func permissionString(for url: URL) -> String? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let mode = attributes[.posixPermissions] as? NSNumber
        else { return nil }
        let bits = mode.uint16Value
        var out = ""
        for shift in [6, 3, 0] {
            let triad = (bits >> UInt16(shift)) & 0b111
            out += (triad & 0b100) != 0 ? "r" : "-"
            out += (triad & 0b010) != 0 ? "w" : "-"
            out += (triad & 0b001) != 0 ? "x" : "-"
        }
        return out
    }

    private static func describe(_ type: FileAttributeType) -> String {
        switch type {
        case .typeDirectory: "Folder"
        case .typeRegular: "File"
        case .typeSymbolicLink: "Symbolic link"
        case .typeSocket: "Socket"
        case .typeBlockSpecial: "Block device"
        case .typeCharacterSpecial: "Character device"
        default: "Unknown"
        }
    }

    /// Turns Cocoa error codes into messages that say what to do next. macOS
/// sandbox denials are the common case and need their own wording.
    private static func translate(_ error: NSError, path: String) -> StorageError {
        switch error.code {
        case NSFileReadNoSuchFileError, NSFileNoSuchFileError:
            return .notFound(path)
        case NSFileReadNoPermissionError, NSFileWriteNoPermissionError:
            return .accessDenied(
                "macOS is blocking access to \(path). Grant access in System Settings › Privacy & Security › Files and Folders."
            )
        case NSFileWriteFileExistsError:
            return .conflict("\(path) already exists.")
        case NSFileWriteOutOfSpaceError:
            return .provider("The disk is full.")
        case NSFileWriteVolumeReadOnlyError:
            return .accessDenied("That volume is read-only.")
        default:
            return .provider(error.localizedDescription)
        }
    }
}

public extension DateFormatter {
    /// Date and time, medium both — used wherever a full timestamp is shown.
    static let openborldFull: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return formatter
    }()
}
