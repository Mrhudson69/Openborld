import Foundation

/// Remembers directory listings so a revisited folder paints immediately while
/// a fresh listing loads behind it.
///
/// Two tiers: a small in-memory map for the folders just visited, and SQLite
/// for everything else so the benefit survives a relaunch. Entries are only
/// ever a display shortcut — every hit is still followed by a real request, so a
/// stale entry costs a brief flicker of old data, never a wrong operation.
public actor ListingCache {
    public static let shared = ListingCache()

    public struct Entry: Sendable {
        public var items: [CloudItem]
        public var storedAt: Date
        /// False when the directory had more pages than we cached.
        public var isComplete: Bool

        public var age: TimeInterval { Date().timeIntervalSince(storedAt) }
    }

    /// Cap per directory: enough that the first few screens are instant, small
    /// enough that a million-object prefix doesn't bloat the cache file.
    private static let maxItemsPerDirectory = 5_000
    private static let memoryCapacity = 64
    /// Beyond this, a cached listing isn't shown at all — better a brief spinner
    /// than minutes-old contents.
    private static let maxDisplayAge: TimeInterval = 7 * 24 * 3600

    private var database: SQLiteDatabase?
    private var memory: [String: Entry] = [:]
    private var recency: [String] = []
    private var didPrepare = false

    public init() {}

    // MARK: - Reads

    /// Cached listing for a directory, or nil when there's nothing usable.
    public func entry(connection: UUID, path: RemotePath) -> Entry? {
        let key = Self.key(connection: connection, path: path)

        if let hit = memory[key] {
            touch(key)
            return hit
        }

        prepareIfNeeded()
        guard let database else { return nil }
        do {
            let statement = try database.prepare(
                "SELECT items, stored_at, complete FROM listings WHERE key = ?1 LIMIT 1"
            )
            statement.bind(1, key)
            guard statement.step(), let blob = statement.blob(0) else { return nil }

            let storedAt = Date(timeIntervalSince1970: Double(statement.int64(1)))
            guard Date().timeIntervalSince(storedAt) < Self.maxDisplayAge else { return nil }

            let items = try JSONDecoder().decode([CloudItem].self, from: blob)
            let entry = Entry(items: items, storedAt: storedAt, isComplete: statement.int64(2) == 1)
            remember(key, entry)
            return entry
        } catch {
            return nil
        }
    }

    // MARK: - Writes

    public func store(
        connection: UUID,
        path: RemotePath,
        items: [CloudItem],
        isComplete: Bool
    ) {
        let key = Self.key(connection: connection, path: path)
        let capped = items.count > Self.maxItemsPerDirectory
            ? Array(items.prefix(Self.maxItemsPerDirectory))
            : items
        let entry = Entry(
            items: capped,
            storedAt: Date(),
            isComplete: isComplete && capped.count == items.count
        )
        remember(key, entry)

        prepareIfNeeded()
        guard let database else { return }
        do {
            let blob = try JSONEncoder().encode(capped)
            let statement = try database.prepare("""
                INSERT INTO listings (key, connection, path, items, stored_at, complete)
                VALUES (?1, ?2, ?3, ?4, ?5, ?6)
                ON CONFLICT(key) DO UPDATE SET
                    items = excluded.items,
                    stored_at = excluded.stored_at,
                    complete = excluded.complete
                """)
            statement.bind(1, key)
            statement.bind(2, connection.uuidString)
            statement.bind(3, path.joined)
            statement.bind(4, blob)
            statement.bind(5, Int64(entry.storedAt.timeIntervalSince1970))
            statement.bind(6, Int64(entry.isComplete ? 1 : 0))
            try statement.run()
        } catch {
            // A cache that can't write is a performance loss, not a failure.
        }
    }

    /// Drops one directory — after a create, delete, rename, or upload there.
    public func invalidate(connection: UUID, path: RemotePath) {
        let key = Self.key(connection: connection, path: path)
        memory.removeValue(forKey: key)
        recency.removeAll { $0 == key }

        prepareIfNeeded()
        guard let database else { return }
        if let statement = try? database.prepare("DELETE FROM listings WHERE key = ?1") {
            statement.bind(1, key)
            try? statement.run()
        }
    }

    /// Drops a directory and everything beneath it — after a recursive delete
    /// or a move of a whole folder.
    public func invalidateSubtree(connection: UUID, path: RemotePath) {
        let prefix = path.joined
        memory = memory.filter { entryKey, _ in
            !entryKey.hasPrefix("\(connection.uuidString):\(prefix)")
        }
        recency = recency.filter { memory[$0] != nil }

        prepareIfNeeded()
        guard let database else { return }
        if let statement = try? database.prepare(
            "DELETE FROM listings WHERE connection = ?1 AND (path = ?2 OR path LIKE ?3)"
        ) {
            statement.bind(1, connection.uuidString)
            statement.bind(2, prefix)
            statement.bind(3, prefix.isEmpty ? "%" : prefix + "/%")
            try? statement.run()
        }
    }

    public func clear(connection: UUID) {
        memory = memory.filter { !$0.key.hasPrefix(connection.uuidString + ":") }
        recency = recency.filter { memory[$0] != nil }

        prepareIfNeeded()
        guard let database else { return }
        if let statement = try? database.prepare("DELETE FROM listings WHERE connection = ?1") {
            statement.bind(1, connection.uuidString)
            try? statement.run()
        }
    }

    public func clearAll() {
        memory.removeAll()
        recency.removeAll()
        prepareIfNeeded()
        try? database?.execute("DELETE FROM listings")
    }

    /// Current on-disk size, for the Settings pane.
    public func diskSize() -> Int64 {
        let attributes = try? FileManager.default.attributesOfItem(
            atPath: AppPaths.listingCacheFile.path
        )
        return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
    }

    // MARK: - Internals

    private func remember(_ key: String, _ entry: Entry) {
        memory[key] = entry
        touch(key)
        while recency.count > Self.memoryCapacity {
            let evicted = recency.removeFirst()
            memory.removeValue(forKey: evicted)
        }
    }

    private func touch(_ key: String) {
        recency.removeAll { $0 == key }
        recency.append(key)
    }

    private static func key(connection: UUID, path: RemotePath) -> String {
        "\(connection.uuidString):\(path.joined)"
    }

    private func prepareIfNeeded() {
        guard !didPrepare else { return }
        didPrepare = true
        do {
            let database = try SQLiteDatabase(path: AppPaths.listingCacheFile)
            try database.execute("""
                CREATE TABLE IF NOT EXISTS listings (
                    key TEXT PRIMARY KEY,
                    connection TEXT NOT NULL,
                    path TEXT NOT NULL,
                    items BLOB NOT NULL,
                    stored_at INTEGER NOT NULL,
                    complete INTEGER NOT NULL DEFAULT 0
                )
                """)
            try database.execute(
                "CREATE INDEX IF NOT EXISTS listings_connection ON listings (connection)"
            )
            // Keep the cache bounded without a background sweep.
            try database.execute("""
                DELETE FROM listings
                WHERE stored_at < \(Int64(Date().addingTimeInterval(-Self.maxDisplayAge).timeIntervalSince1970))
                """)
            self.database = database
        } catch {
            self.database = nil
        }
    }
}
