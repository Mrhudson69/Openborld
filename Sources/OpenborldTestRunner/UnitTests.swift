import Foundation
import Crypto
import OpenborldCore

/// Tests that need no server: path arithmetic, encoding, credential parsing,
/// XML handling. These are where most of the fiddly bugs live.
func runUnitTests(_ h: Harness) async {
    await h.suite("Crypto primitives")

    await h.test("HMAC-SHA256 matches RFC 4231 test case 2") {
        // External ground truth for the primitive every signer is built on.
        let mac = HMAC<SHA256>.authenticationCode(
            for: Data("what do ya want for nothing?".utf8),
            using: SymmetricKey(data: Data("Jefe".utf8))
        )
        await h.equal(
            Data(mac).hexString,
            "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843",
            "RFC 4231 case 2"
        )
    }

    await h.test("SHA-256 of the empty string matches the SigV4 constant") {
        await h.equal(
            Data(SHA256.hash(data: Data())).hexString,
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
            "empty body hash"
        )
    }

    await h.suite("RemotePath")

    await h.test("parses and rejoins") {
        let path = RemotePath("container/folder/file.txt")
        await h.equal(path.components, ["container", "folder", "file.txt"], "components")
        await h.equal(path.joined, "container/folder/file.txt", "joined")
        await h.equal(path.name, "file.txt", "name")
        await h.equal(path.parent.joined, "container/folder", "parent")
        await h.equal(path.depth, 3, "depth")
    }

    await h.test("collapses empty and duplicated separators") {
        await h.equal(RemotePath("//a///b//").components, ["a", "b"], "squashed")
        await h.equal(RemotePath("").components, [], "empty")
        await h.equal(RemotePath("/").components, [], "slash only")
    }

    await h.test("root is its own parent, and prefix is empty there") {
        await h.equal(RemotePath.root.parent, RemotePath.root, "root parent")
        await h.equal(RemotePath.root.prefix, "", "root prefix")
        await h.expect(RemotePath.root.isRoot, "root isRoot")
    }

    await h.test("prefix ends in a slash below the root") {
        await h.equal(RemotePath("a/b").prefix, "a/b/", "prefix")
    }

    await h.test("ancestry and relative paths") {
        let parent = RemotePath("a/b")
        let child = RemotePath("a/b/c/d.txt")
        await h.expect(parent.isAncestor(of: child), "isAncestor")
        await h.expect(!child.isAncestor(of: parent), "not reversed")
        await h.expect(!parent.isAncestor(of: parent), "not itself")
        await h.equal(parent.relative(child)?.joined, "c/d.txt", "relative")
        await h.expect(RemotePath("x").relative(child) == nil, "unrelated gives nil")
    }

    await h.test("appending a path keeps order") {
        await h.equal(
            RemotePath("a").appending(path: RemotePath("b/c")).joined,
            "a/b/c",
            "appended"
        )
    }

    await h.suite("URI encoding")

    await h.test("encodes the RFC 3986 reserved set") {
        await h.equal(URIEncoding.encode("a b"), "a%20b", "space")
        await h.equal(URIEncoding.encode("a+b"), "a%2Bb", "plus")
        await h.equal(URIEncoding.encode("a/b"), "a%2Fb", "slash encoded")
        await h.equal(URIEncoding.encode("a/b", encodeSlash: false), "a/b", "slash kept")
        await h.equal(URIEncoding.encode("a~_-.z"), "a~_-.z", "unreserved untouched")
        await h.equal(URIEncoding.encode("é"), "%C3%A9", "utf-8 multibyte")
        await h.equal(URIEncoding.encode("a=b&c"), "a%3Db%26c", "query delimiters")
    }

    await h.test("canonical query sorts by encoded name then value") {
        await h.equal(
            URIEncoding.canonicalQuery([("b", "2"), ("a", "1"), ("a", "0")]),
            "a=0&a=1&b=2",
            "sorted"
        )
        await h.equal(
            URIEncoding.canonicalQuery([("uploadId", "a b")]),
            "uploadId=a%20b",
            "value encoded"
        )
    }

    await h.suite("Azure SAS URL parsing")

    await h.test("container URL yields endpoint, container, and token") {
        let config = try AzureAuth.parseSASURL(
            "https://acct.blob.core.windows.net/mycontainer?sv=2021-12-02&sp=rl&sig=abc%3D"
        )
        await h.equal(config.blobEndpoint.absoluteString, "https://acct.blob.core.windows.net", "endpoint")
        await h.equal(config.accountName, "acct", "account")
        await h.equal(config.containerScope, "mycontainer", "container")
        await h.equal(config.basePrefix, "", "no prefix")
        await h.expect(config.isContainerScoped, "container scoped")
    }

    await h.test("URL with a folder prefix keeps it as the root") {
        let config = try AzureAuth.parseSASURL(
            "https://acct.blob.core.windows.net/data/2024/q1?sv=2021-12-02&sig=x"
        )
        await h.equal(config.containerScope, "data", "container")
        await h.equal(config.basePrefix, "2024/q1", "prefix")

        // A path inside a prefix-scoped connection must resolve beneath it.
        let resolved = config.resolve(RemotePath("report.csv"))
        await h.equal(resolved.container, "data", "resolved container")
        await h.equal(resolved.key, "2024/q1/report.csv", "resolved key")

        // And the inverse mapping must strip it again.
        await h.equal(
            config.path(container: "data", key: "2024/q1/report.csv").joined,
            "report.csv",
            "round trip"
        )
    }

    await h.test("account-level SAS URL has no container scope") {
        let config = try AzureAuth.parseSASURL(
            "https://acct.blob.core.windows.net/?sv=2021-12-02&srt=sco&sig=x"
        )
        await h.expect(!config.isContainerScoped, "account scoped")
        let resolved = config.resolve(RemotePath("mycontainer/a/b.txt"))
        await h.equal(resolved.container, "mycontainer", "container from path")
        await h.equal(resolved.key, "a/b.txt", "key from path")
    }

    await h.test("rejects a URL with no signature") {
        await h.throwsError("no sig") {
            _ = try AzureAuth.parseSASURL("https://acct.blob.core.windows.net/c?sv=2021-12-02")
        }
        await h.throwsError("no query at all") {
            _ = try AzureAuth.parseSASURL("https://acct.blob.core.windows.net/c")
        }
        await h.throwsError("not a URL") {
            _ = try AzureAuth.parseSASURL("not a url at all")
        }
    }

    await h.test("percent-encoded container names are decoded") {
        let config = try AzureAuth.parseSASURL(
            "https://acct.blob.core.windows.net/my%20container?sv=1&sig=x"
        )
        await h.equal(config.containerScope, "my container", "decoded")
    }

    await h.test("normalises a token pasted with a leading ? or as a whole URL") {
        await h.equal(AzureAuth.normalizeSASToken("?sv=1&sig=x"), "sv=1&sig=x", "leading ?")
        await h.equal(AzureAuth.normalizeSASToken("&sv=1"), "sv=1", "leading &")
        await h.equal(
            AzureAuth.normalizeSASToken("https://a.blob.core.windows.net/c?sv=1&sig=x"),
            "sv=1&sig=x",
            "whole URL pasted into the token field"
        )
    }

    await h.suite("Azure connection strings")

    await h.test("account key form") {
        let key = Data("secret-key-bytes".utf8).base64EncodedString()
        let config = try AzureAuth.parseConnectionString(
            "DefaultEndpointsProtocol=https;AccountName=myacct;AccountKey=\(key);EndpointSuffix=core.windows.net"
        )
        await h.equal(config.accountName, "myacct", "account")
        await h.equal(
            config.blobEndpoint.absoluteString,
            "https://myacct.blob.core.windows.net",
            "derived endpoint"
        )
        await h.expect(config.credential.canMintSAS, "shared key can mint SAS")
    }

    await h.test("embedded SAS form") {
        let config = try AzureAuth.parseConnectionString(
            "BlobEndpoint=https://myacct.blob.core.windows.net;SharedAccessSignature=sv=2021-12-02&sig=abc"
        )
        await h.expect(!config.credential.canMintSAS, "SAS can't mint a narrower SAS")
        await h.equal(config.accountName, "myacct", "account from endpoint")
    }

    await h.test("keeps base64 padding in the account key") {
        // Splitting on every '=' would corrupt a padded key — a real bug class.
        let key = Data("abc".utf8).base64EncodedString()  // "YWJj" — no padding
        let padded = Data("ab".utf8).base64EncodedString()  // "YWI=" — padded
        await h.expect(padded.hasSuffix("="), "test input is actually padded")
        for candidate in [key, padded] {
            let config = try AzureAuth.parseConnectionString(
                "AccountName=a;AccountKey=\(candidate)"
            )
            await h.equal(config.accountName, "a", "account parsed with key \(candidate)")
        }
    }

    await h.test("rejects a string with neither key nor SAS") {
        await h.throwsError("no credential") {
            _ = try AzureAuth.parseConnectionString("AccountName=a;EndpointSuffix=x")
        }
        await h.throwsError("non-base64 key") {
            _ = try AzureAuth.parseConnectionString("AccountName=a;AccountKey=not!base64!")
        }
        await h.throwsError("gibberish") {
            _ = try AzureAuth.parseConnectionString("hello")
        }
    }

    await h.suite("Azure service SAS")

    await h.test("produces the documented parameter set") {
        let token = AzureAuth.serviceSAS(
            account: "acct",
            key: Data("key".utf8),
            container: "c",
            blob: "folder/file name.txt",
            permissions: "r",
            expires: Date(timeIntervalSince1970: 4_000_000_000)
        )
        for required in ["sv=", "sr=b", "sp=r", "se=", "sig=", "spr=https"] {
            await h.expect(token.contains(required), "token contains \(required): \(token)")
        }
        // The signature must be percent-encoded: base64 contains + and /.
        await h.expect(!token.contains("+"), "signature is encoded, not raw base64")
    }

    await h.test("a different blob gives a different signature") {
        let key = Data("key".utf8)
        let expires = Date(timeIntervalSince1970: 4_000_000_000)
        let first = AzureAuth.serviceSAS(
            account: "a", key: key, container: "c", blob: "one", expires: expires
        )
        let second = AzureAuth.serviceSAS(
            account: "a", key: key, container: "c", blob: "two", expires: expires
        )
        await h.expect(first != second, "signatures are blob-specific")
    }

    await h.suite("S3 addressing")

    await h.test("virtual-hosted style puts the bucket in the hostname") {
        let config = S3Config(
            endpoint: URL(string: "https://s3.eu-west-1.amazonaws.com")!,
            region: "eu-west-1",
            credentials: .init(accessKeyID: "k", secretAccessKey: "s", sessionToken: nil),
            usePathStyle: false,
            bucketScope: nil
        )
        let url = try config.url(bucket: "my-bucket", key: "a/b c.txt", query: [])
        await h.equal(
            url.absoluteString,
            "https://my-bucket.s3.eu-west-1.amazonaws.com/a/b%20c.txt",
            "virtual hosted"
        )
    }

    await h.test("path style keeps the bucket in the path and preserves the port") {
        let config = S3Config(
            endpoint: URL(string: "http://127.0.0.1:9000")!,
            region: "us-east-1",
            credentials: .init(accessKeyID: "k", secretAccessKey: "s", sessionToken: nil),
            usePathStyle: true,
            bucketScope: nil
        )
        let url = try config.url(bucket: "b", key: "k", query: [("list-type", "2")])
        await h.equal(url.absoluteString, "http://127.0.0.1:9000/b/k?list-type=2", "path style")
    }

    await h.test("a valueless query flag renders without an equals sign") {
        let config = S3Config(
            endpoint: URL(string: "http://h")!,
            region: "r",
            credentials: .init(accessKeyID: "k", secretAccessKey: "s", sessionToken: nil),
            usePathStyle: true,
            bucketScope: nil
        )
        // `?uploads` and `?delete` are flags; `?uploads=` is a different request.
        let url = try config.url(bucket: "b", key: "k", query: [("uploads", "")])
        await h.equal(url.absoluteString, "http://h/b/k?uploads", "bare flag")
    }

    await h.test("bucket-scoped config resolves paths inside the bucket") {
        let config = S3Config(
            endpoint: URL(string: "http://h")!,
            region: "r",
            credentials: .init(accessKeyID: "k", secretAccessKey: "s", sessionToken: nil),
            usePathStyle: true,
            bucketScope: "fixed"
        )
        let resolved = config.resolve(RemotePath("a/b.txt"))
        await h.equal(resolved.bucket, "fixed", "bucket")
        await h.equal(resolved.key, "a/b.txt", "key")
        await h.equal(config.path(bucket: "fixed", key: "a/b.txt").joined, "a/b.txt", "round trip")
    }

    await h.suite("Durability of saved connections")

    await h.test("a missing file and an unreadable one are different outcomes") {
        let directory = TestFiles.directory.appendingPathComponent("json-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let missing = directory.appendingPathComponent("absent.json")
        if case .missing = JSONFile.load([Connection].self, from: missing) {} else {
            await h.record("an absent file should read as .missing")
        }

        let corrupt = directory.appendingPathComponent("corrupt.json")
        try Data("{ this is not json".utf8).write(to: corrupt)
        switch JSONFile.load([Connection].self, from: corrupt) {
        case .corrupt(_, let backup):
            await h.notNil(backup, "a copy of the unreadable file is kept")
            if let backup {
                await h.expect(
                    FileManager.default.fileExists(atPath: backup.path),
                    "the backup is actually on disk"
                )
            }
        default:
            await h.record("an unreadable file must not read as .missing — that is what caused the data loss")
        }

        let good = directory.appendingPathComponent("good.json")
        try JSONFile.write([Connection(name: "x", kind: .azureBlob)], to: good)
        await h.equal(
            JSONFile.load([Connection].self, from: good).value?.count,
            1,
            "a valid file round-trips"
        )
    }

    await h.test("an empty file reads as missing, not as corrupt") {
        let directory = TestFiles.directory.appendingPathComponent("json-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let empty = directory.appendingPathComponent("empty.json")
        try Data().write(to: empty)
        if case .missing = JSONFile.load([Connection].self, from: empty) {} else {
            await h.record("a zero-byte file should be treated as absent")
        }
    }

    await h.suite("Signing regressions")

    await h.test("a trailing slash survives into the canonical path") {
        // `URL.path` drops a trailing slash, so an account- or bucket-level
        // request signed `/acct` while sending `/acct/`. Both services reject
        // that, and the only symptom is a bare 403.
        for raw in ["http://h/acct/", "http://h/bucket/", "http://h/a/b/"] {
            let url = URL(string: raw)!
            await h.expect(
                url.path(percentEncoded: false).hasSuffix("/"),
                "\(raw): the accessor used by both signers keeps the trailing slash"
            )
            await h.expect(
                !url.path.hasSuffix("/"),
                "\(raw): URL.path is still the broken accessor, so the guard above matters"
            )
        }
    }

    await h.test("a path-addressed account stays on the endpoint") {
        // Azurite and path-style gateways carry the account in the first path
        // segment; dropping it addresses /container instead of /account/container.
        let config = try AzureAuth.parseSASURL(
            "http://127.0.0.1:10000/devstoreaccount1/mycontainer?sv=2021-12-02&sig=x"
        )
        await h.equal(
            config.blobEndpoint.absoluteString,
            "http://127.0.0.1:10000/devstoreaccount1",
            "endpoint keeps the account segment"
        )
        await h.equal(config.accountName, "devstoreaccount1", "account")
        await h.equal(config.containerScope, "mycontainer", "container")
    }

    await h.test("a host-addressed account leaves the endpoint path empty") {
        let config = try AzureAuth.parseSASURL(
            "https://real.blob.core.windows.net/c?sv=1&sig=x"
        )
        await h.equal(
            config.blobEndpoint.absoluteString,
            "https://real.blob.core.windows.net",
            "no spurious path segment"
        )
    }

    await h.suite("XML parsing")

    await h.test("reads nested elements and strips namespace prefixes") {
        let xml = """
        <?xml version="1.0"?>
        <D:multistatus xmlns:D="DAV:">
          <D:response>
            <D:href>/dav/file.txt</D:href>
            <D:propstat><D:prop>
              <D:getcontentlength>1234</D:getcontentlength>
              <D:resourcetype/>
            </D:prop></D:propstat>
          </D:response>
        </D:multistatus>
        """
        let root = XMLLite.parse(xml)
        await h.notNil(root, "parsed")
        await h.equal(root?.name, "multistatus", "prefix stripped")
        let responses = root?.descendants(named: "response") ?? []
        await h.equal(responses.count, 1, "one response")
        await h.equal(responses.first?.string("href"), "/dav/file.txt", "href")
        let prop = responses.first?.firstDescendant(named: "prop")
        await h.equal(prop?.int64("getcontentlength"), 1234, "content length")
        await h.expect(prop?.child("resourcetype") != nil, "empty element present")
        await h.expect(
            prop?.child("resourcetype")?.child("collection") == nil,
            "not a collection"
        )
    }

    await h.test("decodes entities and CDATA") {
        let root = XMLLite.parse("<r><a>a &amp; b &lt;c&gt;</a><b><![CDATA[raw & text]]></b></r>")
        await h.equal(root?.string("a"), "a & b <c>", "entities")
        await h.equal(root?.string("b"), "raw & text", "cdata")
    }

    await h.test("returns nil for empty input and survives malformed input") {
        await h.expect(XMLLite.parse("") == nil, "empty is nil")
        // A truncated document should give back what it managed, not crash.
        _ = XMLLite.parse("<a><b>unclosed")
    }

    await h.test("descendants are returned in document order") {
        let root = XMLLite.parse("<r><k>1</k><g><k>2</k></g><k>3</k></r>")
        await h.equal(
            root?.descendants(named: "k").map(\.text),
            ["1", "2", "3"],
            "document order"
        )
    }

    await h.test("escapes text for request bodies") {
        await h.equal("a & b <c>".xmlEscaped, "a &amp; b &lt;c&gt;", "escaped")
    }

    await h.suite("Formatting")

    await h.test("byte sizes use decimal units like Finder") {
        await h.equal(ByteFormat.bytes(0), "0 bytes", "zero")
        await h.equal(ByteFormat.bytes(999), "999 bytes", "under 1 KB")
        await h.equal(ByteFormat.bytes(1000), "1.0 KB", "1 KB")
        await h.equal(ByteFormat.bytes(1_500_000), "1.5 MB", "MB")
        await h.equal(ByteFormat.bytes(nil), "—", "unknown")
    }

    await h.test("durations round to readable units") {
        await h.equal(ByteFormat.duration(0.4), "less than a second", "sub-second")
        await h.equal(ByteFormat.duration(45), "45 sec", "seconds")
        await h.equal(ByteFormat.duration(60), "1 min", "exact minute")
        await h.equal(ByteFormat.duration(nil), "—", "unknown")
        await h.equal(ByteFormat.duration(.infinity), "—", "infinite")
    }

    await h.test("content types come from the filename") {
        await h.equal(MIMEType.forFilename("a.png"), "image/png", "png")
        await h.equal(MIMEType.forFilename("a.json"), "application/json", "json")
        await h.equal(MIMEType.forFilename("a.md"), "text/markdown", "markdown override")
        await h.equal(MIMEType.forFilename("noext"), "application/octet-stream", "no extension")
    }

    await h.suite("HTTP date handling")

    await h.test("RFC 1123 round trips") {
        let date = Date(timeIntervalSince1970: 784_111_777)
        let text = HTTPDate.rfc1123(date)
        await h.equal(text, "Sun, 06 Nov 1994 08:49:37 GMT", "formatted")
        await h.equal(
            HTTPDate.parseRFC1123(text)?.timeIntervalSince1970,
            784_111_777,
            "parsed back"
        )
    }

    await h.test("SigV4 timestamp shapes") {
        let date = Date(timeIntervalSince1970: 1_440_938_160)  // 2015-08-30T12:36:00Z
        await h.equal(HTTPDate.iso8601Basic(date), "20150830T123600Z", "basic")
        await h.equal(HTTPDate.yyyymmdd(date), "20150830", "day")
    }

    await h.test("ISO 8601 parses with and without fractional seconds") {
        await h.notNil(HTTPDate.parseISO8601("2024-01-15T09:30:00Z"), "plain")
        await h.notNil(HTTPDate.parseISO8601("2024-01-15T09:30:00.123Z"), "fractional")
        await h.notNil(HTTPDate.parseISO8601("2024-01-15T09:30:00.0000000Z"), "azure 7-digit")
    }

    await h.suite("Error classification")

    await h.test("retryable and auth failures are distinguished") {
        await h.expect(StorageError.network("x").isRetryable, "network retryable")
        await h.expect(StorageError.http(status: 503, message: "").isRetryable, "503 retryable")
        await h.expect(StorageError.http(status: 429, message: "").isRetryable, "429 retryable")
        await h.expect(!StorageError.http(status: 404, message: "").isRetryable, "404 not retryable")
        await h.expect(!StorageError.notFound("x").isRetryable, "not found not retryable")
        await h.expect(StorageError.accessDenied("x").isAuthFailure, "denied is auth")
        await h.expect(StorageError.http(status: 403, message: "").isAuthFailure, "403 is auth")
        await h.expect(!StorageError.network("x").isAuthFailure, "network is not auth")
    }

    await h.suite("Local provider")

    await h.test("maps between URLs and paths") {
        var connection = Connection(name: "t", kind: .local)
        connection[.rootPath] = "/"
        let provider = LocalProvider(connection: connection)
        let url = provider.url(for: RemotePath("tmp/x.txt"))
        await h.equal(url.path, "/tmp/x.txt", "to URL")
        await h.equal(
            provider.path(for: URL(fileURLWithPath: "/tmp/x.txt"))?.joined,
            "tmp/x.txt",
            "from URL"
        )
    }

    await h.test("lists a real directory and pages through it") {
        let root = TestFiles.directory.appendingPathComponent("local-list", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for index in 0..<25 {
            try Data("x".utf8).write(to: root.appendingPathComponent("f\(index).txt"))
        }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("sub"), withIntermediateDirectories: true
        )

        var connection = Connection(name: "t", kind: .local)
        connection[.rootPath] = root.path
        let provider = LocalProvider(connection: connection)
        try await provider.validate()

        let first = try await provider.list(.root, cursor: nil, pageSize: 10)
        await h.equal(first.items.count, 10, "first page size")
        await h.notNil(first.nextCursor, "has a cursor")

        var total = 0
        for try await batch in provider.enumerate(.root, pageSize: 10) {
            total += batch.count
        }
        await h.equal(total, 26, "25 files plus 1 folder")
    }

    await h.test("reports a missing root as not found") {
        var connection = Connection(name: "t", kind: .local)
        connection[.rootPath] = "/nope/does/not/exist"
        let provider = LocalProvider(connection: connection)
        await h.throwsError("missing root") { try await provider.validate() }
    }

    await h.suite("Provider capabilities")

    await h.test("an unimplemented provider is reported, not offered") {
        for kind in ProviderKind.allCases where !kind.isImplemented {
            await h.throwsError("\(kind.rawValue) refuses construction") {
                _ = try ProviderFactory.make(
                    connection: Connection(name: "x", kind: kind),
                    secrets: ConnectionSecrets()
                )
            }
        }
    }

    await h.test("missing credentials produce an actionable message") {
        // Not a crash, and not a generic failure: the message must name the field.
        do {
            _ = try ProviderFactory.make(
                connection: Connection(name: "x", kind: .azureBlob),
                secrets: ConnectionSecrets()
            )
            await h.record("expected an error for an Azure connection with no credentials")
        } catch let error as StorageError {
            let message = error.errorDescription ?? ""
            await h.expect(
                message.lowercased().contains("sas"),
                "message mentions what's missing: \(message)"
            )
        }
    }
}
