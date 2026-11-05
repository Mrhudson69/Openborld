import SwiftUI
import AppKit
import OpenborldCore

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
            TransferSettings()
                .tabItem { Label("Transfers", systemImage: "arrow.up.arrow.down") }
            CacheSettings()
                .tabItem { Label("Cache", systemImage: "internaldrive") }
        }
        .environment(model)
        .frame(width: 480, height: 330)
    }
}

private struct GeneralSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Picker("Default view", selection: Binding(
                get: { model.settings.viewMode },
                set: { model.settings.viewMode = $0 }
            )) {
                ForEach([ViewMode.list, .grid]) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }

            Picker("Sort by", selection: Binding(
                get: { model.settings.sortField },
                set: { model.settings.sortField = $0 }
            )) {
                ForEach(SortField.allCases) { field in
                    Text(field.displayName).tag(field)
                }
            }

            Toggle("Folders before files", isOn: Binding(
                get: { model.settings.foldersFirst },
                set: { model.settings.foldersFirst = $0; refresh() }
            ))

            Toggle("Show hidden files", isOn: Binding(
                get: { model.settings.showHiddenFiles },
                set: { model.settings.showHiddenFiles = $0; refresh() }
            ))

            Toggle("Confirm before deleting", isOn: Binding(
                get: { model.settings.confirmDeletes },
                set: { model.settings.confirmDeletes = $0 }
            ))
        }
        .formStyle(.grouped)
    }

    private func refresh() {
        model.left.refresh()
        model.right.refresh()
    }
}

private struct TransferSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Section {
                Stepper(
                    value: Binding(
                        get: { model.settings.maxConcurrentTransfers },
                        set: {
                            model.settings.maxConcurrentTransfers = $0
                            model.transfers.maxConcurrent = $0
                        }
                    ),
                    in: 1...32
                ) {
                    HStack {
                        Text("Simultaneous transfers")
                        Spacer()
                        Text("\(model.settings.maxConcurrentTransfers)")
                            .monospacedDigit()
                            .foregroundStyle(Theme.Ink.secondary)
                    }
                }
            } footer: {
                Text("Past a handful, extra transfers mostly split the same bandwidth while using more memory.")
                    .font(Theme.Typo.micro)
                    .foregroundStyle(Theme.Ink.secondary)
            }

            Picker("When a file already exists", selection: Binding(
                get: { model.settings.conflictPolicy },
                set: {
                    model.settings.conflictPolicy = $0
                    model.transfers.conflictPolicy = $0
                }
            )) {
                ForEach(ConflictPolicy.allCases) { policy in
                    Text(policy.displayName).tag(policy)
                }
            }

            Section {
                HStack {
                    Text("Download folder")
                    Spacer()
                    Text(model.settings.downloadFolder.lastPathComponent)
                        .foregroundStyle(Theme.Ink.secondary)
                        .lineLimit(1)
                    Button("Choose…") { chooseFolder() }
                        .controlSize(.small)
                }
            } footer: {
                Text(model.settings.downloadFolder.path)
                    .font(Theme.Typo.micro)
                    .foregroundStyle(Theme.Ink.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .formStyle(.grouped)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = model.settings.downloadFolder
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            model.settings.downloadFolderPath = url.path
        }
    }
}

private struct CacheSettings: View {
    @Environment(AppModel.self) private var model
    @State private var cacheSize: Int64 = 0

    var body: some View {
        Form {
            Section {
                Toggle("Show cached listings while refreshing", isOn: Binding(
                    get: { model.settings.useCachedListings },
                    set: { model.settings.useCachedListings = $0 }
                ))
            } footer: {
                Text("A revisited folder appears immediately from the cache, then updates as the live listing arrives. Turn this off to always wait for fresh data.")
                    .font(Theme.Typo.micro)
                    .foregroundStyle(Theme.Ink.secondary)
            }

            Section {
                Stepper(
                    value: Binding(
                        get: { model.settings.pageSize },
                        set: { model.settings.pageSize = $0 }
                    ),
                    in: 100...5000,
                    step: 100
                ) {
                    HStack {
                        Text("Items per request")
                        Spacer()
                        Text("\(model.settings.pageSize)")
                            .monospacedDigit()
                            .foregroundStyle(Theme.Ink.secondary)
                    }
                }
            } footer: {
                Text("How many entries each listing request asks for. Larger pages mean fewer round trips in big folders.")
                    .font(Theme.Typo.micro)
                    .foregroundStyle(Theme.Ink.secondary)
            }

            Section {
                HStack {
                    Text("Listing cache")
                    Spacer()
                    Text(ByteFormat.bytes(cacheSize))
                        .foregroundStyle(Theme.Ink.secondary)
                        .monospacedDigit()
                    Button("Clear") {
                        Task {
                            await ListingCache.shared.clearAll()
                            await refreshSize()
                            model.left.refresh()
                            model.right.refresh()
                        }
                    }
                    .controlSize(.small)
                }
            }
        }
        .formStyle(.grouped)
        .task { await refreshSize() }
    }

    private func refreshSize() async {
        cacheSize = await ListingCache.shared.diskSize()
    }
}
