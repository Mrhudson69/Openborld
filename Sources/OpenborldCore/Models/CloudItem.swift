import Foundation

/// One row in a listing: a file, a folder/prefix, or a container/bucket.
public struct CloudItem: Identifiable, Hashable, Sendable, Codable {
    public enum Kind: String, Sendable, Codable {
        case file
        case folder
        /// A container, bucket, share, or drive — a top-level namespace.
        case container

        public var isDirectoryLike: Bool { self != .file }
    }

    /// Stable identity within a connection.
    public var id: String { path.joined + (kind == .file ? "" : "/") }

    public var name: String
    public var path: RemotePath
    public var kind: Kind
    public var size: Int64?
    public var modified: Date?
    public var created: Date?
    public var etag: String?
    public var contentType: String?
    /// Provider-specific tier, e.g. Azure access tier or S3 storage class.
    public var storageClass: String?
    /// POSIX-ish mode string for protocols that report one (SFTP, FTP, SMB).
    public var permissions: String?
    public var isSymlink: Bool
    /// True when a listing only partially described the item and a HEAD would
    /// fill in size/modified/etc. Lets the UI avoid showing a confident blank.
    public var isPartial: Bool

    public init(
        name: String,
        path: RemotePath,
        kind: Kind,
        size: Int64? = nil,
        modified: Date? = nil,
        created: Date? = nil,
        etag: String? = nil,
        contentType: String? = nil,
        storageClass: String? = nil,
        permissions: String? = nil,
        isSymlink: Bool = false,
        isPartial: Bool = false
    ) {
        self.name = name
        self.path = path
        self.kind = kind
        self.size = size
        self.modified = modified
        self.created = created
        self.etag = etag
        self.contentType = contentType
        self.storageClass = storageClass
        self.permissions = permissions
        self.isSymlink = isSymlink
        self.isPartial = isPartial
    }

    public var isDirectory: Bool { kind.isDirectoryLike }

    /// Lowercased extension without the dot, or nil for folders and extensionless files.
    public var fileExtension: String? {
        guard kind == .file else { return nil }
        let ext = (name as NSString).pathExtension
        return ext.isEmpty ? nil : ext.lowercased()
    }

    public static func folder(name: String, at path: RemotePath) -> CloudItem {
        CloudItem(name: name, path: path, kind: .folder)
    }

    public static func container(name: String, at path: RemotePath, modified: Date? = nil) -> CloudItem {
        CloudItem(name: name, path: path, kind: .container, modified: modified)
    }
}

/// One page of a directory listing.
public struct Listing: Sendable {
    public var items: [CloudItem]
    /// Opaque continuation token; nil means the listing is complete.
    public var nextCursor: String?

    public init(items: [CloudItem], nextCursor: String? = nil) {
        self.items = items
        self.nextCursor = nextCursor
    }

    public static let empty = Listing(items: [])
}

/// What a provider can actually do, so the UI can disable rather than fail.
public struct ProviderCapabilities: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let createFolder       = ProviderCapabilities(rawValue: 1 << 0)
    public static let delete             = ProviderCapabilities(rawValue: 1 << 1)
    public static let rename             = ProviderCapabilities(rawValue: 1 << 2)
    /// Copy within the same connection without a round trip through the client.
    public static let serverSideCopy     = ProviderCapabilities(rawValue: 1 << 3)
    /// Can create top-level containers/buckets.
    public static let createContainer    = ProviderCapabilities(rawValue: 1 << 4)
    /// Can mint a time-limited public URL (SAS, presigned URL, share link).
    public static let signedURL          = ProviderCapabilities(rawValue: 1 << 5)
    /// Supports HTTP range reads, which is what makes download resume possible.
    public static let rangeDownload      = ProviderCapabilities(rawValue: 1 << 6)
    /// Chunked/multipart upload, which is what makes upload resume possible.
    public static let chunkedUpload      = ProviderCapabilities(rawValue: 1 << 7)
    public static let metadata           = ProviderCapabilities(rawValue: 1 << 8)
    /// Server-side search, as opposed to filtering what we already listed.
    public static let search             = ProviderCapabilities(rawValue: 1 << 9)
    /// True filesystem semantics: directories exist on their own, move is atomic.
    public static let realDirectories    = ProviderCapabilities(rawValue: 1 << 10)
    public static let permissions        = ProviderCapabilities(rawValue: 1 << 11)

    public static let objectStorage: ProviderCapabilities = [
        .createFolder, .delete, .rename, .serverSideCopy, .createContainer,
        .signedURL, .rangeDownload, .chunkedUpload, .metadata,
    ]

    public static let filesystem: ProviderCapabilities = [
        .createFolder, .delete, .rename, .serverSideCopy, .rangeDownload,
        .chunkedUpload, .realDirectories, .permissions, .metadata,
    ]
}
