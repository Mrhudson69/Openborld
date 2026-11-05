import SwiftUI
import OpenborldCore

/// Side panel describing the current selection, or the folder when nothing is
/// selected. Loads detail lazily so opening it never slows browsing.
struct InspectorView: View {
    @Environment(AppModel.self) private var model

    private var browser: BrowserModel { model.active }
    private var selected: [CloudItem] { browser.selectedItems }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if selected.count == 1, let item = selected.first {
                    single(item)
                } else if selected.count > 1 {
                    multiple
                } else {
                    folder
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func single(_ item: CloudItem) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(spacing: 8) {
                Image(systemName: item.symbol)
                    .font(.system(size: Theme.Icon.illustration, weight: .light))
                    .foregroundStyle(item.symbolColor)
                Text(item.name)
                    .font(Theme.Typo.bodyStrong)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity)

            Divider()

            InfoRows(rows: basicRows(item))

            if !item.isDirectory {
                Divider()
                RemoteProperties(connection: browser.connection, item: item)
            }

            Divider()
            actions(for: item)
        }
    }

    private func basicRows(_ item: CloudItem) -> [(String, String)] {
        var rows: [(String, String)] = [("Kind", item.kindLabel)]
        if !item.isDirectory { rows.append(("Size", ByteFormat.bytes(item.size))) }
        if let modified = item.modified {
            rows.append(("Modified", DateFormatter.openborldFull.string(from: modified)))
        }
        if let created = item.created {
            rows.append(("Created", DateFormatter.openborldFull.string(from: created)))
        }
        if let type = item.contentType { rows.append(("Content Type", type)) }
        if let tier = item.storageClass { rows.append(("Storage Class", tier)) }
        if let permissions = item.permissions { rows.append(("Permissions", permissions)) }
        if let etag = item.etag { rows.append(("ETag", etag)) }
        rows.append(("Where", "/" + item.path.parent.joined))
        return rows
    }

    private var multiple: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(spacing: 6) {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: Theme.Icon.display, weight: .light))
                    .foregroundStyle(Theme.Ink.secondary)
                Text("\(selected.count) items selected")
                    .font(Theme.Typo.bodyStrong)
            }
            .frame(maxWidth: .infinity)

            Divider()

            InfoRows(rows: [
                ("Files", String(selected.filter { !$0.isDirectory }.count)),
                ("Folders", String(selected.filter(\.isDirectory).count)),
                ("Total Size", ByteFormat.bytes(selected.compactMap(\.size).reduce(0, +))),
            ])

            if model.isDualPane {
                Divider()
                VStack(spacing: 6) {
                    Button("Copy to Other Pane") {
                        model.transferSelection(from: model.activePane, isMove: false)
                    }
                    .frame(maxWidth: .infinity)
                    Button("Move to Other Pane") {
                        model.transferSelection(from: model.activePane, isMove: true)
                    }
                    .frame(maxWidth: .infinity)
                }
                .controlSize(.small)
            }
        }
    }

    private var folder: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(spacing: 6) {
                Image(systemName: browser.connection.kind.symbol)
                    .font(.system(size: Theme.Icon.display, weight: .light))
                    .foregroundStyle(browser.connection.kind.tint)
                Text(browser.title)
                    .font(Theme.Typo.bodyStrong)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity)

            Divider()

            InfoRows(rows: folderRows)

            Divider()

            VStack(alignment: .leading, spacing: 5) {
                Text("SUPPORTS")
                    .font(Theme.Typo.eyebrow)
                    .foregroundStyle(Theme.Ink.secondary)
                    .tracking(0.6)
                CapabilityList(capabilities: browser.capabilities)
            }
        }
    }

    private var folderRows: [(String, String)] {
        var rows: [(String, String)] = [
            ("Provider", browser.connection.kind.displayName),
            ("Connection", browser.connection.name),
            ("Path", "/" + browser.path.joined),
            ("Items", browser.hasMore
                ? "\(browser.visibleItems.count)+ loaded"
                : String(browser.visibleItems.count)),
        ]
        let status = model.connections.status(of: browser.connection.id)
        rows.append(("Status", status.label))
        if browser.loadedFromCache {
            rows.append(("Source", "Cached, refreshing"))
        }
        return rows
    }

    private func actions(for item: CloudItem) -> some View {
        VStack(spacing: 6) {
            if item.isDirectory {
                Button("Open") { browser.open(item) }
                    .frame(maxWidth: .infinity)
            } else {
                Button("Open") { model.open(item, in: model.activePane) }
                    .frame(maxWidth: .infinity)
                if browser.connection.kind != .local {
                    Button("Download") { model.downloadSelection(from: model.activePane) }
                        .frame(maxWidth: .infinity)
                }
                if browser.capabilities.contains(.signedURL) {
                    Button("Copy Share Link…") {
                        model.shareLink(for: item, in: model.activePane)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            Button("Copy Path") { model.copyPath(item, in: model.activePane) }
                .frame(maxWidth: .infinity)
        }
        .controlSize(.small)
    }
}

private struct InfoRows: View {
    let rows: [(String, String)]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.0)
                        .font(Theme.Typo.eyebrow)
                        .foregroundStyle(Theme.Ink.secondary)
                        .tracking(0.4)
                    Text(row.1)
                        .font(Theme.Typo.caption)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// Fetches provider properties for the selected file, once, on demand.
private struct RemoteProperties: View {
    let connection: Connection
    let item: CloudItem

    @State private var rows: [(key: String, value: String)] = []
    @State private var state: LoadState = .idle

    private enum LoadState { case idle, loading, loaded, failed(String) }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("PROPERTIES")
                    .font(Theme.Typo.eyebrow)
                    .foregroundStyle(Theme.Ink.secondary)
                    .tracking(0.6)
                Spacer()
                switch state {
                case .idle:
                    Button("Load") { load() }
                        .buttonStyle(.link)
                        .font(Theme.Typo.micro)
                case .loading:
                    ProgressView().controlSize(.mini)
                case .loaded:
                    Button("Reload") { load() }
                        .buttonStyle(.link)
                        .font(Theme.Typo.micro)
                case .failed:
                    Button("Retry") { load() }
                        .buttonStyle(.link)
                        .font(Theme.Typo.micro)
                }
            }

            switch state {
            case .idle:
                Text("Not loaded — provider properties need a request.")
                    .font(Theme.Typo.micro)
                    .foregroundStyle(Theme.Ink.secondary)
            case .loading:
                EmptyView()
            case .loaded:
                InfoRows(rows: rows.map { ($0.key, $0.value) })
            case .failed(let message):
                Text(message)
                    .font(Theme.Typo.micro)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        // A new selection invalidates whatever was loaded for the last one.
        .onChange(of: item.id) {
            rows = []
            state = .idle
        }
    }

    private func load() {
        state = .loading
        Task {
            do {
                let provider = try await ProviderRegistry.shared.validatedProvider(for: connection)
                rows = try await provider.metadata(item.path)
                state = .loaded
            } catch {
                state = .failed(TransferManager.describe(error))
            }
        }
    }
}

private struct CapabilityList: View {
    let capabilities: ProviderCapabilities

    private static let labels: [(ProviderCapabilities, String)] = [
        (.serverSideCopy, "Server-side copy"),
        (.chunkedUpload, "Resumable uploads"),
        (.rangeDownload, "Resumable downloads"),
        (.signedURL, "Shareable links"),
        (.createContainer, "Create containers"),
        (.realDirectories, "Real folders"),
        (.metadata, "Metadata"),
        (.permissions, "Permissions"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Self.labels.indices, id: \.self) { index in
                let (capability, label) = Self.labels[index]
                let supported = capabilities.contains(capability)
                HStack(spacing: 5) {
                    Image(systemName: supported ? "checkmark" : "minus")
                        .font(.system(size: Theme.Icon.tiny, weight: .bold))
                        .foregroundStyle(supported ? AnyShapeStyle(Color.green) : AnyShapeStyle(.tertiary))
                        .frame(width: 10)
                    Text(label)
                        .font(Theme.Typo.micro)
                        .foregroundStyle(supported ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
                }
            }
        }
    }
}
