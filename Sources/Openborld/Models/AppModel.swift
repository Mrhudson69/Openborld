import Foundation
import Observation
import AppKit
import OpenborldCore

/// Which sidebar section is driving the content area.
public enum SidebarSelection: Hashable {
    case location(connectionID: UUID, path: RemotePath)
    case transfers
    case history
}

/// Top-level app state: the stores, the two panes, and the file operations the
/// UI invokes. Views stay declarative; everything that mutates storage or
/// touches the network goes through here.
@MainActor
@Observable
public final class AppModel {
    public let settings: AppSettings
    public let connections: ConnectionStore
    public let places: PlacesStore
    public let transfers: TransferManager

    public var left: BrowserModel
    public var right: BrowserModel

    /// Dual-pane mode. Off by default: one pane is the simpler thing, and the
    /// second is a deliberate choice.
    public var isDualPane = false {
        didSet {
            if isDualPane, right.items.isEmpty { right.load() }
        }
    }

    /// Which pane keystrokes and the toolbar act on.
    public var activePane: Pane = .left
    public var showInspector = false
    public var sidebarSelection: SidebarSelection?

    /// A sheet or alert the content area needs to present.
    public var presentation: Presentation?
    public var banner: Banner?

    public enum Pane: String, Hashable, Sendable {
        case left
        case right
    }

    public enum Presentation: Identifiable {
        case addConnection
        case editConnection(Connection)
        case newFolder(Pane)
        case rename(Pane, CloudItem)
        case newContainer(Pane)
        case shareLink(name: String, url: URL, isConnectionToken: Bool)
        case metadata(connection: Connection, item: CloudItem)
        case confirmDelete(Pane, [CloudItem])
        case transferConflict(ConflictPrompt)

        public var id: String {
            switch self {
            case .addConnection: "addConnection"
            case .editConnection(let connection): "edit-\(connection.id)"
            case .newFolder(let pane): "newFolder-\(pane.rawValue)"
            case .rename(let pane, let item): "rename-\(pane.rawValue)-\(item.id)"
            case .newContainer(let pane): "newContainer-\(pane.rawValue)"
            case .shareLink(let name, _, _): "share-\(name)"
            case .metadata(_, let item): "metadata-\(item.id)"
            case .confirmDelete(let pane, let items): "delete-\(pane.rawValue)-\(items.count)"
            case .transferConflict: "conflict"
            }
        }
    }

    /// A pending cross-pane transfer waiting on a conflict decision.
    public struct ConflictPrompt {
        public var items: [CloudItem]
        public var source: TransferEndpoint
        public var destination: TransferEndpoint
        public var isMove: Bool
        public var conflictingNames: [String]
    }

    public struct Banner: Identifiable {
        public enum Level { case info, success, warning, error }
        public let id = UUID()
        public var message: String
        public var level: Level
        public var detail: String?
    }

    public init() {
        let settings = AppSettings()
        let connections = ConnectionStore()
        let places = PlacesStore()
        let transfers = TransferManager.shared

        self.settings = settings
        self.connections = connections
        self.places = places
        self.transfers = transfers

        transfers.maxConcurrent = settings.maxConcurrentTransfers
        transfers.conflictPolicy = settings.conflictPolicy

        // Open on the user's home folder rather than the filesystem root — the
        // root is reachable, but it isn't where anyone starts.
        let home = RemotePath(
            components: FileManager.default.homeDirectoryForCurrentUser.path
                .split(separator: "/").map(String.init)
        )
        self.left = BrowserModel(
            connection: connections.local, path: home,
            settings: settings, places: places, connections: connections
        )
        self.right = BrowserModel(
            connection: connections.connections.first ?? connections.local,
            path: connections.connections.isEmpty ? home : .root,
            settings: settings, places: places, connections: connections
        )

        // Only prune when the connection list is known-good: pruning against a
        // list that failed to load would delete the favourites and recents
        // pointing at the very connections we couldn't read.
        if connections.loadFailure == nil {
            places.prune(validConnectionIDs: Set(connections.all.map(\.id)))
        }
        sidebarSelection = .location(connectionID: connections.local.id, path: home)

        // Keep the sidebar highlight on the active pane's real location.
        left.onLocationChange = { [weak self] connectionID, path in
            self?.sidebarDidFollow(pane: .left, connectionID: connectionID, path: path)
        }
        right.onLocationChange = { [weak self] connectionID, path in
            self?.sidebarDidFollow(pane: .right, connectionID: connectionID, path: path)
        }
    }

    /// Mirrors a pane's location into the sidebar selection.
    ///
    /// Safe against a feedback loop: writing the same value fires no change,
    /// and `navigateFromSidebar` ignores a location a pane is already showing.
    private func sidebarDidFollow(pane: Pane, connectionID: UUID, path: RemotePath) {
        guard pane == activePane else { return }
        let location = SidebarSelection.location(connectionID: connectionID, path: path)
        guard sidebarSelection != location else { return }
        sidebarSelection = location
    }

    public func pane(_ which: Pane) -> BrowserModel {
        which == .left ? left : right
    }

    public var active: BrowserModel { pane(activePane) }

    public var inactive: BrowserModel { pane(activePane == .left ? .right : .left) }

    public func start() {
        // A failed read of the connections file must be visible. Silently
        // showing an empty sidebar is how the problem gets mistaken for
        // "my connections vanished" instead of "a file needs attention".
        if let failure = connections.loadFailure {
            show("Couldn't load your saved connections.", level: .error, detail: failure)
        }
        left.load()
        if isDualPane { right.load() }
    }

    // MARK: - Banners

    public func show(_ message: String, level: Banner.Level = .info, detail: String? = nil) {
        banner = Banner(message: message, level: level, detail: detail)
        let id = banner?.id
        Task {
            try? await Task.sleep(nanoseconds: level == .error ? 8_000_000_000 : 4_000_000_000)
            if banner?.id == id { banner = nil }
        }
    }

    private func report(_ error: Error, while action: String) {
        show("Couldn't \(action).", level: .error, detail: TransferManager.describe(error))
    }

    // MARK: - Navigation from the sidebar

    /// Performs the navigation a sidebar selection implies.
    ///
    /// The sidebar sets `sidebarSelection` and this reacts to it, so there is
    /// exactly one path from "a row was chosen" to "a pane moved" — setting the
    /// selection *and* navigating at each call site would do both twice.
    public func navigateFromSidebar(connectionID: UUID, path: RemotePath) {
        guard let connection = connections.connection(id: connectionID) else {
            show("That connection no longer exists.", level: .warning)
            return
        }
        let browser = active
        // A selection that matches where the pane already is came from the
        // pane itself reporting its location, not from a click — so it is
        // neither a navigation nor a visit.
        guard browser.connection.id != connectionID || browser.path != path else { return }
        browser.switchTo(connection: connection, path: path)

        // Recents records places you chose to go, not every folder you opened
        // on the way. Logging each navigation buries the useful entries.
        places.recordVisit(
            connectionID: connectionID,
            path: path,
            name: path.isRoot ? connection.name : path.name
        )
    }

    public func go(to place: Place) {
        guard connections.connection(id: place.connectionID) != nil else {
            show("That connection no longer exists.", level: .warning)
            return
        }
        sidebarSelection = .location(connectionID: place.connectionID, path: place.path)
    }

    public func go(to connection: Connection) {
        let target = SidebarSelection.location(connectionID: connection.id, path: .root)
        // Selecting what is already selected fires no change, so navigate here.
        if sidebarSelection == target {
            navigateFromSidebar(connectionID: connection.id, path: .root)
        } else {
            sidebarSelection = target
        }
    }

    // MARK: - Folder and container creation

    public func createFolder(in pane: Pane, named name: String) {
        let browser = self.pane(pane)
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard !trimmed.contains("/") else {
            show("A folder name can't contain a slash.", level: .warning)
            return
        }

        let connection = browser.connection
        let target = browser.path.appending(trimmed)
        Task {
            do {
                let provider = try await ProviderRegistry.shared.validatedProvider(for: connection)
                try await provider.createFolder(at: target)
                browser.reloadAfterChange()
                show("Created “\(trimmed)”.", level: .success)
            } catch {
                report(error, while: "create that folder")
            }
        }
    }

    public func createContainer(in pane: Pane, named name: String) {
        let browser = self.pane(pane)
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let connection = browser.connection
        let noun = connection.kind.containerNoun.lowercased()
        Task {
            do {
                let provider = try await ProviderRegistry.shared.validatedProvider(for: connection)
                try await provider.createContainer(named: trimmed)
                browser.reloadAfterChange()
                show("Created \(noun) “\(trimmed)”.", level: .success)
            } catch {
                report(error, while: "create that \(noun)")
            }
        }
    }

    // MARK: - Rename

    public func rename(_ item: CloudItem, in pane: Pane, to newName: String) {
        let browser = self.pane(pane)
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != item.name else { return }
        guard !trimmed.contains("/") else {
            show("A name can't contain a slash.", level: .warning)
            return
        }

        let connection = browser.connection
        let destination = item.path.parent.appending(trimmed)
        Task {
            do {
                let provider = try await ProviderRegistry.shared.validatedProvider(for: connection)
                if item.isDirectory, connection.kind.isObjectStore {
                    // No directories to rename in an object store: every key
                    // under the old prefix has to be copied across.
                    try await renamePrefix(
                        provider: provider,
                        from: item.path,
                        to: destination,
                        connection: connection
                    )
                } else {
                    try await provider.move(item, to: destination)
                }
                await ListingCache.shared.invalidateSubtree(
                    connection: connection.id, path: item.path
                )
                browser.reloadAfterChange()
                show("Renamed to “\(trimmed)”.", level: .success)
            } catch {
                report(error, while: "rename that item")
            }
        }
    }

    /// Moves every object under one prefix to another, server-side.
    private func renamePrefix(
        provider: any StorageProvider,
        from source: RemotePath,
        to destination: RemotePath,
        connection: Connection
    ) async throws {
        var moved = 0
        for try await file in provider.walkFiles(from: source) {
            guard let relative = source.relative(file.path) else { continue }
            try await provider.move(file, to: destination.appending(path: relative))
            moved += 1
        }
        if moved == 0 {
            // An empty folder is only a marker object; recreate it and drop the old.
            try await provider.createFolder(at: destination)
            try? await provider.delete(
                CloudItem(name: source.name, path: source, kind: .folder)
            )
        }
    }

    // MARK: - Delete

    public func requestDelete(in pane: Pane) {
        let browser = self.pane(pane)
        let items = browser.selectedItems
        guard !items.isEmpty else { return }
        if settings.confirmDeletes {
            presentation = .confirmDelete(pane, items)
        } else {
            performDelete(items, in: pane)
        }
    }

    public func performDelete(_ items: [CloudItem], in pane: Pane) {
        let browser = self.pane(pane)
        let connection = browser.connection
        Task {
            var failures: [String] = []
            do {
                let provider = try await ProviderRegistry.shared.validatedProvider(for: connection)
                for item in items {
                    do {
                        if item.isDirectory {
                            try await provider.deleteRecursively(item)
                        } else {
                            try await provider.delete(item)
                        }
                        await ListingCache.shared.invalidateSubtree(
                            connection: connection.id, path: item.path
                        )
                    } catch {
                        failures.append("\(item.name): \(TransferManager.describe(error))")
                    }
                }
            } catch {
                report(error, while: "reach that connection")
                return
            }
            browser.reloadAfterChange()
            if failures.isEmpty {
                let noun = items.count == 1 ? "“\(items[0].name)”" : "\(items.count) items"
                show("Deleted \(noun).", level: .success)
            } else {
                show(
                    "Deleted \(items.count - failures.count) of \(items.count).",
                    level: .warning,
                    detail: failures.joined(separator: "\n")
                )
            }
        }
    }

    // MARK: - Transfers

    /// Copies or moves the pane's selection into the other pane's folder.
    public func transferSelection(from pane: Pane, isMove: Bool) {
        let source = self.pane(pane)
        let destination = self.pane(pane == .left ? .right : .left)
        let items = source.selectedItems
        guard !items.isEmpty else { return }
        enqueue(
            items,
            from: source.currentEndpoint,
            to: destination.currentEndpoint,
            isMove: isMove
        )
    }

    public func enqueue(
        _ items: [CloudItem],
        from source: TransferEndpoint,
        to destination: TransferEndpoint,
        isMove: Bool
    ) {
        guard !items.isEmpty else { return }
        if source.connection.id == destination.connection.id,
           source.path == destination.path {
            show("The source and destination are the same folder.", level: .warning)
            return
        }

        transfers.conflictPolicy = settings.conflictPolicy

        // With "Ask Me", find the collisions up front and get one decision for
        // the batch rather than interrupting mid-transfer.
        if settings.conflictPolicy == .ask {
            Task {
                let clashes = await conflictingNames(items, at: destination)
                if clashes.isEmpty {
                    dispatch(items, from: source, to: destination, isMove: isMove, policy: .overwrite)
                } else {
                    presentation = .transferConflict(ConflictPrompt(
                        items: items,
                        source: source,
                        destination: destination,
                        isMove: isMove,
                        conflictingNames: clashes
                    ))
                }
            }
            return
        }

        dispatch(items, from: source, to: destination, isMove: isMove, policy: settings.conflictPolicy)
    }

    public func resolveConflict(_ prompt: ConflictPrompt, with policy: ConflictPolicy) {
        dispatch(
            prompt.items,
            from: prompt.source,
            to: prompt.destination,
            isMove: prompt.isMove,
            policy: policy
        )
    }

    private func dispatch(
        _ items: [CloudItem],
        from source: TransferEndpoint,
        to destination: TransferEndpoint,
        isMove: Bool,
        policy: ConflictPolicy
    ) {
        transfers.conflictPolicy = policy == .ask ? .overwrite : policy
        for item in items {
            if item.isDirectory {
                transfers.enqueueDirectory(
                    item: item, from: source, to: destination, isMove: isMove
                )
            } else {
                transfers.enqueue(
                    item: item, from: source, to: destination, isMove: isMove
                )
            }
        }
        let verb = isMove ? "Moving" : "Copying"
        let noun = items.count == 1 ? "“\(items[0].name)”" : "\(items.count) items"
        show("\(verb) \(noun) to \(destination.label).", level: .info)

        // A move empties the source folder, so it needs re-reading too.
        if isMove {
            let browser = self.pane(activePane)
            if browser.connection.id == source.connection.id {
                Task {
                    try? await Task.sleep(nanoseconds: 1_200_000_000)
                    browser.reloadAfterChange()
                }
            }
        }
    }

    private func conflictingNames(
        _ items: [CloudItem],
        at destination: TransferEndpoint
    ) async -> [String] {
        guard let provider = try? await ProviderRegistry.shared
            .validatedProvider(for: destination.connection)
        else { return [] }
        var clashes: [String] = []
        for item in items {
            let target = destination.path.appending(item.name)
            if (try? await provider.stat(target)) != nil { clashes.append(item.name) }
        }
        return clashes
    }

    /// Downloads the selection to the configured download folder.
    public func downloadSelection(from pane: Pane) {
        let browser = self.pane(pane)
        let items = browser.selectedItems
        guard !items.isEmpty else { return }
        guard browser.connection.kind != .local else {
            show("Those files are already on this Mac.", level: .info)
            return
        }

        let folder = settings.downloadFolder
        let localPath = RemotePath(
            components: folder.path.split(separator: "/").map(String.init)
        )
        enqueue(
            items,
            from: browser.currentEndpoint,
            to: TransferEndpoint(connection: connections.local, path: localPath),
            isMove: false
        )
    }

    /// Uploads files chosen in an open panel into the pane's folder.
    public func chooseFilesToUpload(into pane: Pane) {
        let browser = self.pane(pane)
        guard !browser.isAtContainerRoot else {
            show(
                "Pick a \(browser.connection.kind.containerNoun.lowercased()) first.",
                level: .warning
            )
            return
        }

        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.message = "Choose files to upload to \(browser.title)"
        panel.prompt = "Upload"

        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        upload(urls: panel.urls, into: pane)
    }

    /// Uploads local URLs — from the open panel, or dropped from Finder.
    public func upload(urls: [URL], into pane: Pane) {
        let browser = self.pane(pane)
        guard !urls.isEmpty else { return }
        guard browser.connection.kind != .local || browser.path != RemotePath(
            components: urls[0].deletingLastPathComponent().path
                .split(separator: "/").map(String.init)
        ) else {
            show("Those files are already in this folder.", level: .info)
            return
        }

        var items: [CloudItem] = []
        var groups: [RemotePath: [CloudItem]] = [:]
        for url in urls {
            let components = url.standardizedFileURL.path
                .split(separator: "/").map(String.init)
            let path = RemotePath(components: components)
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?
                .isDirectory ?? false
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
            let item = CloudItem(
                name: url.lastPathComponent,
                path: path,
                kind: isDirectory ? .folder : .file,
                size: size.map(Int64.init)
            )
            items.append(item)
            groups[path.parent, default: []].append(item)
        }

        // Each source folder is its own endpoint, since the local provider is
        // rooted at `/` and the transfer needs the parent path.
        for (parent, group) in groups {
            enqueue(
                group,
                from: TransferEndpoint(connection: connections.local, path: parent),
                to: browser.currentEndpoint,
                isMove: false
            )
        }
    }

    // MARK: - Drag and drop

    /// Items currently being dragged inside the app. The drag itself carries
    /// only a token, so there's no pasteboard type to register and no risk of a
    /// stale serialised path being acted on.
    private var dragPayload: (token: UUID, items: [CloudItem], source: TransferEndpoint)?

    public func beginDrag(items: [CloudItem], from pane: Pane) -> DragToken {
        let token = UUID()
        dragPayload = (token, items, self.pane(pane).currentEndpoint)
        return DragToken(id: token)
    }

    /// Handles a drop of in-app items into a folder. Returns false when the
    /// drop is a no-op, so the drag animates back instead of pretending.
    public func handleDrop(token: DragToken, into folder: RemotePath, pane: Pane) -> Bool {
        guard let payload = dragPayload, payload.token == token.id else { return false }
        dragPayload = nil

        let destination = TransferEndpoint(
            connection: self.pane(pane).connection,
            path: folder
        )

        // Dropping something into the folder it already lives in, or into
        // itself, isn't a transfer.
        if payload.source.connection.id == destination.connection.id {
            if payload.source.path == destination.path { return false }
            if payload.items.contains(where: {
                $0.isDirectory && ($0.path == folder || $0.path.isAncestor(of: folder))
            }) {
                show("A folder can't be moved into itself.", level: .warning)
                return false
            }
        }

        // Same connection drags move; across connections they copy. That's the
        // Finder convention and it's the safer default for a cloud account.
        let isMove = payload.source.connection.id == destination.connection.id
        enqueue(payload.items, from: payload.source, to: destination, isMove: isMove)
        return true
    }

    /// Drop onto a pane's background — targets the folder being viewed.
    public func handleDropOnPane(token: DragToken, pane: Pane) -> Bool {
        handleDrop(token: token, into: self.pane(pane).path, pane: pane)
    }

    // MARK: - Open, reveal, share

    /// Opens a file: directly for local, after staging a copy for remote.
    public func open(_ item: CloudItem, in pane: Pane) {
        let browser = self.pane(pane)
        guard !item.isDirectory else {
            browser.open(item)
            return
        }

        if browser.connection.kind == .local {
            let provider = LocalProvider(connection: browser.connection)
            NSWorkspace.shared.open(provider.url(for: item.path))
            return
        }

        let connection = browser.connection
        Task {
            do {
                let provider = try await ProviderRegistry.shared.validatedProvider(for: connection)
                let staged = AppPaths.scratch
                    .appendingPathComponent(UUID().uuidString, isDirectory: true)
                    .appendingPathComponent(item.name)
                try FileManager.default.createDirectory(
                    at: staged.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                show("Opening “\(item.name)”…", level: .info)
                try await provider.download(item, to: staged, progress: nil)
                NSWorkspace.shared.open(staged)
            } catch {
                report(error, while: "open that file")
            }
        }
    }

    public func revealInFinder(_ item: CloudItem, in pane: Pane) {
        let browser = self.pane(pane)
        guard browser.connection.kind == .local else { return }
        let provider = LocalProvider(connection: browser.connection)
        NSWorkspace.shared.activateFileViewerSelecting([provider.url(for: item.path)])
    }

    public func copyPath(_ item: CloudItem, in pane: Pane) {
        let browser = self.pane(pane)
        let text: String
        if browser.connection.kind == .local {
            text = LocalProvider(connection: browser.connection).url(for: item.path).path
        } else {
            text = "\(browser.connection.name):/\(item.path.joined)"
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        show("Path copied.", level: .success)
    }

    public func shareLink(for item: CloudItem, in pane: Pane) {
        let browser = self.pane(pane)
        let connection = browser.connection
        guard connection.kind != .local else {
            copyPath(item, in: pane)
            return
        }
        Task {
            do {
                let provider = try await ProviderRegistry.shared.validatedProvider(for: connection)
                guard provider.capabilities.contains(.signedURL) else {
                    throw StorageError.unsupported(
                        "\(connection.kind.displayName) can't generate a shareable link with these credentials."
                    )
                }
                let url = try await provider.signedURL(for: item, expiresIn: 24 * 3600)
                // A SAS-authenticated connection can only hand back its own
                // token, which may grant more than read on more than this blob.
                let isConnectionToken = connection.kind == .azureBlob
                    && AzureAuthMethod(rawValue: connection.setting(.authMethod)) != .accountKey
                presentation = .shareLink(
                    name: item.name, url: url, isConnectionToken: isConnectionToken
                )
            } catch {
                report(error, while: "create a link")
            }
        }
    }

    public func showMetadata(for item: CloudItem, in pane: Pane) {
        presentation = .metadata(connection: self.pane(pane).connection, item: item)
    }

    // MARK: - Lifecycle

    public func willQuit() {
        connections.persist()
        places.persist()
        settings.persist()
    }
}
