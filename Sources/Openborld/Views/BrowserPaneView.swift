import SwiftUI
import AppKit
import OpenborldCore

struct BrowserPaneView: View {
    @Environment(AppModel.self) private var model
    let pane: AppModel.Pane

    private var browser: BrowserModel { model.pane(pane) }
    private var isActive: Bool { model.activePane == pane }

    var body: some View {
        VStack(spacing: 0) {
            PaneToolbar(pane: pane)
            Divider()
            BreadcrumbBar(pane: pane)
            Divider()
            content
        }
        .background(Theme.Surface.content)
        // In dual-pane mode the active pane is marked with an accent rule along
        // its top edge rather than a full border: a border inset at zero clips
        // against the divider and fights the window's own focus ring.
        .overlay(alignment: .top) {
            if model.isDualPane {
                Rectangle()
                    .fill(isActive ? Color.accentColor : Color.clear)
                    .frame(height: 2)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { model.activePane = pane }
        // Files dragged in from Finder become an upload into this folder.
        // Only one drop destination per view: stacking two can leave the
        // inner one shadowed, so the in-app token drop sits on the content
        // view instead.
        .dropDestination(for: URL.self) { urls, _ in
            let fileURLs = urls.filter(\.isFileURL)
            guard !fileURLs.isEmpty else { return false }
            model.activePane = pane
            model.upload(urls: fileURLs, into: pane)
            return true
        }
        .accessibilityLabel(
            model.isDualPane
                ? "\(pane == .left ? "Left" : "Right") pane, \(browser.title)"
                : browser.title
        )
    }

    private var content: some View {
        contentBody
            // Dropping onto pane background, rather than onto a folder row,
            // targets the folder currently on screen.
            .dropDestination(for: DragToken.self) { tokens, _ in
                guard let token = tokens.first else { return false }
                return model.handleDropOnPane(token: token, pane: pane)
            }
    }

    @ViewBuilder
    private var contentBody: some View {
        if let error = browser.error, browser.visibleItems.isEmpty {
            ErrorState(message: error, pane: pane)
        } else if browser.isLoading, browser.visibleItems.isEmpty {
            LoadingState()
        } else if browser.isEmpty {
            EmptyState(pane: pane)
        } else {
            switch model.settings.viewMode {
            case .list, .columns:
                FileListView(pane: pane)
            case .grid:
                FileGridView(pane: pane)
            }
        }
    }
}

// MARK: - Toolbar

private struct PaneToolbar: View {
    @Environment(AppModel.self) private var model
    let pane: AppModel.Pane

    private var browser: BrowserModel { model.pane(pane) }

    private var isRemote: Bool { browser.connection.kind != .local }
    private var newFolderLabel: String {
        browser.isAtContainerRoot
            ? "New \(browser.connection.kind.containerNoun)"
            : "New Folder"
    }

    var body: some View {
        HStack(spacing: Theme.Space.md) {
            HStack(spacing: 0) {
                IconButton(
                    symbol: "chevron.left",
                    label: "Back",
                    detail: "Go to the previous location",
                    isEnabled: browser.canGoBack
                ) { browser.goBack() }

                IconButton(
                    symbol: "chevron.right",
                    label: "Forward",
                    detail: "Go to the next location",
                    isEnabled: browser.canGoForward
                ) { browser.goForward() }

                IconButton(
                    symbol: "chevron.up",
                    label: "Enclosing Folder",
                    detail: "Go up one level",
                    isEnabled: browser.canGoUp
                ) { browser.goUp() }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Navigation")

            Divider().frame(height: Theme.Space.xl)

            IconButton(
                symbol: "arrow.clockwise",
                label: "Refresh",
                detail: "Reload this folder, ignoring the cache"
            ) { browser.refresh() }

            IconButton(symbol: "folder.badge.plus", label: newFolderLabel) {
                model.activePane = pane
                model.presentation = browser.isAtContainerRoot
                    ? .newContainer(pane)
                    : .newFolder(pane)
            }

            IconButton(
                symbol: "arrow.up.doc",
                label: "Upload",
                detail: "Choose files to upload here",
                isEnabled: !browser.isAtContainerRoot
            ) {
                model.activePane = pane
                model.chooseFilesToUpload(into: pane)
            }

            IconButton(
                symbol: "arrow.down.doc",
                label: "Download",
                detail: "Save the selection to your download folder",
                isEnabled: !browser.selection.isEmpty && isRemote
            ) {
                model.activePane = pane
                model.downloadSelection(from: pane)
            }

            if model.isDualPane {
                Divider().frame(height: Theme.Space.xl)
                IconButton(
                    symbol: pane == .left ? "arrow.right.circle" : "arrow.left.circle",
                    label: "Copy to Other Pane",
                    detail: "Copy the selection across",
                    isEnabled: !browser.selection.isEmpty
                ) {
                    model.activePane = pane
                    model.transferSelection(from: pane, isMove: false)
                }
            }

            Spacer(minLength: Theme.Space.md)

            SearchField(
                text: Binding(
                    get: { browser.searchText },
                    set: { browser.searchText = $0 }
                ),
                placeholder: "Search this folder"
            )
            .frame(width: 168)
            .accessibilityLabel("Search within \(browser.title)")

            ViewModePicker()

            IconButton(
                symbol: "sidebar.right",
                label: "Inspector",
                detail: "Show details for the selection",
                isActive: model.showInspector
            ) {
                model.showInspector.toggle()
            }
        }
        .padding(.horizontal, Theme.Space.lg)
        .frame(height: Theme.Row.toolbarHeight)
        .background(Theme.Surface.bar)
    }
}

private struct ViewModePicker: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Picker("View as", selection: Binding(
            get: { model.settings.viewMode },
            set: { model.settings.viewMode = $0 }
        )) {
            Image(systemName: ViewMode.list.symbol)
                .accessibilityLabel("List view")
                .tag(ViewMode.list)
            Image(systemName: ViewMode.grid.symbol)
                .accessibilityLabel("Grid view")
                .tag(ViewMode.grid)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 72)
        .help("Switch between list and grid")
    }
}

/// A native search field. `NSSearchField` brings the real focus ring, cancel
/// button, and accessibility role that a hand-rolled `TextField` doesn't.
struct SearchField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = placeholder
        field.delegate = context.coordinator
        field.focusRingType = .default
        field.sendsSearchStringImmediately = false
        field.sendsWholeSearchString = false
        field.controlSize = .small
        field.font = .systemFont(ofSize: 11)
        field.setAccessibilityLabel(placeholder)
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        // Only write when the value genuinely differs, or every keystroke
        // resets the insertion point to the end of the field.
        if field.stringValue != text { field.stringValue = text }
        if field.placeholderString != placeholder { field.placeholderString = placeholder }
        context.coordinator.text = $text
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var text: Binding<String>

        init(text: Binding<String>) { self.text = text }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            text.wrappedValue = field.stringValue
        }
    }
}

// MARK: - Breadcrumbs

struct BreadcrumbBar: View {
    @Environment(AppModel.self) private var model
    let pane: AppModel.Pane

    private var browser: BrowserModel { model.pane(pane) }

    private var isFavorite: Bool {
        model.places.isFavorite(connectionID: browser.connection.id, path: browser.path)
    }

    /// The full location as text, for the tooltip and for Copy Path. The
    /// crumbs can truncate; this never does.
    private var fullPath: String {
        browser.path.isRoot
            ? browser.connection.name
            : "\(browser.connection.name)/\(browser.path.joined)"
    }

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Theme.Space.hair) {
                    // The root crumb is a picker, not just a link: this is how
                    // you point one pane at S3 and the other at Azure, which is
                    // what makes dragging between services possible.
                    ConnectionCrumb(pane: pane)

                    ForEach(Array(browser.path.components.enumerated()), id: \.offset) { index, component in
                        Image(systemName: "chevron.compact.right")
                            .font(.system(size: Theme.Icon.badge))
                            .foregroundStyle(Theme.Ink.faint)
                            .accessibilityHidden(true)

                        Crumb(
                            label: component,
                            symbol: nil,
                            tint: Theme.Ink.primary,
                            isLast: index == browser.path.components.count - 1
                        ) {
                            browser.navigate(
                                to: RemotePath(
                                    components: Array(browser.path.components.prefix(index + 1))
                                )
                            )
                        }
                    }
                }
                .padding(.horizontal, Theme.Space.lg)
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Path: \(browser.connection.name) \(browser.path.joined)")

            // Outside the scroll view, so these can never be scrolled out of
            // reach or sit under a fading gradient.
            Divider().frame(height: Theme.Space.xl)

            IconButton(
                symbol: "doc.on.clipboard",
                label: "Copy Path",
                detail: fullPath,
                size: Theme.Icon.xs
            ) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(fullPath, forType: .string)
                model.show("Path copied.", level: .success)
            }

            IconButton(
                symbol: isFavorite ? "star.fill" : "star",
                label: isFavorite ? "Remove from Favorites" : "Add to Favorites",
                size: Theme.Icon.xs,
                isActive: isFavorite
            ) {
                model.places.toggleFavorite(
                    connectionID: browser.connection.id,
                    path: browser.path,
                    name: browser.path.isRoot ? browser.connection.name : browser.path.name
                )
            }
            .padding(.trailing, Theme.Space.sm)
        }
        .frame(height: Theme.Row.breadcrumbHeight)
        .background(Theme.Surface.bar)
        .help(fullPath)
    }
}

/// The leading crumb: shows this pane's connection and switches it.
private struct ConnectionCrumb: View {
    @Environment(AppModel.self) private var model
    @Environment(\.reducedMotion) private var reducedMotion
    let pane: AppModel.Pane

    @State private var isHovering = false

    private var browser: BrowserModel { model.pane(pane) }

    var body: some View {
        Menu {
            Section("Open in this pane") {
                ForEach(model.connections.all) { connection in
                    Button {
                        browser.switchTo(connection: connection, path: .root)
                    } label: {
                        Label(connection.name, systemImage: connection.kind.symbol)
                    }
                    .disabled(connection.id == browser.connection.id && browser.path.isRoot)
                }
            }

            Divider()

            if browser.path.isRoot == false {
                Button("Go to \(browser.connection.name) Root") {
                    browser.navigate(to: .root)
                }
            }

            Button(model.isDualPane ? "Close Second Pane" : "Open Second Pane") {
                model.isDualPane.toggle()
            }

            Button("Add Connection…") { model.presentation = .addConnection }
        } label: {
            HStack(spacing: Theme.Space.xs) {
                Image(systemName: browser.connection.kind.symbol)
                    .font(.system(size: Theme.Icon.sm))
                    .foregroundStyle(browser.connection.kind.tint)
                Text(browser.connection.name)
                    .font(browser.path.isRoot ? Theme.Typo.bodyStrong : Theme.Typo.body)
                    .foregroundStyle(
                        browser.path.isRoot ? Theme.Ink.primary : Theme.Ink.secondary
                    )
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: Theme.Icon.tiny, weight: .semibold))
                    .foregroundStyle(Theme.Ink.secondary)
            }
            .padding(.horizontal, Theme.Space.sm)
            .padding(.vertical, 3)
            .background(
                isHovering ? Color.primary.opacity(0.08) : .clear,
                in: RoundedRectangle(cornerRadius: Theme.Radius.sm)
            )
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { hovering in
            if reducedMotion { isHovering = hovering }
            else { withAnimation(Theme.Motion.hover) { isHovering = hovering } }
        }
        .help("Switch this pane to another connection")
        .accessibilityLabel("Connection: \(browser.connection.name). Switch this pane.")
    }
}

private struct Crumb: View {
    let label: String
    let symbol: String?
    let tint: Color
    let isLast: Bool
    let action: () -> Void

    @Environment(\.reducedMotion) private var reducedMotion
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Space.xs) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: Theme.Icon.badge + 1))
                        .foregroundStyle(tint)
                        .accessibilityHidden(true)
                }
                Text(label)
                    .font(isLast ? Theme.Typo.bodyStrong : Theme.Typo.body)
                    .foregroundStyle(isLast ? Theme.Ink.primary : Theme.Ink.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, Theme.Space.sm)
            .padding(.vertical, 3)
            .background(
                isHovering && !isLast ? Color.primary.opacity(0.08) : .clear,
                in: RoundedRectangle(cornerRadius: Theme.Radius.sm)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isLast)
        .onHover { hovering in
            guard !isLast else { return }
            if reducedMotion { isHovering = hovering }
            else { withAnimation(Theme.Motion.hover) { isHovering = hovering } }
        }
        .accessibilityLabel(isLast ? "\(label), current folder" : "Go to \(label)")
        .accessibilityAddTraits(isLast ? [.isSelected] : [])
    }
}

// MARK: - States

private struct LoadingState: View {
    var body: some View {
        VStack(spacing: Theme.Space.md) {
            ProgressView()
                .controlSize(.small)
            Text("Loading…")
                .font(Theme.Typo.body)
                .foregroundStyle(Theme.Ink.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Loading folder contents")
        .accessibilityAddTraits(.updatesFrequently)
    }
}

private struct EmptyState: View {
    @Environment(AppModel.self) private var model
    let pane: AppModel.Pane

    private var browser: BrowserModel { model.pane(pane) }

    var body: some View {
        VStack(spacing: Theme.Space.lg) {
            Image(systemName: browser.isAtContainerRoot ? "cube.box" : "folder")
                .font(.system(size: Theme.Icon.display, weight: .light))
                .foregroundStyle(Theme.Ink.faint)
                .accessibilityHidden(true)

            Text(browser.emptyMessage)
                .font(Theme.Typo.body)
                .foregroundStyle(Theme.Ink.secondary)
                .multilineTextAlignment(.center)

            // An empty state should offer the way out, not just report the fact.
            if browser.searchText.isEmpty {
                HStack(spacing: Theme.Space.md) {
                    if browser.isAtContainerRoot {
                        Button("New \(browser.connection.kind.containerNoun)") {
                            model.presentation = .newContainer(pane)
                        }
                    } else {
                        Button("New Folder") { model.presentation = .newFolder(pane) }
                        Button("Upload…") { model.chooseFilesToUpload(into: pane) }
                    }
                }
                .controlSize(.small)
            } else {
                Button("Clear Search") { browser.searchText = "" }
                    .controlSize(.small)
            }
        }
        .padding(Theme.Space.huge)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ErrorState: View {
    @Environment(AppModel.self) private var model
    let message: String
    let pane: AppModel.Pane

    private var browser: BrowserModel { model.pane(pane) }

    var body: some View {
        VStack(spacing: Theme.Space.lg) {
            // Icon plus heading plus colour: the failure is never signalled by
            // colour alone.
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: Theme.Icon.display, weight: .light))
                .foregroundStyle(Theme.Status.warning)
                .accessibilityHidden(true)

            Text("Couldn't open this location")
                .font(Theme.Typo.title)

            Text(message)
                .font(Theme.Typo.caption)
                .foregroundStyle(Theme.Ink.secondary)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
                .frame(maxWidth: 380)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: Theme.Space.md) {
                Button("Try Again") { browser.refresh() }
                if browser.connection.kind != .local {
                    Button("Edit Connection…") {
                        model.presentation = .editConnection(browser.connection)
                    }
                }
            }
            .controlSize(.small)
        }
        .padding(Theme.Space.huge)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Error: couldn't open this location. \(message)")
    }
}
