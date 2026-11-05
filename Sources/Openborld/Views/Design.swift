import SwiftUI
import OpenborldCore

/// Column widths shared by the list header and its rows, so the two can't
/// drift out of alignment.
enum Design {
    static let sizeColumn: CGFloat = 92
    static let dateColumn: CGFloat = 150
    static let kindColumn: CGFloat = 92

    static let gridItemWidth: CGFloat = 108
    static let gridIconSize: CGFloat = 46
}

extension ProviderKind {
    /// A stable tint per provider, so a glance at the sidebar distinguishes
    /// Azure from S3 without reading the label.
    ///
    /// Each has a lighter dark-mode variant: a mid-tone brand blue that clears
    /// 4.5:1 on white falls well under it on a dark surface, and the tint is
    /// carrying identity, so it has to stay legible in both.
    var tint: Color {
        switch self {
        case .local:
            return Theme.Ink.secondary
        case .azureBlob:
            return .adaptive(light: (0.00, 0.40, 0.72), dark: (0.36, 0.71, 1.00))
        case .s3, .s3Compatible:
            return .adaptive(light: (0.76, 0.37, 0.03), dark: (0.98, 0.66, 0.28))
        case .gcs:
            return .adaptive(light: (0.16, 0.39, 0.84), dark: (0.47, 0.69, 1.00))
        case .backblazeB2:
            return .adaptive(light: (0.75, 0.14, 0.12), dark: (1.00, 0.49, 0.45))
        case .openStackSwift:
            return .adaptive(light: (0.72, 0.20, 0.10), dark: (0.98, 0.54, 0.40))
        case .googleDrive:
            return .adaptive(light: (0.07, 0.44, 0.76), dark: (0.40, 0.73, 1.00))
        case .dropbox:
            return .adaptive(light: (0.00, 0.33, 0.80), dark: (0.42, 0.67, 1.00))
        case .oneDrive, .sharePoint:
            return .adaptive(light: (0.00, 0.37, 0.60), dark: (0.36, 0.72, 0.95))
        case .box:
            return .adaptive(light: (0.00, 0.31, 0.66), dark: (0.40, 0.68, 1.00))
        case .nextcloud:
            return .adaptive(light: (0.00, 0.41, 0.64), dark: (0.33, 0.74, 0.98))
        case .ownCloud:
            return .adaptive(light: (0.11, 0.39, 0.66), dark: (0.42, 0.71, 0.98))
        case .dracoon:
            return .adaptive(light: (0.37, 0.21, 0.62), dark: (0.72, 0.58, 0.98))
        case .filesCom:
            return .adaptive(light: (0.10, 0.47, 0.35), dark: (0.40, 0.84, 0.66))
        case .ftp, .ftps:
            return .adaptive(light: (0.37, 0.37, 0.42), dark: (0.70, 0.71, 0.76))
        case .sftp:
            return .adaptive(light: (0.18, 0.45, 0.25), dark: (0.50, 0.84, 0.58))
        case .webdav:
            return .adaptive(light: (0.30, 0.34, 0.48), dark: (0.66, 0.71, 0.88))
        case .smb:
            return .adaptive(light: (0.27, 0.32, 0.53), dark: (0.63, 0.69, 0.93))
        }
    }
}

extension ConnectionStatus {
    var label: String {
        switch self {
        case .idle: "Not connected"
        case .connecting: "Connecting…"
        case .connected: "Connected"
        case .failed(let message): message
        }
    }
}

extension CloudItem {
    /// SF Symbol for a row, chosen by extension so a listing reads at a glance.
    /// One family, one weight — mixing filled and outline glyphs at the same
    /// level reads as inconsistency rather than meaning.
    var symbol: String {
        switch kind {
        case .container: "cube.box"
        case .folder: "folder"
        case .file: Self.symbol(forExtension: fileExtension)
        }
    }

    private static func symbol(forExtension ext: String?) -> String {
        guard let ext else { return "doc" }
        switch ext {
        case "jpg", "jpeg", "png", "gif", "heic", "heif", "webp", "bmp", "tiff", "svg", "ico":
            return "photo"
        case "mp4", "mov", "avi", "mkv", "webm", "m4v", "mpg", "mpeg", "wmv":
            return "film"
        case "mp3", "wav", "aac", "flac", "m4a", "ogg", "aiff":
            return "music.note"
        case "pdf":
            return "doc.richtext"
        case "zip", "tar", "gz", "bz2", "xz", "7z", "rar", "tgz", "zst":
            return "doc.zipper"
        case "doc", "docx", "odt", "rtf", "pages":
            return "doc.text"
        case "xls", "xlsx", "ods", "csv", "tsv", "numbers", "parquet":
            return "tablecells"
        case "ppt", "pptx", "odp", "key":
            return "rectangle.on.rectangle"
        case "txt", "md", "log", "rst":
            return "doc.plaintext"
        case "json", "yaml", "yml", "xml", "toml", "plist", "ini", "conf":
            return "curlybraces"
        case "swift", "py", "js", "ts", "tsx", "jsx", "rb", "go", "rs", "java",
             "c", "cpp", "h", "hpp", "cs", "php", "sh", "bash", "zsh", "sql":
            return "chevron.left.forwardslash.chevron.right"
        case "dmg", "pkg", "app", "iso", "vmdk", "qcow2":
            return "shippingbox"
        case "ttf", "otf", "woff", "woff2":
            return "textformat"
        case "db", "sqlite", "sqlite3", "mdb":
            return "cylinder.split.1x2"
        case "bak", "backup", "snapshot":
            return "clock.arrow.circlepath"
        default:
            return "doc"
        }
    }

    /// File-type tints, kept desaturated enough to read on either surface. The
    /// glyph already distinguishes the type; colour only reinforces it.
    var symbolColor: Color {
        switch kind {
        case .container:
            return .adaptive(light: (0.31, 0.25, 0.64), dark: (0.68, 0.63, 0.99))
        case .folder:
            // Folder blue, file amber — the convention a file manager inherits.
            return .adaptive(light: (0.17, 0.45, 0.80), dark: (0.46, 0.70, 1.00))
        case .file:
            switch fileExtension {
            case "jpg", "jpeg", "png", "gif", "heic", "heif", "webp", "bmp", "tiff", "svg":
                return .adaptive(light: (0.50, 0.23, 0.63), dark: (0.80, 0.60, 0.95))
            case "mp4", "mov", "avi", "mkv", "webm", "m4v":
                return .adaptive(light: (0.68, 0.18, 0.44), dark: (0.96, 0.56, 0.76))
            case "mp3", "wav", "aac", "flac", "m4a", "ogg":
                return .adaptive(light: (0.72, 0.38, 0.04), dark: (0.97, 0.69, 0.33))
            case "pdf":
                return .adaptive(light: (0.72, 0.13, 0.13), dark: (0.99, 0.52, 0.49))
            case "zip", "tar", "gz", "bz2", "xz", "7z", "rar", "tgz":
                return .adaptive(light: (0.45, 0.31, 0.18), dark: (0.84, 0.69, 0.52))
            case "xls", "xlsx", "csv", "tsv", "numbers", "parquet":
                return .adaptive(light: (0.08, 0.45, 0.24), dark: (0.42, 0.83, 0.55))
            case "swift", "py", "js", "ts", "tsx", "jsx", "rb", "go", "rs",
                 "java", "c", "cpp", "h", "cs", "php", "sh", "sql":
                return .adaptive(light: (0.04, 0.42, 0.47), dark: (0.40, 0.82, 0.88))
            case "json", "yaml", "yml", "xml", "toml", "plist":
                return .adaptive(light: (0.29, 0.28, 0.66), dark: (0.66, 0.65, 0.99))
            default:
                return Theme.Ink.secondary
            }
        }
    }

    /// Human-readable kind for the list's Kind column.
    var kindLabel: String {
        switch kind {
        case .container: "Container"
        case .folder: "Folder"
        case .file: fileExtension?.uppercased() ?? "File"
        }
    }
}

extension Transfer.Status {
    var tint: Color {
        switch self {
        case .queued: Theme.Ink.secondary
        case .running: Color.accentColor
        case .paused: Theme.Status.warning
        case .completed: Theme.Status.success
        case .failed: Theme.Status.danger
        case .cancelled: Theme.Ink.secondary
        case .skipped: Theme.Ink.secondary
        }
    }

    /// Each state has its own glyph, so the queue is readable without relying
    /// on the colour difference between, say, completed and failed.
    var symbol: String {
        switch self {
        case .queued: "clock"
        case .running: "arrow.triangle.2.circlepath"
        case .paused: "pause.circle"
        case .completed: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .cancelled: "xmark.circle"
        case .skipped: "arrow.turn.down.right"
        }
    }
}

extension AppModel.Banner.Level {
    var tint: Color {
        switch self {
        case .info: Color.accentColor
        case .success: Theme.Status.success
        case .warning: Theme.Status.warning
        case .error: Theme.Status.danger
        }
    }

    var symbol: String {
        switch self {
        case .info: "info.circle.fill"
        case .success: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "xmark.octagon.fill"
        }
    }

    /// Prefixed to the message for screen readers, since the icon and tint that
    /// convey severity visually aren't announced.
    var spokenPrefix: String {
        switch self {
        case .info: "Information"
        case .success: "Success"
        case .warning: "Warning"
        case .error: "Error"
        }
    }
}
