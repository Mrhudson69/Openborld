import Foundation

#if canImport(FoundationNetworking)
// On Linux and Windows, Foundation is split and the URL loading system lives
// in its own module.
import FoundationNetworking
#endif

/// A value behind a lock.
///
/// `NSLock.lock()` is unavailable from async contexts for good reason, but the
/// `URLSession` delegate callbacks that feed our byte sinks are synchronous and
/// arrive on arbitrary threads, so a plain mutex is the right tool. Going
/// through `withLock` keeps the critical section non-suspending by construction.
public final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    public init(_ value: Value) {
        self.value = value
    }

    public func read<T>(_ body: (Value) throws -> T) rethrows -> T {
        try lock.withLock { try body(value) }
    }

    @discardableResult
    public func write<T>(_ body: (inout Value) throws -> T) rethrows -> T {
        try lock.withLock { try body(&value) }
    }

    public var current: Value {
        lock.withLock { value }
    }

    public func set(_ newValue: Value) {
        lock.withLock { value = newValue }
    }
}
