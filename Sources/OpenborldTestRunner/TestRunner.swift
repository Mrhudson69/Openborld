import Foundation
import OpenborldCore

/// Entry point for `swift run openborld-tests`.
///
/// Unit suites run always. The provider integration suites need the mock cloud
/// server, so they're skipped with an explicit message when Python or the
/// script is unavailable rather than silently passing.
@main
struct TestRunner {
    static func main() async {
        let harness = Harness()
        let started = Date()

        print("\u{001B}[1mOpenborld test suite\u{001B}[0m")

        await runUnitTests(harness)

        let scriptPath = locateMockServer()

        if CommandLine.arguments.contains("--diagnose"), let scriptPath {
            await diagnoseSignatures(scriptPath: scriptPath)
            exit(0)
        }

        if let scriptPath {
            await runProviderTests(harness, scriptPath: scriptPath)
        } else {
            await harness.suite("Provider integration")
            await harness.test("mock cloud server") {
                throw skip("Tests/Support/mock_cloud.py not found relative to the package root")
            }
        }

        TestFiles.cleanup()

        let elapsed = Date().timeIntervalSince(started)
        let ok = await harness.summary()
        print(String(format: "Finished in %.2fs", elapsed))
        exit(ok ? 0 : 1)
    }

    /// Walks up from the executable to find the package root, so the runner
    /// works from `swift run` and from a built binary alike.
    private static func locateMockServer() -> URL? {
        let relative = "Tests/Support/mock_cloud.py"

        var candidates: [URL] = [
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent(relative)
        ]

        var directory = URL(fileURLWithPath: CommandLine.arguments[0])
            .resolvingSymlinksInPath()
            .deletingLastPathComponent()
        for _ in 0..<6 {
            candidates.append(directory.appendingPathComponent(relative))
            directory = directory.deletingLastPathComponent()
        }

        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }
}
