import Foundation

public enum AppPaths {
    public static let bundleIdentifier = "dev.openborld.app"

    /// Settings and connections.
    ///
    /// Each platform has its own convention and ignoring them puts dotfiles in
    /// people's home directories: `~/Library/Application Support` on macOS,
    /// `$XDG_CONFIG_HOME` on Linux, `%APPDATA%` on Windows.
    public static let support: URL = {
        let directory = platformDirectory(
            appleSearchPath: .applicationSupportDirectory,
            xdgVariable: "XDG_CONFIG_HOME",
            xdgFallback: ".config",
            windowsVariable: "APPDATA"
        )
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }()

    /// `~/Library/Caches/Openborld` — safe to delete; holds the listing cache and
    /// thumbnails, which is why it lives outside Application Support.
    public static let cache: URL = {
        let directory = platformDirectory(
            appleSearchPath: .cachesDirectory,
            xdgVariable: "XDG_CACHE_HOME",
            xdgFallback: ".cache",
            windowsVariable: "LOCALAPPDATA"
        )
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }()

    private static func platformDirectory(
        appleSearchPath: FileManager.SearchPathDirectory,
        xdgVariable: String,
        xdgFallback: String,
        windowsVariable: String
    ) -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let environment = ProcessInfo.processInfo.environment

        #if os(macOS) || os(iOS)
        let base = FileManager.default
            .urls(for: appleSearchPath, in: .userDomainMask).first
            ?? home.appendingPathComponent("Library/Application Support")
        #elseif os(Windows)
        let base = environment[windowsVariable].map { URL(fileURLWithPath: $0) }
            ?? home.appendingPathComponent("AppData/Roaming")
        #else
        let base = environment[xdgVariable].map { URL(fileURLWithPath: $0) }
            ?? home.appendingPathComponent(xdgFallback)
        #endif

        return base.appendingPathComponent("Openborld", isDirectory: true)
    }

    public static var connectionsFile: URL { support.appendingPathComponent("connections.json") }
    public static var settingsFile: URL { support.appendingPathComponent("settings.json") }
    public static var placesFile: URL { support.appendingPathComponent("places.json") }
    public static var historyFile: URL { support.appendingPathComponent("history.json") }
    public static var listingCacheFile: URL { cache.appendingPathComponent("listings.sqlite") }

    /// Where remote files are staged when opened or previewed.
    public static let scratch: URL = {
        let directory = cache.appendingPathComponent("scratch", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }()

    public static var defaultDownloads: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        #if os(macOS) || os(iOS)
        return FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? home.appendingPathComponent("Downloads")
        #else
        if let xdg = ProcessInfo.processInfo.environment["XDG_DOWNLOAD_DIR"] {
            return URL(fileURLWithPath: xdg)
        }
        return home.appendingPathComponent("Downloads")
        #endif
    }
}

/// Atomic reads and writes for the small JSON files above.
public enum JSONFile {
    /// Why a read produced no value.
    ///
    /// The distinction matters more than it looks: "the file isn't there" is
    /// normal on first run, while "the file is there but won't parse" means
    /// real data is at risk. Collapsing both into `nil` is what let an
    /// unreadable connections file be silently replaced with an empty one.
    public enum ReadOutcome<T> {
        case missing
        case decoded(T)
        case corrupt(underlying: Error, backup: URL?)

        public var value: T? {
            if case .decoded(let value) = self { return value }
            return nil
        }
    }

    public static func load<T: Decodable>(_ type: T.Type, from url: URL) -> ReadOutcome<T> {
        guard FileManager.default.fileExists(atPath: url.path) else { return .missing }
        do {
            let data = try Data(contentsOf: url)
            if data.isEmpty { return .missing }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return .decoded(try decoder.decode(type, from: data))
        } catch {
            // Preserve the unreadable file rather than letting the next write
            // erase it; a human can still recover the contents by hand.
            let backup = url.deletingPathExtension().appendingPathExtension(
                "corrupt-\(Int(Date().timeIntervalSince1970)).json"
            )
            try? FileManager.default.copyItem(at: url, to: backup)
            return .corrupt(underlying: error, backup: backup)
        }
    }

    /// Convenience for files where losing the contents is merely annoying.
    public static func read<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        load(type, from: url).value
    }

    public static func write<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(value)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        // Atomic: a crash mid-write can't leave a truncated settings file.
        try data.write(to: url, options: .atomic)
    }
}
