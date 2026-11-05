import Foundation

#if canImport(FoundationNetworking)
// On Linux and Windows, Foundation is split and the URL loading system lives
// in its own module.
import FoundationNetworking
#endif

/// Shared HTTP engine for every network provider.
///
/// One `URLSession` per process means TLS handshakes and HTTP/2 connections are
/// reused across folder navigations — no reconnect when the user changes folder,
/// which is one of the hard performance requirements. Bodies are always streamed
/// to or from disk, never materialised in memory.
public final class HTTPClient: NSObject, @unchecked Sendable {
    public static let shared = HTTPClient()

    private var session: URLSession!
    private let bridges = BridgeRegistry()

    public init(maxConnectionsPerHost: Int = 16, timeout: TimeInterval = 60) {
        let config = URLSessionConfiguration.default
        config.httpMaximumConnectionsPerHost = maxConnectionsPerHost
        config.timeoutIntervalForRequest = timeout
        // Long transfers must not be killed by a request timeout; the per-request
        // timeout above covers stalls between bytes.
        config.timeoutIntervalForResource = 86_400
        #if canImport(Darwin)
        // Get-only in swift-corelibs-foundation; it simply has no equivalent
        // behaviour, so elsewhere a request fails fast instead of waiting.
        config.waitsForConnectivity = true
        #endif
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        config.httpShouldUsePipelining = true
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        super.init()
        // One session-level delegate that fans out to per-task bridges.
        // Per-task delegates exist only in Apple's SDK; this shape works the
        // same on macOS, Linux, and Windows.
        self.session = URLSession(
            configuration: config,
            delegate: self,
            delegateQueue: nil
        )
    }

    // MARK: - Small request/response

    /// For control-plane calls: listings, metadata, copy, delete. Bodies here are
    /// small by definition, so buffering them is fine.
    @discardableResult
    public func send(
        _ request: URLRequest,
        acceptableStatus: Set<Int> = Set(200..<300),
        retries: Int = 2
    ) async throws -> HTTPResult {
        try await withRetry(attempts: retries) {
            let (data, response) = try await self.rawSend(request)
            guard acceptableStatus.contains(response.statusCode) else {
                throw Self.error(from: response, body: data)
            }
            return HTTPResult(data: data, response: response)
        }
    }

    /// Like `send` but treats 404 as a value rather than an error.
    public func sendAllowingNotFound(
        _ request: URLRequest,
        retries: Int = 2
    ) async throws -> HTTPResult? {
        let result = try await send(
            request,
            acceptableStatus: Set(200..<300).union([404]),
            retries: retries
        )
        return result.response.statusCode == 404 ? nil : result
    }

    private func rawSend(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw StorageError.network("The server sent a response that wasn't HTTP.")
            }
            return (data, http)
        } catch let error as StorageError {
            throw error
        } catch let error as URLError {
            throw Self.translate(error)
        }
    }

    // MARK: - Download to file (streaming, resumable, cancellable)

    /// Streams the response body straight into `destination`.
    ///
    /// When `resumeFrom` is non-zero a `Range` header is sent and bytes are
    /// appended, which is how an interrupted download picks up where it stopped.
    @discardableResult
    public func download(
        _ request: URLRequest,
        to destination: URL,
        resumeFrom offset: Int64 = 0,
        progress: ProgressHandler? = nil
    ) async throws -> HTTPURLResponse {
        var request = request
        if offset > 0 {
            request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range")
        }

        let fm = FileManager.default
        try fm.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if offset == 0 || !fm.fileExists(atPath: destination.path) {
            fm.createFile(atPath: destination.path, contents: nil, attributes: nil)
        }
        let handle = try FileHandle(forWritingTo: destination)
        if offset > 0 {
            try handle.seek(toOffset: UInt64(offset))
        } else {
            try handle.truncate(atOffset: 0)
        }

        let sink = FileSink(handle: handle, baseOffset: offset)
        defer { sink.close() }

        let response = try await perform(request, sink: sink, progress: progress)
        sink.close()
        return response
    }

    /// Streams the response body as chunks — used to pipe one provider's bytes
    /// directly into another's upload without touching disk.
    public func stream(_ request: URLRequest) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            let sink = StreamSink(continuation: continuation)
            let task = Task {
                do {
                    _ = try await self.perform(request, sink: sink, progress: nil)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Upload

    /// Uploads directly from a file on disk. `URLSession` memory-maps and streams
    /// it, so a 50 GB file costs no more RAM than a 50 KB one.
    @discardableResult
    public func upload(
        _ request: URLRequest,
        fromFile file: URL,
        acceptableStatus: Set<Int> = Set(200..<300),
        progress: ProgressHandler? = nil
    ) async throws -> HTTPResult {
        let sink = MemorySink()
        let response = try await perform(
            request,
            sink: sink,
            progress: progress,
            uploadFile: file
        )
        guard acceptableStatus.contains(response.statusCode) else {
            throw Self.error(from: response, body: sink.data)
        }
        return HTTPResult(data: sink.data, response: response)
    }

    /// Uploads an in-memory body. Only for genuinely small payloads: block lists,
    /// metadata documents, multipart-complete XML.
    @discardableResult
    public func upload(
        _ request: URLRequest,
        body: Data,
        acceptableStatus: Set<Int> = Set(200..<300),
        retries: Int = 2
    ) async throws -> HTTPResult {
        var request = request
        request.httpBody = body
        if request.value(forHTTPHeaderField: "Content-Length") == nil {
            request.setValue(String(body.count), forHTTPHeaderField: "Content-Length")
        }
        return try await send(request, acceptableStatus: acceptableStatus, retries: retries)
    }

    // MARK: - Core task driver

    private func perform(
        _ request: URLRequest,
        sink: any ByteSink,
        progress: ProgressHandler?,
        uploadFile: URL? = nil
    ) async throws -> HTTPURLResponse {
        let bridge = TaskBridge(sink: sink, progress: progress)
        let task: URLSessionTask = if let uploadFile {
            session.uploadTask(with: request, fromFile: uploadFile)
        } else {
            session.dataTask(with: request)
        }
        bridges.insert(bridge, for: task.taskIdentifier)
        defer { bridges.remove(task.taskIdentifier) }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                bridge.onFinish = { result in
                    switch result {
                    case .success(let response): continuation.resume(returning: response)
                    case .failure(let error): continuation.resume(throwing: error)
                    }
                }
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    // MARK: - Retry

    private func withRetry<T: Sendable>(
        attempts: Int,
        _ body: @Sendable () async throws -> T
    ) async throws -> T {
        var lastError: Error?
        for attempt in 0...max(0, attempts) {
            do {
                return try await body()
            } catch let error as StorageError where error.isRetryable {
                lastError = error
                if attempt == attempts { break }
                let backoff = min(8.0, pow(2.0, Double(attempt)) * 0.4)
                let jitter = Double.random(in: 0...0.25)
                try? await Task.sleep(nanoseconds: UInt64((backoff + jitter) * 1_000_000_000))
                try Task.checkCancellation()
            }
        }
        throw lastError ?? StorageError.network("The request failed.")
    }

    // MARK: - Error translation

    static func translate(_ error: URLError) -> StorageError {
        switch error.code {
        case .cancelled:
            return .cancelled
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed:
            return .network("No network connection.")
        case .timedOut:
            return .network("The connection timed out.")
        case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
            return .network("Can't reach the server. Check the address.")
        case .secureConnectionFailed, .serverCertificateUntrusted,
             .serverCertificateHasBadDate, .serverCertificateNotYetValid,
             .serverCertificateHasUnknownRoot:
            return .network("The server's TLS certificate couldn't be verified.")
        case .userAuthenticationRequired:
            return .authenticationFailed("The server requires authentication.")
        default:
            return .network(error.localizedDescription)
        }
    }

    static func error(from response: HTTPURLResponse, body: Data) -> StorageError {
        let message = Self.extractMessage(from: body, response: response)
        switch response.statusCode {
        case 401:
            return .authenticationFailed(message.isEmpty ? "The credentials were rejected." : message)
        case 403:
            return .accessDenied(message.isEmpty ? "The credentials don't allow this operation." : message)
        case 404:
            return .notFound(message.isEmpty ? (response.url?.path ?? "resource") : message)
        case 409, 412:
            return .conflict(message.isEmpty ? "The item already exists or has changed." : message)
        default:
            return .http(status: response.statusCode, message: message)
        }
    }

    /// Pulls a human-readable reason out of an XML or JSON error body. Azure and
    /// S3 both bury the useful part in a `<Message>`/`message` field.
    private static func extractMessage(from body: Data, response: HTTPURLResponse) -> String {
        // Azure puts a short code in a header, which beats a parsed body.
        if let code = response.value(forHTTPHeaderField: "x-ms-error-code"), !code.isEmpty {
            return Self.humanize(code)
        }
        guard !body.isEmpty, body.count < 64_000,
              let text = String(data: body, encoding: .utf8)
        else { return "" }

        if let root = XMLLite.parse(text) {
            for key in ["Message", "message", "Error"] {
                if let found = root.firstDescendant(named: key)?.text, !found.isEmpty {
                    return found.split(separator: "\n").first.map(String.init) ?? found
                }
            }
            if let code = root.firstDescendant(named: "Code")?.text, !code.isEmpty {
                return Self.humanize(code)
            }
        }
        if let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
            if let message = json["message"] as? String { return message }
            if let nested = json["error"] as? [String: Any],
               let message = nested["message"] as? String { return message }
            if let nested = json["error"] as? String { return nested }
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count <= 200 ? trimmed : ""
    }

    /// `AuthorizationPermissionMismatch` -> `Authorization permission mismatch`.
    private static func humanize(_ code: String) -> String {
        var out = ""
        for (index, char) in code.enumerated() {
            if index > 0, char.isUppercase, !out.hasSuffix(" ") { out.append(" ") }
            out.append(char)
        }
        guard let first = out.first else { return code }
        return first.uppercased() + out.dropFirst().lowercased()
    }
}

// MARK: - Session delegate

extension HTTPClient: URLSessionDataDelegate {
    public func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        // The completion-handler form, not the `async` one: the async variant
        // is an Apple-SDK concurrency import and isn't offered by corelibs.
        bridges.bridge(for: dataTask.taskIdentifier)?.received(response: response)
        completionHandler(.allow)
    }

    public func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        bridges.bridge(for: dataTask.taskIdentifier)?.received(data: data)
    }

    public func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        bridges.bridge(for: task.taskIdentifier)?.sent(
            total: totalBytesSent,
            expected: totalBytesExpectedToSend
        )
    }

    public func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        bridges.bridge(for: task.taskIdentifier)?.completed(
            response: task.response,
            error: error
        )
    }
}

public struct HTTPResult: @unchecked Sendable {
    public let data: Data
    public let response: HTTPURLResponse

    public var text: String { String(data: data, encoding: .utf8) ?? "" }

    public func header(_ name: String) -> String? {
        response.value(forHTTPHeaderField: name)
    }

    public var contentLength: Int64? {
        header("Content-Length").flatMap(Int64.init)
    }
}

// MARK: - Byte sinks

/// Where a response body goes. Keeps the task driver indifferent to whether the
/// caller wants a file, a stream, or a small buffer.
protocol ByteSink: AnyObject, Sendable {
    func write(_ data: Data)
    func close()
}

private final class FileSink: ByteSink, @unchecked Sendable {
    private let handle: Locked<FileHandle?>

    init(handle: FileHandle, baseOffset: Int64) {
        self.handle = Locked(handle)
    }

    func write(_ data: Data) {
        handle.write { try? $0?.write(contentsOf: data) }
    }

    func close() {
        handle.write { current in
            try? current?.close()
            current = nil
        }
    }
}

private final class StreamSink: ByteSink, @unchecked Sendable {
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation

    init(continuation: AsyncThrowingStream<Data, Error>.Continuation) {
        self.continuation = continuation
    }

    func write(_ data: Data) { continuation.yield(data) }
    func close() {}
}

private final class MemorySink: ByteSink, @unchecked Sendable {
    private let buffer = Locked(Data())

    var data: Data { buffer.current }

    func write(_ data: Data) {
        buffer.write { $0.append(data) }
    }

    func close() {}
}

// MARK: - Per-task delegate

private final class TaskBridge: @unchecked Sendable {
    private struct State {
        var received: Int64 = 0
        var expected: Int64?
        var response: HTTPURLResponse?
        var finished = false
        var onFinish: ((Result<HTTPURLResponse, Error>) -> Void)?
    }

    private let sink: any ByteSink
    private let progress: ProgressHandler?
    private let state = Locked(State())

    var onFinish: ((Result<HTTPURLResponse, Error>) -> Void)? {
        get { state.read { $0.onFinish } }
        set { state.write { $0.onFinish = newValue } }
    }

    init(sink: any ByteSink, progress: ProgressHandler?) {
        self.sink = sink
        self.progress = progress
    }

    /// Resumes the awaiting continuation exactly once, whatever order the
    /// delegate callbacks arrive in.
    private func finish(_ result: Result<HTTPURLResponse, Error>) {
        let handler: ((Result<HTTPURLResponse, Error>) -> Void)? = state.write { current in
            guard !current.finished else { return nil }
            current.finished = true
            return current.onFinish
        }
        handler?(result)
    }

    func received(response: URLResponse) {
        guard let http = response as? HTTPURLResponse else { return }
        state.write { current in
            current.response = http
            if response.expectedContentLength > 0 {
                current.expected = response.expectedContentLength
            }
        }
    }

    func received(data: Data) {
        sink.write(data)
        let snapshot = state.write { current -> (Int64, Int64?) in
            current.received += Int64(data.count)
            return (current.received, current.expected)
        }
        progress?(snapshot.0, snapshot.1)
    }

    func sent(total: Int64, expected: Int64) {
        progress?(total, expected > 0 ? expected : nil)
    }

    func completed(response: URLResponse?, error: Error?) {
        sink.close()
        if let error {
            finish(.failure((error as? URLError).map(HTTPClient.translate) ?? error))
            return
        }
        let http = state.read { $0.response } ?? (response as? HTTPURLResponse)
        guard let http else {
            finish(.failure(StorageError.network("The server sent no response.")))
            return
        }
        finish(.success(http))
    }
}

/// Routes session-level delegate callbacks to the bridge that owns each task.
private final class BridgeRegistry: @unchecked Sendable {
    private let storage = Locked([Int: TaskBridge]())

    func insert(_ bridge: TaskBridge, for id: Int) {
        storage.write { $0[id] = bridge }
    }

    func bridge(for id: Int) -> TaskBridge? {
        storage.read { $0[id] }
    }

    func remove(_ id: Int) {
        storage.write { $0.removeValue(forKey: id) }
    }
}
