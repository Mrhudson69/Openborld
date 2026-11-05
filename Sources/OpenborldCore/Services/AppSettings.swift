import Foundation
import Observation

public enum ViewMode: String, CaseIterable, Codable, Sendable, Identifiable {
    case list
    case grid
    case columns

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .list: "List"
        case .grid: "Grid"
        case .columns: "Columns"
        }
    }

    public var symbol: String {
        switch self {
        case .list: "list.bullet"
        case .grid: "square.grid.2x2"
        case .columns: "rectangle.split.3x1"
        }
    }
}

public enum SortField: String, CaseIterable, Codable, Sendable, Identifiable {
    case name
    case size
    case modified
    case kind

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .name: "Name"
        case .size: "Size"
        case .modified: "Date Modified"
        case .kind: "Kind"
        }
    }
}

@MainActor
@Observable
public final class AppSettings {
    public var viewMode: ViewMode { didSet { persistSoon() } }
    public var sortField: SortField { didSet { persistSoon() } }
    public var sortAscending: Bool { didSet { persistSoon() } }
    public var showHiddenFiles: Bool { didSet { persistSoon() } }
    public var foldersFirst: Bool { didSet { persistSoon() } }

    // Clamped settings keep their value in private storage. Clamping inside a
    // `didSet` would write the property from within its own setter, which
    // `@Observable` turns into unbounded recursion.
    private var concurrentTransfersStorage = 4
    private var chunksPerTransferStorage = 4
    private var pageSizeStorage = 1000

    /// Transfers running at once. The default is deliberately modest: more
    /// parallelism mostly redistributes the same bandwidth while multiplying
    /// memory and request overhead.
    public var maxConcurrentTransfers: Int {
        get { concurrentTransfersStorage }
        set {
            let clamped = max(1, min(newValue, 32))
            guard clamped != concurrentTransfersStorage else { return }
            concurrentTransfersStorage = clamped
            persistSoon()
        }
    }

    /// Parallel chunks within one large file's upload.
    public var chunksPerTransfer: Int {
        get { chunksPerTransferStorage }
        set {
            let clamped = max(1, min(newValue, 16))
            guard clamped != chunksPerTransferStorage else { return }
            chunksPerTransferStorage = clamped
            persistSoon()
        }
    }

    public var conflictPolicy: ConflictPolicy { didSet { persistSoon() } }
    public var downloadFolderPath: String { didSet { persistSoon() } }
    /// How many entries to request per listing page.
    public var pageSize: Int {
        get { pageSizeStorage }
        set {
            let clamped = max(100, min(newValue, 5000))
            guard clamped != pageSizeStorage else { return }
            pageSizeStorage = clamped
            persistSoon()
        }
    }
    public var confirmDeletes: Bool { didSet { persistSoon() } }
    public var useCachedListings: Bool { didSet { persistSoon() } }

    public var downloadFolder: URL {
        downloadFolderPath.isEmpty
            ? AppPaths.defaultDownloads
            : URL(fileURLWithPath: (downloadFolderPath as NSString).expandingTildeInPath)
    }

    private struct Storage: Codable {
        var viewMode: ViewMode = .list
        var sortField: SortField = .name
        var sortAscending = true
        var showHiddenFiles = false
        var foldersFirst = true
        var maxConcurrentTransfers = 4
        var chunksPerTransfer = 4
        var conflictPolicyRaw = ConflictPolicy.rename.rawValue
        var downloadFolderPath = ""
        var pageSize = 1000
        var confirmDeletes = true
        var useCachedListings = true
    }

    public init() {
        let stored = JSONFile.read(Storage.self, from: AppPaths.settingsFile) ?? Storage()
        viewMode = stored.viewMode
        sortField = stored.sortField
        sortAscending = stored.sortAscending
        showHiddenFiles = stored.showHiddenFiles
        foldersFirst = stored.foldersFirst
        concurrentTransfersStorage = max(1, min(stored.maxConcurrentTransfers, 32))
        chunksPerTransferStorage = max(1, min(stored.chunksPerTransfer, 16))
        conflictPolicy = ConflictPolicy(rawValue: stored.conflictPolicyRaw) ?? .rename
        downloadFolderPath = stored.downloadFolderPath
        pageSizeStorage = max(100, min(stored.pageSize, 5000))
        confirmDeletes = stored.confirmDeletes
        useCachedListings = stored.useCachedListings
    }

    private var pendingSave: Task<Void, Never>?

    private func persistSoon() {
        pendingSave?.cancel()
        pendingSave = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            self?.persist()
        }
    }

    public func persist() {
        let storage = Storage(
            viewMode: viewMode,
            sortField: sortField,
            sortAscending: sortAscending,
            showHiddenFiles: showHiddenFiles,
            foldersFirst: foldersFirst,
            maxConcurrentTransfers: maxConcurrentTransfers,
            chunksPerTransfer: chunksPerTransfer,
            conflictPolicyRaw: conflictPolicy.rawValue,
            downloadFolderPath: downloadFolderPath,
            pageSize: pageSize,
            confirmDeletes: confirmDeletes,
            useCachedListings: useCachedListings
        )
        Task.detached(priority: .utility) {
            try? JSONFile.write(storage, to: AppPaths.settingsFile)
        }
    }
}
