import Foundation

/// A provider-agnostic location inside a connection.
///
/// `components` is always relative to the connection's root. For object storage
/// mounted at account scope the first component is the container/bucket; for a
/// connection scoped directly to one container (an Azure SAS container URL, say)
/// the components are just the key path. Providers decide how to interpret this,
/// which keeps the UI layer free of per-provider path rules.
public struct RemotePath: Hashable, Sendable, Codable {
    public var components: [String]

    public init(components: [String] = []) {
        self.components = components.filter { !$0.isEmpty }
    }

    public init(_ string: String) {
        self.components = string.split(separator: "/").map(String.init).filter { !$0.isEmpty }
    }

    public static let root = RemotePath()

    public var isRoot: Bool { components.isEmpty }
    public var depth: Int { components.count }
    public var name: String { components.last ?? "" }

    /// Slash-joined path with no leading slash, e.g. `container/folder/sub`.
    public var joined: String { components.joined(separator: "/") }

    /// Slash-joined with a trailing slash, the usual shape of an object-storage prefix.
    /// Empty (not "/") at the root so it can be used directly as a list prefix.
    public var prefix: String { components.isEmpty ? "" : joined + "/" }

    public var parent: RemotePath {
        guard !components.isEmpty else { return self }
        return RemotePath(components: components.dropLast())
    }

    public func appending(_ component: String) -> RemotePath {
        RemotePath(components: components + [component])
    }

    public func appending(path: RemotePath) -> RemotePath {
        RemotePath(components: components + path.components)
    }

    /// Drops the first component — how an account-scoped object path becomes a
    /// container-relative key.
    public var droppingFirst: RemotePath {
        guard !components.isEmpty else { return self }
        return RemotePath(components: Array(components.dropFirst()))
    }

    public var first: String? { components.first }

    public func isAncestor(of other: RemotePath) -> Bool {
        guard components.count < other.components.count else { return false }
        return Array(other.components.prefix(components.count)) == components
    }

    /// Path of `other` relative to `self`, or nil when `self` is not an ancestor.
    public func relative(_ other: RemotePath) -> RemotePath? {
        guard components.count <= other.components.count,
              Array(other.components.prefix(components.count)) == components
        else { return nil }
        return RemotePath(components: Array(other.components.dropFirst(components.count)))
    }
}

extension RemotePath: CustomStringConvertible {
    public var description: String { "/" + joined }
}
