import Foundation

public enum ProviderKind: String, Codable, CaseIterable, Sendable, Identifiable {
    // Local
    case local

    // Object storage
    case azureBlob
    case s3
    case gcs
    case backblazeB2
    case s3Compatible
    case openStackSwift

    // Cloud drives
    case googleDrive
    case dropbox
    case oneDrive
    case sharePoint
    case box
    case nextcloud
    case ownCloud
    case dracoon
    case filesCom

    // Protocols
    case ftp
    case ftps
    case sftp
    case webdav
    case smb

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .local: "This Mac"
        case .azureBlob: "Azure Blob Storage"
        case .s3: "Amazon S3"
        case .gcs: "Google Cloud Storage"
        case .backblazeB2: "Backblaze B2"
        case .s3Compatible: "S3-Compatible Storage"
        case .openStackSwift: "OpenStack Swift"
        case .googleDrive: "Google Drive"
        case .dropbox: "Dropbox"
        case .oneDrive: "Microsoft OneDrive"
        case .sharePoint: "SharePoint Online"
        case .box: "Box"
        case .nextcloud: "Nextcloud"
        case .ownCloud: "ownCloud"
        case .dracoon: "DRACOON"
        case .filesCom: "Files.com"
        case .ftp: "FTP"
        case .ftps: "FTPS"
        case .sftp: "SFTP"
        case .webdav: "WebDAV"
        case .smb: "SMB / Windows Share"
        }
    }

    /// SF Symbol used in the sidebar and provider picker.
    public var symbol: String {
        switch self {
        case .local: "laptopcomputer"
        case .azureBlob: "cube.transparent"
        case .s3, .s3Compatible: "shippingbox"
        case .gcs: "cube"
        case .backblazeB2: "flame"
        case .openStackSwift: "circle.hexagongrid"
        case .googleDrive: "triangle"
        case .dropbox: "shippingbox.fill"
        case .oneDrive, .sharePoint: "cloud"
        case .box: "archivebox"
        case .nextcloud, .ownCloud: "circle.grid.cross"
        case .dracoon: "shield.lefthalf.filled"
        case .filesCom: "folder.badge.gearshape"
        case .ftp, .ftps: "arrow.up.arrow.down.circle"
        case .sftp: "lock.shield"
        case .webdav: "globe"
        case .smb: "network"
        }
    }

    public var category: Category {
        switch self {
        case .local: .local
        case .azureBlob, .s3, .gcs, .backblazeB2, .s3Compatible, .openStackSwift: .objectStorage
        case .googleDrive, .dropbox, .oneDrive, .sharePoint, .box,
             .nextcloud, .ownCloud, .dracoon, .filesCom: .cloudDrive
        case .ftp, .ftps, .sftp, .webdav, .smb: .protocolBased
        }
    }

    public enum Category: String, CaseIterable, Sendable, Identifiable {
        case local = "Local"
        case objectStorage = "Object Storage"
        case cloudDrive = "Cloud Drives"
        case protocolBased = "File Transfer Protocols"

        public var id: String { rawValue }
    }

    /// Whether a working provider implementation is wired up. The Add Connection
    /// picker uses this to mark the rest as unavailable instead of offering a
    /// provider that would fail on first use.
    public var isImplemented: Bool {
        switch self {
        case .local, .azureBlob, .s3, .s3Compatible, .backblazeB2, .gcs,
             .webdav, .nextcloud, .ownCloud:
            true
        default:
            false
        }
    }

    /// Objects stored under a flat keyspace with simulated folders. Affects how
    /// rename/move and "create folder" behave.
    public var isObjectStore: Bool {
        switch self {
        case .azureBlob, .s3, .s3Compatible, .gcs, .backblazeB2, .openStackSwift: true
        default: false
        }
    }

    /// What a top-level namespace is called in this provider's own vocabulary.
    public var containerNoun: String {
        switch self {
        case .azureBlob: "Container"
        case .s3, .s3Compatible, .gcs, .backblazeB2: "Bucket"
        case .openStackSwift: "Container"
        case .sharePoint: "Site"
        default: "Folder"
        }
    }
}
