import SwiftUI
import OpenborldCore

struct MainWindow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 210, ideal: 240, max: 340)
        } detail: {
            detail
                // Without a floor here the split view takes the inspector's
                // width out of the sidebar, whose rows then overflow their
                // column and clip. Giving the detail a minimum makes it the
                // column that yields.
                .frame(minWidth: 420)
        }
        .navigationTitle(model.active.title)
        // Applied to the whole split view, not inside the detail column:
        // nesting it in the detail is what let it compete with the sidebar
        // for width in the first place.
        .inspector(isPresented: Binding(
            get: { model.showInspector },
            set: { model.showInspector = $0 }
        )) {
            InspectorView()
                .inspectorColumnWidth(min: 240, ideal: 280, max: 380)
        }
        .overlay(alignment: .top) { bannerOverlay }
        .sheet(item: Binding(
            get: { model.presentation },
            set: { model.presentation = $0 }
        )) { presentation in
            PresentationHost(presentation: presentation)
                .environment(model)
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch model.sidebarSelection {
        case .transfers:
            TransfersView()
        case .history:
            HistoryView()
        default:
            browser
        }
    }

    private var browser: some View {
        VStack(spacing: 0) {
            if model.isDualPane {
                HSplitView {
                    BrowserPaneView(pane: .left)
                        .frame(minWidth: 340)
                    BrowserPaneView(pane: .right)
                        .frame(minWidth: 340)
                }
            } else {
                BrowserPaneView(pane: .left)
            }

            Divider()
            StatusBar()
        }
    }

    @ViewBuilder
    private var bannerOverlay: some View {
        if let banner = model.banner {
            BannerView(banner: banner) { model.banner = nil }
                .padding(.top, Theme.Space.md)
                .transition(
                    .move(edge: .top).combined(with: .opacity)
                )
                .id(banner.id)
        }
    }
}

/// Transient feedback for actions that complete without changing the view —
/// a created folder, a copied path, a failure that doesn't warrant a dialog.
struct BannerView: View {
    @Environment(\.reducedMotion) private var reducedMotion
    let banner: AppModel.Banner
    let dismiss: () -> Void

    @State private var showDetail = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            HStack(spacing: Theme.Space.md) {
                Image(systemName: banner.level.symbol)
                    .foregroundStyle(banner.level.tint)
                    .accessibilityHidden(true)

                Text(banner.message)
                    .font(Theme.Typo.bodyStrong)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                if banner.detail != nil {
                    Button(showDetail ? "Less" : "Details") {
                        if reducedMotion {
                            showDetail.toggle()
                        } else {
                            withAnimation(Theme.Motion.state) { showDetail.toggle() }
                        }
                    }
                    .buttonStyle(.link)
                    .font(Theme.Typo.caption)
                    .accessibilityLabel(showDetail ? "Hide error details" : "Show error details")
                }

                IconButton(
                    symbol: "xmark",
                    label: "Dismiss",
                    size: Theme.Icon.badge
                ) { dismiss() }
                .foregroundStyle(Theme.Ink.secondary)
            }

            if showDetail, let detail = banner.detail {
                Text(detail)
                    .font(Theme.Typo.caption)
                    .foregroundStyle(Theme.Ink.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: 420, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, Theme.Space.lg)
        .padding(.vertical, 9)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Theme.Radius.lg))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.lg)
                .strokeBorder(banner.level.tint.opacity(0.4), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.16), radius: 10, y: 3)
        // Announced as a complete phrase including severity, which the icon and
        // tint carry visually but a screen reader never sees.
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(banner.level.spokenPrefix): \(banner.message)")
    }
}

/// Bottom bar: item counts on the left, live transfer summary on the right.
struct StatusBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: Theme.Space.lg) {
            Text(model.active.statusSummary)
                .font(Theme.Typo.caption)
                .foregroundStyle(Theme.Ink.secondary)
                .accessibilityLabel(model.active.statusSummary)

            if model.active.isRefreshing {
                HStack(spacing: Theme.Space.xs) {
                    ProgressView().controlSize(.mini)
                    Text("Refreshing")
                }
                .font(Theme.Typo.caption)
                .foregroundStyle(Theme.Ink.secondary)
                .accessibilityLabel("Refreshing the listing")
            }

            Spacer()

            if model.transfers.hasActivity {
                transferSummary
            } else if model.transfers.failedCount > 0 {
                Button {
                    model.sidebarSelection = .transfers
                } label: {
                    Label(
                        "\(model.transfers.failedCount) failed",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(Theme.Typo.caption)
                    .foregroundStyle(Theme.Status.danger)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(
                    "\(model.transfers.failedCount) transfers failed. Open the transfer queue."
                )
            }
        }
        .padding(.horizontal, Theme.Space.lg)
        .frame(height: Theme.Row.statusHeight)
        .background(Theme.Surface.bar)
    }

    private var transferSummary: some View {
        Button {
            model.sidebarSelection = .transfers
        } label: {
            HStack(spacing: Theme.Space.sm) {
                ProgressView(value: model.transfers.overallFraction)
                    .progressViewStyle(.linear)
                    .frame(width: 70)
                Text("\(model.transfers.activeCount) active")
                if model.transfers.totalSpeed > 1 {
                    Text(ByteFormat.rate(model.transfers.totalSpeed))
                        .monospacedDigit()
                        .foregroundStyle(Theme.Ink.secondary)
                }
            }
            .font(Theme.Typo.caption)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(model.transfers.activeCount) active transfers, "
                + "\(Int(model.transfers.overallFraction * 100)) percent complete. "
                + "Open the transfer queue."
        )
        // Keeps VoiceOver from re-reading the whole bar on every progress tick.
        .accessibilityAddTraits(.updatesFrequently)
    }
}

/// Routes `AppModel.Presentation` to the right sheet. Keeping this in one place
/// means every sheet is reachable from anywhere by setting `model.presentation`.
struct PresentationHost: View {
    @Environment(AppModel.self) private var model
    let presentation: AppModel.Presentation

    var body: some View {
        switch presentation {
        case .addConnection:
            ConnectionEditor(existing: nil)
        case .editConnection(let connection):
            ConnectionEditor(existing: connection)
        case .newFolder(let pane):
            TextPromptSheet(
                title: "New Folder",
                message: "Create a folder in \(model.pane(pane).title).",
                placeholder: "untitled folder",
                confirmLabel: "Create"
            ) { name in
                model.createFolder(in: pane, named: name)
            }
        case .newContainer(let pane):
            let noun = model.pane(pane).connection.kind.containerNoun
            TextPromptSheet(
                title: "New \(noun)",
                message: "Create a \(noun.lowercased()) in \(model.pane(pane).connection.name).",
                placeholder: noun.lowercased() + "-name",
                confirmLabel: "Create",
                validator: ContainerNameRules.validate
            ) { name in
                model.createContainer(in: pane, named: name)
            }
        case .rename(let pane, let item):
            TextPromptSheet(
                title: "Rename",
                message: "Rename “\(item.name)”.",
                placeholder: item.name,
                initialValue: item.name,
                confirmLabel: "Rename"
            ) { name in
                model.rename(item, in: pane, to: name)
            }
        case .shareLink(let name, let url, let isConnectionToken):
            ShareLinkSheet(name: name, url: url, isConnectionToken: isConnectionToken)
        case .metadata(let connection, let item):
            MetadataSheet(connection: connection, item: item)
        case .confirmDelete(let pane, let items):
            DeleteConfirmSheet(pane: pane, items: items)
        case .transferConflict(let prompt):
            ConflictSheet(prompt: prompt)
        }
    }
}
