import Foundation

/// One location in a transfer: which connection, and where inside it.
public struct TransferEndpoint: Sendable, Hashable {
    public var connection: Connection
    public var path: RemotePath

    public init(connection: Connection, path: RemotePath) {
        self.connection = connection
        self.path = path
    }

    public var label: String {
        path.isRoot ? connection.name : "\(connection.name) › \(path.joined)"
    }
}

/// What to do when the destination already has a file of that name.
public enum ConflictPolicy: String, CaseIterable, Sendable, Identifiable {
    case ask
    case overwrite
    case skip
    case rename

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .ask: "Ask Me"
        case .overwrite: "Replace"
        case .skip: "Skip"
        case .rename: "Keep Both"
        }
    }
}

public struct Transfer: Identifiable, Sendable {
    public enum Kind: String, Sendable {
        case upload
        case download
        /// Remote to remote, streamed through this Mac.
        case remoteCopy
        /// Remote to remote, performed entirely by the provider.
        case serverSideCopy
        case localCopy

        public var symbol: String {
            switch self {
            case .upload: "arrow.up.circle"
            case .download: "arrow.down.circle"
            case .remoteCopy, .localCopy: "arrow.left.arrow.right.circle"
            case .serverSideCopy: "bolt.circle"
            }
        }
    }

    public enum Status: String, Sendable {
        case queued
        case running
        case paused
        case completed
        case failed
        case cancelled
        case skipped

        public var isActive: Bool { self == .queued || self == .running || self == .paused }
        public var isFinished: Bool { !isActive }

        public var displayName: String {
            switch self {
            case .queued: "Waiting"
            case .running: "Transferring"
            case .paused: "Paused"
            case .completed: "Completed"
            case .failed: "Failed"
            case .cancelled: "Cancelled"
            case .skipped: "Skipped"
            }
        }
    }

    public let id: UUID
    public var name: String
    public var kind: Kind
    public var source: TransferEndpoint
    public var destination: TransferEndpoint
    /// Whether the source was a folder, and this transfer is one file inside it.
    public var groupName: String?
    public var size: Int64?
    public var transferred: Int64
    public var status: Status
    /// Bytes per second, smoothed.
    public var speed: Double
    public var error: String?
    public var queuedAt: Date
    public var startedAt: Date?
    public var finishedAt: Date?
    public var isMove: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        kind: Kind,
        source: TransferEndpoint,
        destination: TransferEndpoint,
        groupName: String? = nil,
        size: Int64? = nil,
        isMove: Bool = false
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.source = source
        self.destination = destination
        self.groupName = groupName
        self.size = size
        self.transferred = 0
        self.status = .queued
        self.speed = 0
        self.queuedAt = Date()
        self.isMove = isMove
    }

    public var fraction: Double {
        guard let size, size > 0 else { return status == .completed ? 1 : 0 }
        return min(1, max(0, Double(transferred) / Double(size)))
    }

    /// Seconds remaining, or nil when there isn't enough information to say.
    public var estimatedTimeRemaining: TimeInterval? {
        guard status == .running, let size, size > 0, speed > 1 else { return nil }
        let remaining = Double(size - transferred)
        guard remaining > 0 else { return 0 }
        return remaining / speed
    }

    public var duration: TimeInterval? {
        guard let startedAt else { return nil }
        return (finishedAt ?? Date()).timeIntervalSince(startedAt)
    }

    /// Whether restarting this transfer is worth offering.
    public var isRetryable: Bool {
        status == .failed || status == .cancelled
    }
}

/// A finished transfer, kept for the Activity History list.
public struct TransferRecord: Codable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var kindRaw: String
    public var statusRaw: String
    public var sourceLabel: String
    public var destinationLabel: String
    public var size: Int64?
    public var transferred: Int64
    public var finishedAt: Date
    public var duration: TimeInterval?
    public var error: String?

    public init(from transfer: Transfer) {
        self.id = transfer.id
        self.name = transfer.name
        self.kindRaw = transfer.kind.rawValue
        self.statusRaw = transfer.status.rawValue
        self.sourceLabel = transfer.source.label
        self.destinationLabel = transfer.destination.label
        self.size = transfer.size
        self.transferred = transfer.transferred
        self.finishedAt = transfer.finishedAt ?? Date()
        self.duration = transfer.duration
        self.error = transfer.error
    }

    public var status: Transfer.Status {
        Transfer.Status(rawValue: statusRaw) ?? .completed
    }

    public var kind: Transfer.Kind {
        Transfer.Kind(rawValue: kindRaw) ?? .download
    }

    /// Average throughput over the whole transfer.
    public var averageSpeed: Double? {
        guard let duration, duration > 0.1, transferred > 0 else { return nil }
        return Double(transferred) / duration
    }
}
