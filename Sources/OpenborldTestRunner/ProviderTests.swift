import Foundation
import OpenborldCore

/// Drives the real Azure and S3 providers against the local mock cloud, which
/// verifies every signature with an independent implementation.
///
/// Still to come: the full operation matrix (chunked upload resume, server-side
/// copy, pagination, unicode keys). This first pass proves the signing path and
/// the basic object lifecycle, which is what the providers had no coverage of
/// at all.
func runProviderTests(_ h: Harness, scriptPath: URL) async {
    await h.suite("Provider integration (mock cloud)")

    var server: MockCloud?
    await h.test("mock cloud server starts") {
        do {
            server = try MockCloud(scriptPath: scriptPath)
        } catch {
            throw skip("couldn't start the server: \(error)")
        }
    }
    guard let server else { return }
    defer { server.stop() }

    // MARK: Azure

    await h.test("Azure: SharedKey signature is accepted") {
        let (connection, secrets) = server.azureConnection()
        let provider = try AzureBlobProvider(connection: connection, secrets: secrets)
        try await provider.validate()

        // Prove the SharedKey path was actually exercised, not a SAS fallback.
        let log = try await server.authLog()
        let sharedKey = log.filter { $0["scheme"] as? String == "sharedkey" }
        await h.expect(!sharedKey.isEmpty, "at least one SharedKey request was verified")
        await h.expect(
            sharedKey.allSatisfy { $0["ok"] as? Bool == true },
            "every SharedKey signature matched the server's own computation"
        )
    }

    await h.test("Azure: container and blob lifecycle") {
        let (connection, secrets) = server.azureConnection()
        let provider = try AzureBlobProvider(connection: connection, secrets: secrets)

        try await provider.createContainer(named: "docs")
        let containers = try await provider.list(.root, cursor: nil, pageSize: 100)
        await h.expect(
            containers.items.contains { $0.name == "docs" && $0.kind == .container },
            "the new container appears in the account listing"
        )

        let file = try TestFiles.make(name: "azure-small.bin", size: 4096)
        let item = try await provider.upload(
            file, to: RemotePath("docs/folder/azure-small.bin"),
            contentType: nil, progress: nil
        )
        await h.equal(item.size, 4096, "uploaded size")

        // A delimiter listing must show the prefix as a folder, not a blob.
        let root = try await provider.list(RemotePath("docs"), cursor: nil, pageSize: 100)
        await h.expect(
            root.items.contains { $0.name == "folder" && $0.kind == .folder },
            "prefix surfaces as a folder"
        )

        let round = try await provider.read(item, range: nil)
        let expected = try Data(contentsOf: file)
        await h.equal(round, expected, "downloaded bytes match what was uploaded")

        try await provider.delete(item)
        let after = try await provider.list(
            RemotePath("docs/folder"), cursor: nil, pageSize: 100
        )
        await h.expect(after.items.isEmpty, "blob is gone after delete")
    }

    await h.test("Azure: SAS URL connection is container-scoped") {
        _ = try? await server.reset()
        let (keyed, keySecrets) = server.azureConnection()
        let seeder = try AzureBlobProvider(connection: keyed, secrets: keySecrets)
        try await seeder.createContainer(named: "shared")
        let file = try TestFiles.make(name: "sas.txt", size: 64)
        _ = try await seeder.upload(
            file, to: RemotePath("shared/sas.txt"), contentType: nil, progress: nil
        )

        let (connection, secrets) = server.azureSASConnection(container: "shared")
        let provider = try AzureBlobProvider(connection: connection, secrets: secrets)
        try await provider.validate()

        // Container-scoped: paths are keys, with no container component.
        let listing = try await provider.list(.root, cursor: nil, pageSize: 100)
        await h.expect(
            listing.items.contains { $0.name == "sas.txt" },
            "the container's contents are the connection root"
        )
        await h.equal(provider.containerScope, "shared", "scope")
    }

    // MARK: S3

    await h.test("S3: SigV4 signature is accepted") {
        _ = try? await server.reset()
        let (connection, secrets) = server.s3Connection()
        let provider = try S3Provider(connection: connection, secrets: secrets)
        try await provider.validate()

        let log = try await server.authLog()
        let sigv4 = log.filter { $0["scheme"] as? String == "sigv4" }
        await h.expect(!sigv4.isEmpty, "at least one SigV4 request was verified")
        await h.expect(
            sigv4.allSatisfy { $0["ok"] as? Bool == true },
            "every SigV4 signature matched the server's own canonical request"
        )
    }

    await h.test("S3: bucket and object lifecycle") {
        let (connection, secrets) = server.s3Connection()
        let provider = try S3Provider(connection: connection, secrets: secrets)

        try await provider.createContainer(named: "assets")
        let file = try TestFiles.make(name: "s3-small.bin", size: 8192)
        let item = try await provider.upload(
            file, to: RemotePath("assets/img/s3-small.bin"),
            contentType: nil, progress: nil
        )
        await h.equal(item.size, 8192, "uploaded size")

        let round = try await provider.read(item, range: nil)
        await h.equal(round, try Data(contentsOf: file), "round-tripped bytes")

        try await provider.delete(item)
    }

    await h.test("S3: keys with spaces and unicode survive signing") {
        // The encoding minefield: a mismatch between the signed canonical URI
        // and the sent path shows up only on keys like these.
        let (connection, secrets) = server.s3Connection()
        let provider = try S3Provider(connection: connection, secrets: secrets)
        try await provider.createContainer(named: "awkward")

        let names = ["a file with spaces.txt", "üñïçødé-ñame.txt", "plus+and&amp.txt"]
        for name in names {
            let file = try TestFiles.make(name: "payload.bin", size: 128)
            let path = RemotePath(components: ["awkward", "dir", name])
            let item = try await provider.upload(
                file, to: path, contentType: nil, progress: nil
            )
            let round = try await provider.read(item, range: nil)
            await h.equal(round.count, 128, "round-trip for “\(name)”")
        }

        let listing = try await provider.list(
            RemotePath("awkward/dir"), cursor: nil, pageSize: 100
        )
        for name in names {
            await h.expect(
                listing.items.contains { $0.name == name },
                "“\(name)” listed back with its name intact"
            )
        }
    }

    await h.test("a wrong secret is rejected, not silently accepted") {
        var (connection, _) = server.s3Connection()
        connection[.accessKeyID] = MockCloud.s3AccessKey
        var secrets = ConnectionSecrets()
        secrets[.secretAccessKey] = "this-is-not-the-right-secret"
        let provider = try S3Provider(connection: connection, secrets: secrets)
        await h.throwsError("bad secret") { try await provider.validate() }
    }
}

/// Prints both sides of a failed signature.
///
/// Run with `swift run openborld-tests --diagnose`. The client's string-to-sign and
/// the server's are printed character-for-character so the differing field is
/// obvious, rather than inferring it from a 403.
func diagnoseSignatures(scriptPath: URL) async {
    guard let server = try? MockCloud(scriptPath: scriptPath) else {
        print("couldn't start the mock server")
        return
    }
    defer { server.stop() }

    func show(_ title: String, _ text: String) {
        print("\n\u{001B}[1m\(title)\u{001B}[0m")
        for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            print(String(format: "  %2d │ %@", index, line.isEmpty ? "⟨empty⟩" : String(line)))
        }
    }

    // --- Azure ---
    let (azureConnection, azureSecrets) = server.azureConnection()
    if let provider = try? AzureBlobProvider(connection: azureConnection, secrets: azureSecrets) {
        _ = try? await provider.validate()
        let clientSide = AzureAuth.lastStringToSign.current
        let log = (try? await server.authLog()) ?? []
        let serverSide = log.last { $0["scheme"] as? String == "sharedkey" }?["string_to_sign"] as? String

        print("\n" + String(repeating: "═", count: 70))
        print("AZURE SharedKey")
        show("client signed", clientSide)
        show("server expected", serverSide ?? "⟨no sharedkey request reached the server⟩")
        if let serverSide {
            print(clientSide == serverSide
                ? "\n  → identical"
                : "\n  → DIFFER at line \(firstDifference(clientSide, serverSide))")
        }
    }

    _ = try? await server.reset()

    // --- S3 ---
    let (s3Connection, s3Secrets) = server.s3Connection()
    if let provider = try? S3Provider(connection: s3Connection, secrets: s3Secrets) {
        _ = try? await provider.createContainer(named: "diag")
        let clientSide = SigV4.lastCanonicalRequest.current
        let log = (try? await server.authLog()) ?? []
        let serverSide = log.last { $0["scheme"] as? String == "sigv4" }?["canonical_request"] as? String

        print("\n" + String(repeating: "═", count: 70))
        print("S3 SigV4 canonical request")
        show("client signed", clientSide)
        show("server expected", serverSide ?? "⟨no sigv4 request reached the server⟩")
        if let serverSide {
            print(clientSide == serverSide
                ? "\n  → identical"
                : "\n  → DIFFER at line \(firstDifference(clientSide, serverSide))")
        }
    }
    print("")
}

private func firstDifference(_ a: String, _ b: String) -> String {
    let left = a.split(separator: "\n", omittingEmptySubsequences: false)
    let right = b.split(separator: "\n", omittingEmptySubsequences: false)
    for index in 0..<max(left.count, right.count) {
        let l = index < left.count ? String(left[index]) : "⟨missing⟩"
        let r = index < right.count ? String(right[index]) : "⟨missing⟩"
        if l != r { return "\(index): client \(l.debugDescription) vs server \(r.debugDescription)" }
    }
    return "nowhere (lengths differ only in trailing newline)"
}
