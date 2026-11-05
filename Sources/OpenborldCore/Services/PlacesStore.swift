import Foundation
import Observation

/// A saved location: a favourite, a bookmark, or somewhere recently visited.
public struct Place: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var connectionID: UUID
    public var path: RemotePath
    public var name: String
    public var visitedAt: Date

    public init(
        id: UUID = UUID(),
        connectionID: UUID,
        path: RemotePath,
        name: String,
        visitedAt: Date = Date()
    ) {
        self.id = id
        self.connectionID = connectionID
        self.path = path
        self.name = name
        self.visitedAt = visitedAt
    }

    /// Identity by location rather than by `id`, so the same folder isn't
    /// favourited twice.
    public var locationKey: String {
        "\(connectionID.uuidString):\(path.joined)"
    }
}

@MainActor
@Observable
public final class PlacesStore {
    public private(set) var favorites: [Place] = []
    public private(set) var bookmarks: [Place] = []
    public private(set) var recents: [Place] = []

    private static let recentsLimit = 20

    private struct Storage: Codable {
        var favorites: [Place] = []
        var bookmarks: [Place] = []
        var recents: [Place] = []
    }

    public init() {
        let stored = JSONFile.read(Storage.self, from: AppPaths.placesFile) ?? Storage()
        favorites = stored.favorites
        bookmarks = stored.bookmarks
        recents = stored.recents

        if favorites.isEmpty {
            favorites = Self.defaultFavorites()
            persist()
        }
    }

    /// Home, Desktop, Documents, Downloads — the folders a file manager should
    /// start you near rather than making you walk to from `/`.
    private static func defaultFavorites() -> [Place] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let components = home.split(separator: "/").map(String.init)
        let local = LocalProvider.macConnectionID
        var places: [Place] = [
            Place(connectionID: local, path: RemotePath(components: components), name: "Home")
        ]
        for folder in ["Desktop", "Documents", "Downloads"] {
            places.append(Place(
                connectionID: local,
                path: RemotePath(components: components + [folder]),
                name: folder
            ))
        }
        return places
    }

    // MARK: - Favorites

    public func isFavorite(connectionID: UUID, path: RemotePath) -> Bool {
        let key = "\(connectionID.uuidString):\(path.joined)"
        return favorites.contains { $0.locationKey == key }
    }

    public func toggleFavorite(connectionID: UUID, path: RemotePath, name: String) {
        let key = "\(connectionID.uuidString):\(path.joined)"
        if let index = favorites.firstIndex(where: { $0.locationKey == key }) {
            favorites.remove(at: index)
        } else {
            favorites.append(Place(connectionID: connectionID, path: path, name: name))
        }
        persist()
    }

    public func removeFavorite(_ id: UUID) {
        favorites.removeAll { $0.id == id }
        persist()
    }

    /// Reorders favourites by drag. `move(fromOffsets:toOffset:)` lives in
    /// SwiftUI, which this layer deliberately doesn't import.
    public func moveFavorite(from source: IndexSet, to destination: Int) {
        let moving = source.sorted().compactMap { favorites.indices.contains($0) ? favorites[$0] : nil }
        guard !moving.isEmpty else { return }
        // Count how many removals happen before the insertion point, since
        // removing them shifts that index left.
        let shift = source.filter { $0 < destination }.count
        for index in source.sorted(by: >) where favorites.indices.contains(index) {
            favorites.remove(at: index)
        }
        let insertAt = min(max(0, destination - shift), favorites.count)
        favorites.insert(contentsOf: moving, at: insertAt)
        persist()
    }

    // MARK: - Bookmarks

    public func addBookmark(connectionID: UUID, path: RemotePath, name: String) {
        let key = "\(connectionID.uuidString):\(path.joined)"
        guard !bookmarks.contains(where: { $0.locationKey == key }) else { return }
        bookmarks.append(Place(connectionID: connectionID, path: path, name: name))
        persist()
    }

    public func removeBookmark(_ id: UUID) {
        bookmarks.removeAll { $0.id == id }
        persist()
    }

    public func renameBookmark(_ id: UUID, to name: String) {
        guard let index = bookmarks.firstIndex(where: { $0.id == id }) else { return }
        bookmarks[index].name = name
        persist()
    }

    // MARK: - Recents

    public func recordVisit(connectionID: UUID, path: RemotePath, name: String) {
        let key = "\(connectionID.uuidString):\(path.joined)"
        recents.removeAll { $0.locationKey == key }
        recents.insert(
            Place(connectionID: connectionID, path: path, name: name),
            at: 0
        )
        if recents.count > Self.recentsLimit {
            recents.removeLast(recents.count - Self.recentsLimit)
        }
        persistSoon()
    }

    public func clearRecents() {
        recents.removeAll()
        persist()
    }

    /// Drops anything pointing at a connection that no longer exists.
    public func prune(validConnectionIDs: Set<UUID>) {
        let before = favorites.count + bookmarks.count + recents.count
        favorites.removeAll { !validConnectionIDs.contains($0.connectionID) }
        bookmarks.removeAll { !validConnectionIDs.contains($0.connectionID) }
        recents.removeAll { !validConnectionIDs.contains($0.connectionID) }
        if favorites.count + bookmarks.count + recents.count != before { persist() }
    }

    // MARK: - Persistence

    private var pendingSave: Task<Void, Never>?

    /// Recents change on every navigation; coalesce the writes.
    private func persistSoon() {
        pendingSave?.cancel()
        pendingSave = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            self?.persist()
        }
    }

    public func persist() {
        let storage = Storage(favorites: favorites, bookmarks: bookmarks, recents: recents)
        Task.detached(priority: .utility) {
            try? JSONFile.write(storage, to: AppPaths.placesFile)
        }
    }
}
