import SwiftUI
import AppKit
import OpenborldCore

/// Renders the real window offscreen to a PNG.
///
/// Run as `Openborld --snapshot <path> [--width N] [--height N] [--inspector]
/// [--dual] [--dark]`. Hosting the view in an offscreen `NSWindow` and calling
/// `cacheDisplay` captures what AppKit actually lays out — including
/// `NavigationSplitView` column behaviour, which `ImageRenderer` does not
/// reproduce — and needs no screen-recording permission.
enum Snapshot {
    static func isRequested() -> Bool {
        CommandLine.arguments.contains("--snapshot")
    }

    @MainActor
    static func run() {
        let arguments = CommandLine.arguments
        guard let flagIndex = arguments.firstIndex(of: "--snapshot"),
              flagIndex + 1 < arguments.count
        else {
            FileHandle.standardError.write(Data("--snapshot needs an output path\n".utf8))
            exit(2)
        }

        let output = URL(fileURLWithPath: arguments[flagIndex + 1])
        let width = value(for: "--width", in: arguments) ?? 1100
        let height = value(for: "--height", in: arguments) ?? 720
        let wantsInspector = arguments.contains("--inspector")
        let wantsDual = arguments.contains("--dual")
        let dark = arguments.contains("--dark")

        let model = AppModel()
        model.showInspector = wantsInspector
        model.isDualPane = wantsDual
        // A selection makes the inspector show its populated state rather than
        // the folder summary.
        model.start()

        let root = MainWindow()
            .environment(model)
            .readsMotionPreference()
            .frame(width: CGFloat(width), height: CGFloat(height))

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.titled, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = NSHostingView(rootView: root)
        window.layoutIfNeeded()

        // Let the async folder listing land before capturing, so the snapshot
        // shows real rows rather than an empty pane.
        let deadline = Date().addingTimeInterval(2.5)
        while Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        window.layoutIfNeeded()
        window.displayIfNeeded()

        guard let view = window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)
        else {
            FileHandle.standardError.write(Data("couldn't create a bitmap\n".utf8))
            exit(3)
        }
        view.cacheDisplay(in: view.bounds, to: rep)

        guard let data = rep.representation(using: .png, properties: [:]) else {
            FileHandle.standardError.write(Data("couldn't encode PNG\n".utf8))
            exit(4)
        }
        do {
            try data.write(to: output)
            print("wrote \(output.path) (\(rep.pixelsWide)×\(rep.pixelsHigh))")
        } catch {
            FileHandle.standardError.write(Data("write failed: \(error)\n".utf8))
            exit(5)
        }
        exit(0)
    }

    private static func value(for flag: String, in arguments: [String]) -> Int? {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count
        else { return nil }
        return Int(arguments[index + 1])
    }
}
