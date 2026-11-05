import Foundation
import OpenborldCore

/// Launches `Tests/Support/mock_cloud.py` and tears it down afterwards.
final class MockCloud {
    let port: Int
    private let process: Process

    static let azureAccount = "devstoreaccount1"
    static let azureKey = Data("openborld-test-account-key-0123456789".utf8)
        .base64EncodedString()
    static let s3AccessKey = "AKIAIOSFODNN7EXAMPLE"
    static let s3Secret = "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY"

    init(scriptPath: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        // -I: don't let the script's own directory onto the import path.
        process.arguments = ["python3", "-I", scriptPath.path, "0"]

        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
        self.process = process

        // The server prints its port once it's listening.
        var discovered: Int?
        let deadline = Date().addingTimeInterval(15)
        var buffer = Data()
        while Date() < deadline, discovered == nil {
            let chunk = output.fileHandleForReading.availableData
            if chunk.isEmpty {
                if !process.isRunning { break }
                continue
            }
            buffer.append(chunk)
            guard let text = String(data: buffer, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n") {
                if line.hasPrefix("MOCK_CLOUD_PORT=") {
                    discovered = Int(line.dropFirst("MOCK_CLOUD_PORT=".count))
                }
            }
        }

        guard let port = discovered else {
            process.terminate()
            throw StorageError.provider("The mock cloud server didn't start.")
        }
        self.port = port
    }

    deinit {
        process.terminate()
    }

    func stop() {
        process.terminate()
    }

    var baseURL: String { "http://127.0.0.1:\(port)" }

    /// Wipes the server's state between suites.
    func reset() async throws {
        _ = try await control("reset")
    }

    /// Creates `count` objects in one call, for pagination tests.
    func seed(container: String, count: Int, prefix: String = "") async throws {
        var path = "seed?container=\(container)&count=\(count)"
        if !prefix.isEmpty {
            path += "&prefix=\(prefix.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? prefix)"
        }
        _ = try await control(path)
    }

    /// Every signature the server checked, so a test can assert that a
    /// particular scheme was actually exercised rather than bypassed.
    func authLog() async throws -> [[String: Any]] {
        let data = try await control("auth_log")
        return (try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]) ?? []
    }

    private func control(_ path: String) async throws -> Data {
        guard let url = URL(string: "\(baseURL)/__control/\(path)") else {
            throw StorageError.provider("bad control URL")
        }
        let (data, _) = try await URLSession.shared.data(from: url)
        return data
    }

    // MARK: - Connections pointed at this server

    func azureConnection(
        container: String? = nil,
        multipartThreshold: Int? = nil,
        chunkSize: Int? = nil
    ) -> (Connection, ConnectionSecrets) {
        var connection = Connection(name: "Mock Azure", kind: .azureBlob)
        connection[.authMethod] = AzureAuthMethod.accountKey.rawValue
        connection[.accountName] = Self.azureAccount
        // Azurite-style path addressing: the account lives in the path.
        connection[.blobEndpoint] = "\(baseURL)/\(Self.azureAccount)"
        if let container { connection[.containerScope] = container }
        if let multipartThreshold {
            connection[.multipartThresholdBytes] = String(multipartThreshold)
        }
        if let chunkSize { connection[.chunkSizeBytes] = String(chunkSize) }

        var secrets = ConnectionSecrets()
        secrets[.accountKey] = Self.azureKey
        return (connection, secrets)
    }

    func azureSASConnection(container: String) -> (Connection, ConnectionSecrets) {
        var connection = Connection(name: "Mock Azure SAS", kind: .azureBlob)
        connection[.authMethod] = AzureAuthMethod.sasURL.rawValue
        var secrets = ConnectionSecrets()
        // A structurally complete token; the mock checks shape, as a real
        // client must, since only the service can validate the signature.
        secrets[.sasURL] = "\(baseURL)/\(Self.azureAccount)/\(container)"
            + "?sv=2021-12-02&ss=b&srt=sco&sp=rwdlac&se=2099-01-01T00:00:00Z&sig=bW9jaw%3D%3D"
        return (connection, secrets)
    }

    func s3Connection(
        bucket: String? = nil,
        multipartThreshold: Int? = nil,
        chunkSize: Int? = nil
    ) -> (Connection, ConnectionSecrets) {
        var connection = Connection(name: "Mock S3", kind: .s3Compatible)
        connection[.accessKeyID] = Self.s3AccessKey
        connection[.endpoint] = baseURL
        connection[.region] = "us-east-1"
        connection[.usePathStyle] = "true"
        if let bucket { connection[.bucketScope] = bucket }
        if let multipartThreshold {
            connection[.multipartThresholdBytes] = String(multipartThreshold)
        }
        if let chunkSize { connection[.chunkSizeBytes] = String(chunkSize) }

        var secrets = ConnectionSecrets()
        secrets[.secretAccessKey] = Self.s3Secret
        return (connection, secrets)
    }
}

// MARK: - Shared helpers

enum TestFiles {
    static let directory: URL = {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("openborld-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    /// Writes a file of `size` bytes with a deterministic, non-repeating
    /// pattern, so a truncated or misordered chunk is detectable rather than
    /// hidden by all-zero content.
    static func make(name: String, size: Int) throws -> URL {
        let url = directory.appendingPathComponent(name)
        var data = Data(capacity: size)
        var seed: UInt64 = 0x2545F4914F6CDD1D
        while data.count < size {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            var value = seed
            withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
        }
        data = data.prefix(size)
        try data.write(to: url)
        return url
    }

    static func cleanup() {
        try? FileManager.default.removeItem(at: directory)
    }
}
