import SwiftUI
import AppKit
import OpenborldCore

@main
struct OpenborldApp: App {
    @State private var model = AppModel()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup {
            MainWindow()
                .environment(model)
                // Publishes the system reduce-motion setting to every view, so
                // animations are opt-out at the source rather than per-site.
                .readsMotionPreference()
                // sidebar 210 + detail 420 + inspector 240, plus chrome.
                .frame(minWidth: 900, minHeight: 540)
                .task { model.start() }
                .onDisappear { model.willQuit() }
        }
        .defaultSize(width: 1180, height: 760)
        // The toolbar carries its own title and path, so the window chrome
        // stays out of the way.
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands { OpenborldCommands(model: model) }

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}

/// Keeps the app from quitting with transfers still running, and tidies the
/// scratch directory on launch.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        // Before anything reads settings: carry across data from the old name.
        LegacyMigration.runIfNeeded()

        // Offscreen render mode: capture the window to a PNG and exit before
        // any normal UI appears.
        if Snapshot.isRequested() {
            MainActor.assumeIsolated { Snapshot.run() }
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task.detached(priority: .background) {
            // Files staged for "Open" are disposable; clear last run's leftovers.
            let fm = FileManager.default
            if let contents = try? fm.contentsOfDirectory(
                at: AppPaths.scratch, includingPropertiesForKeys: nil
            ) {
                for url in contents { try? fm.removeItem(at: url) }
            }
        }
    }

    func applicationShouldTerminate(
        _ sender: NSApplication
    ) -> NSApplication.TerminateReply {
        let active = TransferManager.shared.activeCount
        guard active > 0 else { return .terminateNow }

        let alert = NSAlert()
        alert.messageText = active == 1
            ? "A transfer is still running."
            : "\(active) transfers are still running."
        alert.informativeText = "Quitting now will cancel them. Partially uploaded files may be left behind."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Cancel Transfers and Quit")
        alert.addButton(withTitle: "Keep Transferring")
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

struct OpenborldCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Connection…") { model.presentation = .addConnection }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            Button("New Folder") { model.presentation = .newFolder(model.activePane) }
                .keyboardShortcut("n", modifiers: [.command])
                .disabled(model.active.isAtContainerRoot)
        }

        CommandGroup(after: .newItem) {
            Divider()
            Button("Upload…") { model.chooseFilesToUpload(into: model.activePane) }
                .keyboardShortcut("u", modifiers: [.command])
            Button("Download") { model.downloadSelection(from: model.activePane) }
                .keyboardShortcut("d", modifiers: [.command, .shift])
                .disabled(model.active.selection.isEmpty)
        }

        CommandMenu("Go") {
            Button("Back") { model.active.goBack() }
                .keyboardShortcut("[", modifiers: [.command])
                .disabled(!model.active.canGoBack)
            Button("Forward") { model.active.goForward() }
                .keyboardShortcut("]", modifiers: [.command])
                .disabled(!model.active.canGoForward)
            Button("Enclosing Folder") { model.active.goUp() }
                .keyboardShortcut(.upArrow, modifiers: [.command])
                .disabled(!model.active.canGoUp)
            Divider()
            Button("Refresh") { model.active.refresh() }
                .keyboardShortcut("r", modifiers: [.command])
            Divider()
            Button("Transfers") { model.sidebarSelection = .transfers }
                .keyboardShortcut("t", modifiers: [.command, .shift])
            Button("Activity History") { model.sidebarSelection = .history }
        }

        CommandGroup(after: .sidebar) {
            Toggle("Dual Pane", isOn: Binding(
                get: { model.isDualPane },
                set: { model.isDualPane = $0 }
            ))
            .keyboardShortcut("2", modifiers: [.command, .option])

            Toggle("Inspector", isOn: Binding(
                get: { model.showInspector },
                set: { model.showInspector = $0 }
            ))
            .keyboardShortcut("i", modifiers: [.command, .option])

            Divider()

            Picker("View As", selection: Binding(
                get: { model.settings.viewMode },
                set: { model.settings.viewMode = $0 }
            )) {
                ForEach(ViewMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }

            Toggle("Show Hidden Files", isOn: Binding(
                get: { model.settings.showHiddenFiles },
                set: { model.settings.showHiddenFiles = $0; model.left.refresh(); model.right.refresh() }
            ))
            .keyboardShortcut(".", modifiers: [.command, .shift])
        }
    }
}
