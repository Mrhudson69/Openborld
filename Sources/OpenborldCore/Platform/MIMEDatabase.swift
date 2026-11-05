import Foundation

#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif

public enum MIMEType {
    /// Best-guess content type for a filename.
    ///
    /// Worth getting right: it decides whether a browser opening a shared link
    /// renders the file or downloads it. The built-in table is consulted first
    /// so every platform agrees on the common cases; on Apple platforms the
    /// system database then covers the long tail.
    public static func forFilename(_ name: String) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        guard !ext.isEmpty else { return "application/octet-stream" }
        if let known = table[ext] { return known }

        #if canImport(UniformTypeIdentifiers)
        if let type = UTType(filenameExtension: ext), let mime = type.preferredMIMEType {
            return mime
        }
        #endif

        return "application/octet-stream"
    }

    /// Whether the app can show this inline rather than requiring a download.
    public static func isPreviewable(_ name: String) -> Bool {
        let type = forFilename(name)
        if type.hasPrefix("image/") || type.hasPrefix("text/")
            || type.hasPrefix("video/") || type.hasPrefix("audio/") { return true }
        return ["application/pdf", "application/json", "application/yaml", "application/xml"]
            .contains(type)
    }

    /// Extension to media type. Deliberately explicit rather than delegating
    /// to the OS: an object uploaded from Linux and one uploaded from macOS
    /// must end up with the same Content-Type, or the same file behaves
    /// differently depending on who uploaded it.
    static let table: [String: String] = [
        // Text and code
        "txt": "text/plain", "log": "text/plain", "md": "text/markdown",
        "csv": "text/csv", "tsv": "text/tab-separated-values",
        "html": "text/html", "htm": "text/html", "css": "text/css",
        "js": "text/javascript", "mjs": "text/javascript",
        "json": "application/json", "jsonl": "application/x-ndjson",
        "xml": "application/xml", "yaml": "application/yaml", "yml": "application/yaml",
        "toml": "application/toml", "ini": "text/plain", "conf": "text/plain",
        "env": "text/plain", "sh": "application/x-sh", "bash": "application/x-sh",
        "zsh": "application/x-sh", "bat": "text/plain", "ps1": "text/plain",
        "py": "text/x-python", "rb": "text/x-ruby", "go": "text/x-go",
        "rs": "text/rust", "java": "text/x-java-source", "kt": "text/x-kotlin",
        "c": "text/x-c", "h": "text/x-c", "cpp": "text/x-c++", "hpp": "text/x-c++",
        "cs": "text/plain", "php": "application/x-httpd-php", "sql": "application/sql",
        "swift": "text/plain", "ts": "text/plain", "tsx": "text/plain",
        "jsx": "text/plain", "vue": "text/plain", "rst": "text/plain",

        // Images
        "png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg",
        "gif": "image/gif", "webp": "image/webp", "avif": "image/avif",
        "bmp": "image/bmp", "ico": "image/vnd.microsoft.icon",
        "tif": "image/tiff", "tiff": "image/tiff", "svg": "image/svg+xml",
        "heic": "image/heic", "heif": "image/heif", "psd": "image/vnd.adobe.photoshop",

        // Audio and video
        "mp3": "audio/mpeg", "wav": "audio/wav", "flac": "audio/flac",
        "aac": "audio/aac", "m4a": "audio/mp4", "ogg": "audio/ogg",
        "oga": "audio/ogg", "opus": "audio/opus", "aiff": "audio/aiff",
        "mp4": "video/mp4", "m4v": "video/x-m4v", "mov": "video/quicktime",
        "avi": "video/x-msvideo", "mkv": "video/x-matroska", "webm": "video/webm",
        "mpg": "video/mpeg", "mpeg": "video/mpeg", "wmv": "video/x-ms-wmv",

        // Documents
        "pdf": "application/pdf", "rtf": "application/rtf",
        "doc": "application/msword",
        "docx": "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
        "xls": "application/vnd.ms-excel",
        "xlsx": "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
        "ppt": "application/vnd.ms-powerpoint",
        "pptx": "application/vnd.openxmlformats-officedocument.presentationml.presentation",
        "odt": "application/vnd.oasis.opendocument.text",
        "ods": "application/vnd.oasis.opendocument.spreadsheet",
        "odp": "application/vnd.oasis.opendocument.presentation",
        "epub": "application/epub+zip",

        // Archives and images of disks
        "zip": "application/zip", "gz": "application/gzip", "tgz": "application/gzip",
        "bz2": "application/x-bzip2", "xz": "application/x-xz",
        "zst": "application/zstd", "tar": "application/x-tar",
        "7z": "application/x-7z-compressed", "rar": "application/vnd.rar",
        "iso": "application/x-iso9660-image", "dmg": "application/x-apple-diskimage",
        "pkg": "application/octet-stream", "deb": "application/vnd.debian.binary-package",
        "rpm": "application/x-rpm", "msi": "application/x-msdownload",
        "exe": "application/vnd.microsoft.portable-executable",

        // Data engineering
        "parquet": "application/vnd.apache.parquet", "avro": "application/avro",
        "orc": "application/x-orc", "ndjson": "application/x-ndjson",
        "db": "application/vnd.sqlite3", "sqlite": "application/vnd.sqlite3",
        "sqlite3": "application/vnd.sqlite3",

        // Fonts and web
        "woff": "font/woff", "woff2": "font/woff2",
        "ttf": "font/ttf", "otf": "font/otf",
        "wasm": "application/wasm", "webmanifest": "application/manifest+json",

        // Keys and certificates
        "pem": "application/x-pem-file", "crt": "application/x-x509-ca-cert",
        "cer": "application/x-x509-ca-cert", "key": "application/x-pem-file",
    ]
}
