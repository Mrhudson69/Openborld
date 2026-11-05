import Foundation
import Observation
import OpenborldCore

/// Everything one pane is showing, plus how it got there.
///
/// The load sequence is deliberate: paint the cached listing immediately, then
/// replace it with the first live page, then keep appending pages in the
/// background. The user sees content on the first frame and never waits for a
/// whole directory to finish enumerating.
@MainActor
@Observable
public final class BrowserModel: Identifiable {
    public let id = UUID()

    public private(set) var connection: Connection
    public private(set) var path: RemotePath

    /// Raw listing, in arrival order.
    public private(set) var items: [CloudItem] = []
    /// Filtered and sorted — what the views actually render. Kept as stored
    /// state rather than a computed property so a 20,000-row directory isn't
    /// re-sorted on every SwiftUI update.
    public private(set) var visibleItems: [CloudItem] = []

    public private(set) var isLoading = false
    /// True while live data replaces a cached listing already on screen.
    public private(set) var isRefreshing = false
    public private(set) var error: String?
    public private(set) var hasMore = false
    public private(set) var loadedFromCache = false

    public var selection: Set<String> = []

    public var searchText = "" {
        didSet { if oldValue != searchText { applyFilters() } }
    }

    public var sortField: SortField {
        didSet { if oldValue != sortField { applyFilters() } }
    }

    public var sortAscending: Bool {
        didSet { if oldValue != sortAscending { applyFilters() } }
    }

    private var cursor: String?
    private var loadTask: Task<Void, Never>?
    private var generation = 0

    private let settings: AppSettings
    private let places: PlacesStore
    private let connections: ConnectionStore
    private let registry = ProviderRegistry.shared

    /// Called whenever this pane settles on a new location.
    ///
    /// Lets the sidebar highlight follow the pane. Without it, the selection
    /// stays on whatever row was last clicked, and clicking that same row after
    /// browsing deeper is a no-op because the selection never changes.
    public var onLocationChange: ((UUID, RemotePath) -> Void)?

    /// Stop auto-paging here and let the user ask for more. Past this the cost
    /// of holding rows outweighs the chance anyone scrolls to them.
    private static let autoPageLimit = 20_000

    private struct Location: Equatable {
        var connectionID: UUID
        var path: RemotePath
    }

    private var backStack: [Location] = []
    private var forwardStack: [Location] = []

    public init(
        connection: Connection,
        path: RemotePath = .root,
        settings: AppSettings,
        places: PlacesStore,
        connections: ConnectionStore
    ) {
        self.connection = connection
        self.path = path
        self.settings = settings
        self.places = places
        self.connections = connections
        self.sortField = settings.sortField
        self.sortAscending = settings.sortAscending
    }

    // MARK: - Derived state

    public var canGoBack: Bool { !backStack.isEmpty }
    public var canGoForward: Bool { !forwardStack.isEmpty }
    public var canGoUp: Bool { !path.isRoot }

    public var selectedItems: [CloudItem] {
        guard !selection.isEmpty else { return [] }
        return visibleItems.filter { selection.contains($0.id) }
    }

    public var capabilities: ProviderCapabilities {
        // Known statically per provider kind, so the toolbar can enable the
        // right buttons before any request completes.
        switch connection.kind {
        case .local: .filesystem
        case .azureBlob, .s3, .s3Compatible, .gcs, .backblazeB2: .objectStorage
        case .webdav, .nextcloud, .ownCloud:
            [.createFolder, .delete, .rename, .serverSideCopy, .realDirectories, .metadata]
        default: [.delete, .rename]
        }
    }

    /// True at the root of an object-storage connection, where the rows are
    /// containers rather than folders and most operations don't apply.
    public var isAtContainerRoot: Bool {
        connection.kind.isObjectStore && path.isRoot
    }

    public var title: String {
        path.isRoot ? connection.name : path.name
    }

    public var currentEndpoint: TransferEndpoint {
        TransferEndpoint(connection: connection, path: path)
    }

    public var isEmpty: Bool {
        visibleItems.isEmpty && !isLoading && error == nil
    }

    /// What the empty state should say — the reason matters more than the fact.
    public var emptyMessage: String {
        if !searchText.isEmpty { return "No matches for “\(searchText)”." }
        if isAtContainerRoot {
            return "No \(connection.kind.containerNoun.lowercased())s in this account."
        }
        return "This folder is empty."
    }

    // MARK: - Navigation

    public func navigate(to newPath: RemotePath, recordHistory: Bool = true) {
        guard newPath != path else { return }
        if recordHistory {
            backStack.append(Location(connectionID: connection.id, path: path))
            forwardStack.removeAll()
        }
        path = newPath
        selection.removeAll()
        searchText = ""
        load()
    }

    public func switchTo(connection newConnection: Connection, path newPath: RemotePath = .root) {
        if newConnection.id != connection.id || newPath != path {
            backStack.append(Location(connectionID: connection.id, path: path))
            forwardStack.removeAll()
        }
        connection = newConnection
        path = newPath
        selection.removeAll()
        searchText = ""
        load()
    }

    public func open(_ item: CloudItem) {
        guard item.isDirectory else { return }
        navigate(to: item.path)
    }

    public func goBack() {
        guard let previous = backStack.popLast() else { return }
        forwardStack.append(Location(connectionID: connection.id, path: path))
        apply(previous)
    }

    public func goForward() {
        guard let next = forwardStack.popLast() else { return }
        backStack.append(Location(connectionID: connection.id, path: path))
        apply(next)
    }

    public func goUp() {
        guard canGoUp else { return }
        navigate(to: path.parent)
    }

    private func apply(_ location: Location) {
        if let target = connections.connection(id: location.connectionID) {
            connection = target
        }
        path = location.path
        selection.removeAll()
        searchText = ""
        load()
    }

    // MARK: - Loading

    public func refresh() {
        load(force: true)
    }

    /// Loads the current directory.
    ///
    /// `force` skips the cache, which is what the Refresh button does; ordinary
    /// navigation shows the cache first and corrects it in place.
    public func load(force: Bool = false) {
        loadTask?.cancel()
        generation += 1
        let token = generation

        let connectionID = connection.id
        let targetPath = path
        cursor = nil
        hasMore = false
        error = nil
        loadedFromCache = false

        connections.markUsed(connectionID)
        onLocationChange?(connectionID, targetPath)

        loadTask = Task { [weak self] in
            guard let self else { return }

            // 1. Cached listing, if we have one, so the pane is never blank.
            if !force, settings.useCachedListings {
                if let entry = await ListingCache.shared.entry(
                    connection: connectionID, path: targetPath
                ) {
                    guard token == self.generation else { return }
                    self.items = entry.items
                    self.loadedFromCache = true
                    self.isRefreshing = true
                    self.applyFilters()
                }
            }

            if !self.loadedFromCache {
                self.isLoading = true
            }

            defer {
                if token == self.generation {
                    self.isLoading = false
                    self.isRefreshing = false
                }
            }

            // 2. First live page replaces whatever was shown.
            do {
                if self.connection.kind != .local {
                    self.connections.setStatus(.connecting, for: connectionID)
                }
                let provider = try await registry.validatedProvider(for: self.connection)
                guard token == self.generation else { return }
                self.connections.setStatus(.connected, for: connectionID)

                let page = try await provider.list(
                    targetPath, cursor: nil, pageSize: settings.pageSize
                )
                guard token == self.generation else { return }

                self.items = page.items
                self.cursor = page.nextCursor
                self.hasMore = page.nextCursor != nil
                self.isLoading = false
                self.isRefreshing = false
                self.loadedFromCache = false
                self.applyFilters()

                await ListingCache.shared.store(
                    connection: connectionID,
                    path: targetPath,
                    items: page.items,
                    isComplete: page.nextCursor == nil
                )

                // 3. Keep paging in the background, appending as pages land.
                while let next = self.cursor,
                      token == self.generation,
                      self.items.count < Self.autoPageLimit,
                      !Task.isCancelled {
                    let more = try await provider.list(
                        targetPath, cursor: next, pageSize: settings.pageSize
                    )
                    guard token == self.generation else { return }
                    self.items.append(contentsOf: more.items)
                    self.cursor = more.nextCursor
                    self.hasMore = more.nextCursor != nil
                    self.applyFilters()
                }

                if token == self.generation, !self.hasMore {
                    await ListingCache.shared.store(
                        connection: connectionID,
                        path: targetPath,
                        items: self.items,
                        isComplete: true
                    )
                }
            } catch is CancellationError {
                return
            } catch {
                guard token == self.generation else { return }
                let message = TransferManager.describe(error)
                // A cached listing is still useful; show the problem without
                // throwing away what's on screen.
                if self.items.isEmpty {
                    self.error = message
                }
                if self.connection.kind != .local {
                    self.connections.setStatus(.failed(message), for: connectionID)
                }
            }
        }
    }

    /// Fetches the next page on demand, past the auto-paging limit.
    public func loadMore() {
        guard let next = cursor, !isLoading else { return }
        let token = generation
        let targetPath = path
        Task { [weak self] in
            guard let self else { return }
            self.isLoading = true
            defer { if token == self.generation { self.isLoading = false } }
            do {
                let provider = try await registry.provider(for: self.connection)
                let page = try await provider.list(
                    targetPath, cursor: next, pageSize: settings.pageSize
                )
                guard token == self.generation else { return }
                self.items.append(contentsOf: page.items)
                self.cursor = page.nextCursor
                self.hasMore = page.nextCursor != nil
                self.applyFilters()
            } catch {
                guard token == self.generation else { return }
                self.error = TransferManager.describe(error)
            }
        }
    }

    /// Re-reads the current directory after a mutation, bypassing the cache.
    public func reloadAfterChange() {
        let connectionID = connection.id
        let targetPath = path
        Task {
            await ListingCache.shared.invalidate(connection: connectionID, path: targetPath)
            self.load(force: true)
        }
    }

    // MARK: - Filtering and sorting

    private func applyFilters() {
        var result = items

        if !searchText.isEmpty {
            // Case- and diacritic-insensitive substring match, which is what
            // people expect from a search box in a file list.
            let needle = searchText.folding(
                options: [.caseInsensitive, .diacriticInsensitive], locale: .current
            )
            result = result.filter {
                $0.name
                    .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                    .contains(needle)
            }
        }

        if !settings.showHiddenFiles {
            result = result.filter { !$0.name.hasPrefix(".") }
        }

        let ascending = sortAscending
        let foldersFirst = settings.foldersFirst
        let field = sortField

        result.sort { left, right in
            if foldersFirst, left.isDirectory != right.isDirectory {
                return left.isDirectory
            }
            let ordered: Bool
            switch field {
            case .name:
                ordered = left.name.localizedStandardCompare(right.name) == .orderedAscending
            case .size:
                // Folders have no size; keep them stable rather than random.
                let leftSize = left.size ?? -1
                let rightSize = right.size ?? -1
                ordered = leftSize == rightSize
                    ? left.name.localizedStandardCompare(right.name) == .orderedAscending
                    : leftSize < rightSize
            case .modified:
                let leftDate = left.modified ?? .distantPast
                let rightDate = right.modified ?? .distantPast
                ordered = leftDate == rightDate
                    ? left.name.localizedStandardCompare(right.name) == .orderedAscending
                    : leftDate < rightDate
            case .kind:
                let leftKind = left.fileExtension ?? ""
                let rightKind = right.fileExtension ?? ""
                ordered = leftKind == rightKind
                    ? left.name.localizedStandardCompare(right.name) == .orderedAscending
                    : leftKind < rightKind
            }
            return ascending ? ordered : !ordered
        }

        visibleItems = result

        // Drop selections that the new listing no longer contains.
        if !selection.isEmpty {
            let available = Set(result.map(\.id))
            selection = selection.intersection(available)
        }
    }

    /// Status line: "128 items, 2 selected".
    public var statusSummary: String {
        var parts: [String] = []
        let count = visibleItems.count
        parts.append(count == 1 ? "1 item" : "\(count) items")
        if hasMore { parts[0] += "+" }
        if selection.count == 1 {
            if let item = selectedItems.first {
                parts.append(item.isDirectory ? item.name : ByteFormat.bytes(item.size))
            }
        } else if selection.count > 1 {
            let total = selectedItems.compactMap(\.size).reduce(Int64(0), +)
            parts.append("\(selection.count) selected, \(ByteFormat.bytes(total))")
        }
        return parts.joined(separator: " · ")
    }
}
