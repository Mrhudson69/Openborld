import Foundation

public enum URIEncoding {
    /// Unreserved set from RFC 3986. Everything outside it gets percent-encoded.
    /// Used for AWS SigV4 canonical requests, where Foundation's own escaping is
    /// too permissive and produces signature mismatches.
    private static let unreserved: Set<UInt8> = {
        var set = Set<UInt8>()
        for byte in UInt8(ascii: "A")...UInt8(ascii: "Z") { set.insert(byte) }
        for byte in UInt8(ascii: "a")...UInt8(ascii: "z") { set.insert(byte) }
        for byte in UInt8(ascii: "0")...UInt8(ascii: "9") { set.insert(byte) }
        for char in "-._~" { set.insert(char.asciiValue!) }
        return set
    }()

    private static let hexDigits = Array("0123456789ABCDEF".utf8)

    /// Strict RFC 3986 encoding. With `encodeSlash: false`, `/` is left alone so
    /// a whole object key can be encoded in one pass.
    public static func encode(_ string: String, encodeSlash: Bool = true) -> String {
        var out = [UInt8]()
        out.reserveCapacity(string.utf8.count + 8)
        for byte in string.utf8 {
            if unreserved.contains(byte) {
                out.append(byte)
            } else if byte == UInt8(ascii: "/"), !encodeSlash {
                out.append(byte)
            } else {
                out.append(UInt8(ascii: "%"))
                out.append(hexDigits[Int(byte >> 4)])
                out.append(hexDigits[Int(byte & 0x0F)])
            }
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// Builds a canonical query string: percent-encoded, sorted by key. Both
    /// SigV4 and Azure SAS depend on a deterministic ordering here.
    public static func canonicalQuery(_ items: [(String, String)]) -> String {
        var encoded: [(name: String, value: String)] = []
        encoded.reserveCapacity(items.count)
        for item in items {
            encoded.append((name: encode(item.0), value: encode(item.1)))
        }
        encoded.sort { left, right in
            left.name == right.name ? left.value < right.value : left.name < right.name
        }
        var parts: [String] = []
        parts.reserveCapacity(encoded.count)
        for item in encoded {
            parts.append(item.name + "=" + item.value)
        }
        return parts.joined(separator: "&")
    }
}

public extension String {
    /// Encoded for use as one path segment of a URL.
    var pathSegmentEncoded: String { URIEncoding.encode(self, encodeSlash: true) }

    /// Encoded as a multi-segment object key, keeping the separators.
    var objectKeyEncoded: String { URIEncoding.encode(self, encodeSlash: false) }
}

// MARK: - Dates

public enum HTTPDate {
    /// `Sun, 06 Nov 1994 08:49:37 GMT` — required by Azure's SharedKey signing.
    public static func rfc1123(_ date: Date) -> String {
        rfc1123Formatter.string(from: date)
    }

    public static func parseRFC1123(_ string: String) -> Date? {
        rfc1123Formatter.date(from: string)
    }

    /// `20240115T093000Z` and `20240115` — the two shapes SigV4 needs.
    public static func iso8601Basic(_ date: Date) -> String {
        basicFormatter.string(from: date)
    }

    public static func yyyymmdd(_ date: Date) -> String {
        dayFormatter.string(from: date)
    }

    /// `2024-01-15T09:30:00Z` — Azure SAS expiry and many JSON APIs.
    public static func iso8601(_ date: Date) -> String {
        isoFormatter.string(from: date)
    }

    /// Parses the handful of ISO 8601 shapes providers actually emit, with or
    /// without fractional seconds.
    public static func parseISO8601(_ string: String) -> Date? {
        if let date = isoFractionalParser.date(from: string) { return date }
        if let date = isoFormatter.date(from: string) { return date }
        return isoLenientParser.date(from: string)
    }

    private static let rfc1123Formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return formatter
    }()

    private static let basicFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter
    }()

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd"
        return formatter
    }()

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }()

    private static let isoFractionalParser: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }()

    private static let isoLenientParser: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSSSZZZZZ"
        return formatter
    }()
}

// MARK: - Hashing helpers

public extension Data {
    var hexString: String {
        var out = ""
        out.reserveCapacity(count * 2)
        let digits = Array("0123456789abcdef")
        for byte in self {
            out.append(digits[Int(byte >> 4)])
            out.append(digits[Int(byte & 0x0F)])
        }
        return out
    }
}
