import Foundation

#if canImport(FoundationXML)
// XMLParser is in FoundationXML on non-Apple platforms.
import FoundationXML
#endif

/// A tiny read-only XML tree, built on `XMLParser`.
///
/// S3, Azure, and WebDAV all answer in XML. `XMLDocument` would do the job but
/// pulls in a heavier parse and keeps more alive than we need for a listing that
/// gets thrown away immediately; this builds plain structs and nothing else.
public final class XMLLite {
    public final class Node {
        public let name: String
        public private(set) var attributes: [String: String]
        public private(set) var children: [Node] = []
        public private(set) var rawText: String = ""
        public weak var parent: Node?

        init(name: String, attributes: [String: String]) {
            // WebDAV namespaces every element (`D:response`); callers shouldn't
            // have to care which prefix a particular server picked.
            self.name = name.contains(":") ? String(name.split(separator: ":").last!) : name
            self.attributes = attributes
        }

        func append(_ child: Node) {
            child.parent = self
            children.append(child)
        }

        func appendText(_ text: String) { rawText += text }

        /// Trimmed element text.
        public var text: String {
            rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        public var isEmpty: Bool { text.isEmpty && children.isEmpty }

        /// Direct children with the given name.
        public func children(named name: String) -> [Node] {
            children.filter { $0.name == name }
        }

        /// First direct child with the given name.
        public func child(_ name: String) -> Node? {
            children.first { $0.name == name }
        }

        /// Text of a direct child, nil when absent or blank.
        public func string(_ name: String) -> String? {
            guard let value = child(name)?.text, !value.isEmpty else { return nil }
            return value
        }

        public func int64(_ name: String) -> Int64? {
            string(name).flatMap { Int64($0) }
        }

        public func bool(_ name: String) -> Bool? {
            guard let value = string(name)?.lowercased() else { return nil }
            return value == "true" || value == "1"
        }

        /// Walks a chain of child names: `node.path("Properties", "Content-Length")`.
        public func path(_ names: String...) -> Node? {
            var current: Node? = self
            for name in names { current = current?.child(name) }
            return current
        }

        /// Breadth-first search for the first descendant with this name.
        public func firstDescendant(named name: String) -> Node? {
            var queue = children
            while !queue.isEmpty {
                let node = queue.removeFirst()
                if node.name == name { return node }
                queue.append(contentsOf: node.children)
            }
            return name == self.name ? self : nil
        }

        /// Every descendant with this name, in document order.
        public func descendants(named name: String) -> [Node] {
            var out: [Node] = []
            var stack = children.reversed().map { $0 }
            while let node = stack.popLast() {
                if node.name == name { out.append(node) }
                stack.append(contentsOf: node.children.reversed())
            }
            return out
        }
    }

    public static func parse(_ string: String) -> Node? {
        guard let data = string.data(using: .utf8) else { return nil }
        return parse(data)
    }

    public static func parse(_ data: Data) -> Node? {
        guard !data.isEmpty else { return nil }
        let builder = Builder()
        let parser = XMLParser(data: data)
        parser.delegate = builder
        parser.shouldProcessNamespaces = false
        guard parser.parse() else { return builder.root }
        return builder.root
    }

    private final class Builder: NSObject, XMLParserDelegate {
        var root: Node?
        private var stack: [Node] = []

        func parser(
            _ parser: XMLParser,
            didStartElement elementName: String,
            namespaceURI: String?,
            qualifiedName: String?,
            attributes: [String: String] = [:]
        ) {
            let node = Node(name: elementName, attributes: attributes)
            if let current = stack.last {
                current.append(node)
            } else {
                root = node
            }
            stack.append(node)
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            stack.last?.appendText(string)
        }

        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            if let text = String(data: CDATABlock, encoding: .utf8) {
                stack.last?.appendText(text)
            }
        }

        func parser(
            _ parser: XMLParser,
            didEndElement elementName: String,
            namespaceURI: String?,
            qualifiedName: String?
        ) {
            if !stack.isEmpty { stack.removeLast() }
        }
    }
}

// MARK: - Escaping for request bodies

public extension String {
    /// Escapes text for inclusion in an XML element or attribute.
    var xmlEscaped: String {
        var out = ""
        out.reserveCapacity(count)
        for char in self {
            switch char {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&apos;"
            default: out.append(char)
            }
        }
        return out
    }
}
