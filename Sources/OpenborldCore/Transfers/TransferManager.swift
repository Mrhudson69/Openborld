import Foundation
import Observation

#if canImport(FoundationNetworking)
// On Linux and Windows, Foundation is split and the URL loading system lives
// in its own module.
import FoundationNetworking
#endif

/// Runs every upload, download, and cross-provider copy.
///
/// Lives on the main actor so the UI can read it without synchronisation, but
/// does no work there: each transfer runs in its own task, and progress is
/// throttled before it reaches the main actor so a fast transfer can't flood
/// SwiftUI with updates.
@MainActor
@Observable
public final class TransferManager {
    public static let shared = TransferManager()

    /// Live transfers, newest last. Finished ones stay until cleared so the
    /// user can see what happened.
    public private(set) var transfers: [Transfer] = []
    public private(set) var history: [TransferRecord] = []

    /// How many transfers run at once. More isn't always faster — past a point
    /// they just compete for the same bandwidth — so this is user-tunable.
    ///
    /// Backed by private storage rather than clamped in a `didSet`: under
    /// `@Observable`, writing the property from inside its own `didSet` re-enters
    /// the generated setter and recurses until the stack is gone.
    private var concurrencyLimit = 4

    public var maxConcurrent: Int {
        get { concurrencyLimit }
        set {
            let clamped = max(1, min(newValue, 32))
            guard clamped != concurrencyLimit else { return }
            let grew = clamped > concurrencyLimit
            concurrencyLimit = clamped
            if grew { pump() }
        }
    }

    public var conflictPolicy: ConflictPolicy = .rename

    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var running = 0
    private var indexByID: [UUID: Int] = [:]
    private let registry = ProviderRegistry.shared

    /// Last progress sample per transfer, for smoothing the rate.
    private var samples: [UUID: (time: Date, bytes: Int64, speed: Double)] = [:]

    private static let historyLimit = 500

    public init() {
        history = JSONFile.read([TransferRecord].self, from: AppPaths.historyFile) ?? []
    }

    // MARK: - Aggregates for the UI

    public var activeCount: Int {
        transfers.filter { $0.status == .running || $0.status == .queued }.count
    }

    public var failedCount: Int {
        transfers.filter { $0.status == .failed }.count
    }

    public var hasActivity: Bool { activeCount > 0 }

    /// Combined throughput, for the toolbar badge.
    public var totalSpeed: Double {
        transfers.filter { $0.status == .running }.reduce(0) { $0 + $1.speed }
    }

    /// Overall progress across everything still in flight.
    public var overallFraction: Double {
        let active = transfers.filter { $0.status.isActive }
        guard !active.isEmpty else { return 0 }
        let known = active.filter { ($0.size ?? 0) > 0 }
        guard !known.isEmpty else { return 0 }
        let total = known.reduce(Int64(0)) { $0 + ($1.size ?? 0) }
        let done = known.reduce(Int64(0)) { $0 + $1.transferred }
        guard total > 0 else { return 0 }
        return Double(done) / Double(total)
    }

    // MARK: - Enqueueing

    /// Queues a single file. Returns the transfer's id so a caller can follow it.
    @discardableResult
    public func enqueue(
        item: CloudItem,
        from source: TransferEndpoint,
        to destinationDirectory: TransferEndpoint,
        isMove: Bool = false,
        groupName: String? = nil
    ) -> UUID {
        let destinationPath = destinationDirectory.path.appending(item.name)
        let kind = Self.kind(
            source: source.connection,
            destination: destinationDirectory.connection,
            isMove: isMove
        )
        var transfer = Transfer(
            name: item.name,
            kind: kind,
            source: TransferEndpoint(connection: source.connection, path: item.path),
            destination: TransferEndpoint(
                connection: destinationDirectory.connection,
                path: destinationPath
            ),
            groupName: groupName,
            size: item.size,
            isMove: isMove
        )
        transfer.status = .queued
        append(transfer)
        pump()
        return transfer.id
    }

    /// Queues a folder by walking it and adding one transfer per file.
    ///
    /// The walk runs in the background and transfers start as soon as the first
    /// files are known, so a deep folder doesn't stall behind enumeration.
    public func enqueueDirectory(
        item: CloudItem,
        from source: TransferEndpoint,
        to destinationDirectory: TransferEndpoint,
        isMove: Bool = false
    ) {
        let group = item.name
        Task { [weak self] in
            guard let self else { return }
            do {
                let provider = try await registry.validatedProvider(for: source.connection)
                let rootPath = item.path
                let destinationRoot = destinationDirectory.path.appending(item.name)

                for try await file in provider.walkFiles(from: rootPath) {
                    guard let relative = rootPath.relative(file.path) else { continue }
                    let target = destinationRoot.appending(path: relative.parent)
                    self.enqueueOne(
                        item: file,
                        from: TransferEndpoint(connection: source.connection, path: file.path),
                        to: TransferEndpoint(
                            connection: destinationDirectory.connection,
                            path: target
                        ),
                        isMove: isMove,
                        groupName: group
                    )
                }

                if isMove {
                    // The source folder is only removed once every file inside
                    // it has been transferred.
                    self.scheduleSourceCleanup(
                        item: item,
                        connection: source.connection,
                        group: group
                    )
                }
            } catch {
                self.recordPlanningFailure(
                    name: item.name,
                    source: source,
                    destination: destinationDirectory,
                    error: error
                )
            }
        }
    }

    private func enqueueOne(
        item: CloudItem,
        from source: TransferEndpoint,
        to destinationDirectory: TransferEndpoint,
        isMove: Bool,
        groupName: String?
    ) {
        enqueue(
            item: item,
            from: source,
            to: destinationDirectory,
            isMove: isMove,
            groupName: groupName
        )
    }

    private func recordPlanningFailure(
        name: String,
        source: TransferEndpoint,
        destination: TransferEndpoint,
        error: Error
    ) {
        var transfer = Transfer(
            name: name,
            kind: Self.kind(
                source: source.connection,
                destination: destination.connection,
                isMove: false
            ),
            source: source,
            destination: destination
        )
        transfer.status = .failed
        transfer.error = Self.describe(error)
        transfer.finishedAt = Date()
        append(transfer)
        archive(transfer)
    }

    /// Removes the source folder after a move, once its files are all done.
    private func scheduleSourceCleanup(item: CloudItem, connection: Connection, group: String) {
        Task { [weak self] in
            guard let self else { return }
            while self.hasActiveTransfers(inGroup: group) {
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            guard self.groupSucceededEntirely(group) else { return }
            if let provider = try? await registry.validatedProvider(for: connection) {
                try? await provider.deleteRecursively(item)
                await ListingCache.shared.invalidateSubtree(
                    connection: connection.id,
                    path: item.path
                )
            }
        }
    }

    private func hasActiveTransfers(inGroup group: String) -> Bool {
        transfers.contains { $0.groupName == group && $0.status.isActive }
    }

    private func groupSucceededEntirely(_ group: String) -> Bool {
        let members = transfers.filter { $0.groupName == group }
        guard !members.isEmpty else { return false }
        return members.allSatisfy { $0.status == .completed || $0.status == .skipped }
    }

    // MARK: - Controls

    public func cancel(_ id: UUID) {
        tasks[id]?.cancel()
        tasks[id] = nil
        update(id) { transfer in
            guard transfer.status.isActive else { return }
            transfer.status = .cancelled
            transfer.finishedAt = Date()
            transfer.speed = 0
        }
        finishSlot()
    }

    public func cancelAll() {
        for transfer in transfers where transfer.status.isActive {
            cancel(transfer.id)
        }
    }

    /// Stops a transfer but leaves its partial data in place, so resuming
    /// continues rather than restarting.
    public func pause(_ id: UUID) {
        tasks[id]?.cancel()
        tasks[id] = nil
        update(id) { transfer in
            guard transfer.status == .running || transfer.status == .queued else { return }
            transfer.status = .paused
            transfer.speed = 0
        }
        finishSlot()
    }

    public func resume(_ id: UUID) {
        update(id) { transfer in
            guard transfer.status == .paused else { return }
            transfer.status = .queued
        }
        pump()
    }

    public func retry(_ id: UUID) {
        update(id) { transfer in
            guard transfer.isRetryable else { return }
            transfer.status = .queued
            transfer.error = nil
            transfer.transferred = 0
            transfer.finishedAt = nil
            transfer.startedAt = nil
        }
        samples[id] = nil
        pump()
    }

    public func retryAllFailed() {
        for transfer in transfers where transfer.status == .failed {
            retry(transfer.id)
        }
    }

    /// Clears finished rows from the list; they stay in Activity History.
    public func clearFinished() {
        transfers.removeAll { $0.status.isFinished }
        reindex()
    }

    public func clearHistory() {
        history.removeAll()
        persistHistory()
    }

    // MARK: - Scheduling

    /// Starts as many queued transfers as the concurrency limit allows.
    private func pump() {
        while running < maxConcurrent,
              let next = transfers.first(where: { $0.status == .queued }) {
            start(next.id)
        }
    }

    private func start(_ id: UUID) {
        guard let transfer = self[id], transfer.status == .queued else { return }
        running += 1
        update(id) { current in
            current.status = .running
            current.startedAt = current.startedAt ?? Date()
        }

        let task = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.execute(id: id)
                self.complete(id, error: nil)
            } catch {
                self.complete(id, error: error)
            }
        }
        tasks[id] = task
    }

    private func finishSlot() {
        running = max(0, running - 1)
        pump()
    }

    private func complete(_ id: UUID, error: Error?) {
        tasks[id] = nil
        samples[id] = nil
        update(id) { transfer in
            transfer.finishedAt = Date()
            transfer.speed = 0
            if let error {
                if error is SkipTransfer {
                    // The conflict policy said the destination already had this
                    // file; `execute` already marked it skipped.
                    transfer.status = .skipped
                } else if error is CancellationError {
                    // A pause already set the status; don't overwrite it.
                    if transfer.status != .paused { transfer.status = .cancelled }
                } else if case StorageError.cancelled = error {
                    if transfer.status != .paused { transfer.status = .cancelled }
                } else {
                    transfer.status = .failed
                    transfer.error = Self.describe(error)
                }
            } else {
                transfer.status = .completed
                if let size = transfer.size { transfer.transferred = size }
            }
        }
        if let transfer = self[id], transfer.status.isFinished, transfer.status != .paused {
            archive(transfer)
        }
        finishSlot()
    }

    // MARK: - Execution

    private func execute(id: UUID) async throws {
        guard let transfer = self[id] else { return }

        let sourceConnection = transfer.source.connection
        let destinationConnection = transfer.destination.connection
        let sourceProvider = try await registry.validatedProvider(for: sourceConnection)
        let destinationProvider = sourceConnection.id == destinationConnection.id
            ? sourceProvider
            : try await registry.validatedProvider(for: destinationConnection)

        // Resolve the conflict policy before moving any bytes.
        let finalPath = try await resolveDestination(
            transfer: transfer,
            provider: destinationProvider
        )
        guard let finalPath else {
            update(id) { $0.status = .skipped }
            throw SkipTransfer()
        }
        if finalPath != transfer.destination.path {
            update(id) { $0.destination.path = finalPath }
        }

        let item = CloudItem(
            name: transfer.name,
            path: transfer.source.path,
            kind: .file,
            size: transfer.size
        )
        let progress = makeProgressHandler(for: id)

        // Same connection, and the provider can copy without our involvement:
        // no bytes cross the network twice.
        if sourceConnection.id == destinationConnection.id,
           sourceProvider.capabilities.contains(.serverSideCopy) {
            if transfer.isMove {
                try await sourceProvider.move(item, to: finalPath)
            } else {
                try await sourceProvider.copy(item, to: finalPath)
            }
            update(id) { current in
                if let size = current.size { current.transferred = size }
                current.kind = .serverSideCopy
            }
            await invalidateCaches(for: transfer, finalPath: finalPath)
            return
        }

        switch (sourceConnection.kind, destinationConnection.kind) {
        case (.local, .local):
            let destinationLocal = destinationProvider as? LocalProvider
            let sourceLocal = sourceProvider as? LocalProvider
            guard let destinationLocal, let sourceLocal else {
                throw StorageError.provider("Local transfer had a non-local provider.")
            }
            let sourceURL = sourceLocal.url(for: transfer.source.path)
            _ = try await destinationLocal.upload(
                sourceURL, to: finalPath, contentType: nil, progress: progress
            )

        case (.local, _):
            guard let sourceLocal = sourceProvider as? LocalProvider else {
                throw StorageError.provider("Upload source wasn't local.")
            }
            let sourceURL = sourceLocal.url(for: transfer.source.path)
            _ = try await destinationProvider.upload(
                sourceURL,
                to: finalPath,
                contentType: MIMEType.forFilename(transfer.name),
                progress: progress
            )

        case (_, .local):
            guard let destinationLocal = destinationProvider as? LocalProvider else {
                throw StorageError.provider("Download destination wasn't local.")
            }
            let targetURL = destinationLocal.url(for: finalPath)
            try await sourceProvider.download(item, to: targetURL, progress: progress)

        default:
            // Remote to remote across providers: stream the source straight into
            // the destination so nothing is staged on disk.
            let stream = try await sourceProvider.readStream(item)
            _ = try await destinationProvider.uploadStream(
                stream,
                length: transfer.size,
                to: finalPath,
                contentType: MIMEType.forFilename(transfer.name),
                progress: progress
            )
        }

        if transfer.isMove {
            try await sourceProvider.delete(item)
        }
        await invalidateCaches(for: transfer, finalPath: finalPath)
    }

    private func invalidateCaches(for transfer: Transfer, finalPath: RemotePath) async {
        await ListingCache.shared.invalidate(
            connection: transfer.destination.connection.id,
            path: finalPath.parent
        )
        if transfer.isMove {
            await ListingCache.shared.invalidate(
                connection: transfer.source.connection.id,
                path: transfer.source.path.parent
            )
        }
    }

    /// Applies the conflict policy. Returns the path to write, or nil to skip.
    private func resolveDestination(
        transfer: Transfer,
        provider: any StorageProvider
    ) async throws -> RemotePath? {
        let path = transfer.destination.path
        switch conflictPolicy {
        case .overwrite, .ask:
            // `.ask` is resolved by the UI before enqueueing; reaching here
            // means the user already chose to proceed.
            return path
        case .skip:
            let exists = (try? await provider.stat(path)) != nil
            return exists ? nil : path
        case .rename:
            guard (try? await provider.stat(path)) != nil else { return path }
            return try await freeName(for: path, provider: provider)
        }
    }

    /// `report.pdf` -> `report 2.pdf`, the way Finder does it.
    private func freeName(
        for path: RemotePath,
        provider: any StorageProvider
    ) async throws -> RemotePath {
        let name = path.name
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        for suffix in 2...200 {
            let candidate = ext.isEmpty ? "\(base) \(suffix)" : "\(base) \(suffix).\(ext)"
            let attempt = path.parent.appending(candidate)
            if (try? await provider.stat(attempt)) == nil { return attempt }
        }
        throw StorageError.conflict("Couldn't find an unused name for \(name).")
    }

    /// Progress handler that smooths the rate and throttles main-actor updates.
    ///
    /// `URLSession` can report progress hundreds of times a second; forwarding
    /// each one would spend more time redrawing than transferring.
    private func makeProgressHandler(for id: UUID) -> ProgressHandler {
        let throttle = Locked(Date.distantPast)
        return { [weak self] completed, total in
            let now = Date()
            let shouldSend = throttle.write { last -> Bool in
                guard now.timeIntervalSince(last) >= 0.15 else { return false }
                last = now
                return true
            }
            guard shouldSend else { return }
            Task { @MainActor [weak self] in
                self?.applyProgress(id: id, completed: completed, total: total, at: now)
            }
        }
    }

    private func applyProgress(id: UUID, completed: Int64, total: Int64?, at now: Date) {
        guard let index = indexByID[id], transfers[index].status == .running else { return }

        // Exponential moving average: a raw delta jumps around too much to read.
        var speed = transfers[index].speed
        if let previous = samples[id] {
            let elapsed = now.timeIntervalSince(previous.time)
            if elapsed > 0.05 {
                let instant = Double(completed - previous.bytes) / elapsed
                speed = previous.speed == 0 ? instant : previous.speed * 0.7 + instant * 0.3
            }
        }
        samples[id] = (time: now, bytes: completed, speed: speed)

        transfers[index].transferred = completed
        transfers[index].speed = max(0, speed)
        if transfers[index].size == nil, let total, total > 0 {
            transfers[index].size = total
        }
    }

    // MARK: - Collection plumbing

    private subscript(id: UUID) -> Transfer? {
        guard let index = indexByID[id] else { return nil }
        return transfers[index]
    }

    private func append(_ transfer: Transfer) {
        indexByID[transfer.id] = transfers.count
        transfers.append(transfer)
    }

    private func update(_ id: UUID, _ body: (inout Transfer) -> Void) {
        guard let index = indexByID[id] else { return }
        body(&transfers[index])
    }

    private func reindex() {
        indexByID = Dictionary(
            uniqueKeysWithValues: transfers.enumerated().map { ($0.element.id, $0.offset) }
        )
    }

    private func archive(_ transfer: Transfer) {
        history.insert(TransferRecord(from: transfer), at: 0)
        if history.count > Self.historyLimit {
            history.removeLast(history.count - Self.historyLimit)
        }
        persistHistory()
    }

    private func persistHistory() {
        let snapshot = history
        Task.detached(priority: .background) {
            try? JSONFile.write(snapshot, to: AppPaths.historyFile)
        }
    }

    private static func kind(
        source: Connection,
        destination: Connection,
        isMove: Bool
    ) -> Transfer.Kind {
        switch (source.kind, destination.kind) {
        case (.local, .local): .localCopy
        case (.local, _): .upload
        case (_, .local): .download
        default: source.id == destination.id ? .serverSideCopy : .remoteCopy
        }
    }

    /// A message fit to show the user, whatever the error's origin.
    public static func describe(_ error: Error) -> String {
        if let storage = error as? StorageError {
            return storage.errorDescription ?? "The transfer failed."
        }
        return error.localizedDescription
    }
}

/// Thrown to unwind a transfer the conflict policy said to skip. Never surfaced.
private struct SkipTransfer: Error {}
