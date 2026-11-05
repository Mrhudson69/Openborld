import Foundation

/// A small test harness.
///
/// XCTest ships with Xcode, which isn't installed here, and swift-testing
/// still wants an XCTest-shaped bundle on macOS. A plain executable has
/// neither problem, runs identically in CI, and can orchestrate the mock
/// server process directly.
actor Harness {
    struct Failure {
        var suite: String
        var test: String
        var message: String
    }

    private(set) var failures: [Failure] = []
    private(set) var passed = 0
    private(set) var skipped = 0
    private var currentSuite = ""
    private var currentTest = ""
    private var failedThisTest = false

    func suite(_ name: String) {
        currentSuite = name
        print("\n\u{001B}[1m\(name)\u{001B}[0m")
    }

    /// Runs one test, catching both assertion failures and thrown errors.
    func test(_ name: String, _ body: () async throws -> Void) async {
        currentTest = name
        failedThisTest = false
        let started = Date()
        do {
            try await body()
        } catch let error as SkipError {
            skipped += 1
            print("  \u{001B}[33m○\u{001B}[0m \(name) — skipped: \(error.reason)")
            return
        } catch {
            record("threw \(type(of: error)): \(describe(error))")
        }
        let elapsed = Date().timeIntervalSince(started)
        if failedThisTest {
            print("  \u{001B}[31m✗\u{001B}[0m \(name)")
        } else {
            passed += 1
            let timing = elapsed > 0.3 ? String(format: "  (%.2fs)", elapsed) : ""
            print("  \u{001B}[32m✓\u{001B}[0m \(name)\(timing)")
        }
    }

    func expect(_ condition: Bool, _ message: @autoclosure () -> String) {
        if !condition { record(message()) }
    }

    func equal<T: Equatable>(_ actual: T, _ expected: T, _ label: String) {
        if actual != expected {
            record("\(label): expected \(expected), got \(actual)")
        }
    }

    func notNil<T>(_ value: T?, _ label: String) {
        if value == nil { record("\(label): expected a value, got nil") }
    }

    /// Asserts a specific error is thrown. A test that expects a failure and
    /// silently gets success is worse than no test.
    func throwsError(
        _ label: String,
        _ body: () async throws -> Void
    ) async {
        do {
            try await body()
            record("\(label): expected an error, but it succeeded")
        } catch {
            // Expected.
        }
    }

    func record(_ message: String) {
        failedThisTest = true
        failures.append(Failure(suite: currentSuite, test: currentTest, message: message))
        print("      \u{001B}[31m→ \(message)\u{001B}[0m")
    }

    func summary() -> Bool {
        print("\n" + String(repeating: "─", count: 62))
        if failures.isEmpty {
            print("\u{001B}[32m\u{001B}[1m\(passed) passed\u{001B}[0m", terminator: "")
            if skipped > 0 { print(", \(skipped) skipped", terminator: "") }
            print("")
            return true
        }
        print("\u{001B}[31m\u{001B}[1m\(failures.count) failure(s)\u{001B}[0m, \(passed) passed")
        for failure in failures {
            print("\n  \(failure.suite) › \(failure.test)")
            for line in failure.message.split(separator: "\n", omittingEmptySubsequences: false) {
                print("    \(line)")
            }
        }
        return false
    }

    private func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? "\(error)"
    }
}

struct SkipError: Error {
    var reason: String
}

func skip(_ reason: String) -> SkipError {
    SkipError(reason: reason)
}
