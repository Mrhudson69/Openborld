import SwiftUI
import UniformTypeIdentifiers
import OpenborldCore

/// Identifies an in-app drag. The dragged items themselves are held in
/// `AppModel`, so the drag carries only a token — no custom pasteboard type to
/// register, and no stale serialised path that could be acted on later.
public struct DragToken: Codable, Transferable {
    public var id: UUID

    public init(id: UUID) { self.id = id }

    public static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(for: DragToken.self, contentType: .json)
    }
}

struct FileListView: View {
    @Environment(AppModel.self) private var model
    let pane: AppModel.Pane

    private var browser: BrowserModel { model.pane(pane) }

    var body: some View {
        VStack(spacing: 0) {
            ColumnHeader(pane: pane)
            Divider()

            List(selection: selectionBinding) {
                ForEach(browser.visibleItems) { item in
                    FileRow(item: item, pane: pane)
                        .tag(item.id)
                }

                if browser.hasMore {
                    LoadMoreRow(pane: pane)
                        // Not selectable: it's a control, not a file.
                        .selectionDisabled()
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
            .environment(\.defaultMinListRowHeight, Theme.Row.height)
            // Return opens, matching Finder. The keyboard needs a route to
            // every action that a double-click provides.
            .onKeyPress(.return) {
                guard let first = browser.selectedItems.first else { return .ignored }
                model.open(first, in: pane)
                return .handled
            }
            .accessibilityLabel("\(browser.title) contents")
        }
        .contextMenu {
            // Background menu — acts on the folder, not a selection.
            FolderContextMenu(pane: pane)
        }
    }

    /// Writing selection back through the model keeps the active pane in sync
    /// with whatever the user last clicked.
    private var selectionBinding: Binding<Set<String>> {
        Binding(
            get: { browser.selection },
            set: { newValue in
                if model.activePane != pane { model.activePane = pane }
                browser.selection = newValue
            }
        )
    }
}

private struct ColumnHeader: View {
    @Environment(AppModel.self) private var model
    let pane: AppModel.Pane

    private var browser: BrowserModel { model.pane(pane) }

    var body: some View {
        HStack(spacing: 0) {
            header("Name", field: .name)
                .frame(maxWidth: .infinity, alignment: .leading)
            header("Size", field: .size, alignment: .trailing)
                .frame(width: Design.sizeColumn, alignment: .trailing)
            header("Date Modified", field: .modified)
                .frame(width: Design.dateColumn, alignment: .leading)
            header("Kind", field: .kind)
                .frame(width: Design.kindColumn, alignment: .leading)
        }
        .padding(.horizontal, Theme.Space.lg)
        .frame(height: Theme.Row.headerHeight)
        .background(Theme.Surface.content)
    }

    private func header(
        _ title: String,
        field: SortField,
        alignment: HorizontalAlignment = .leading
    ) -> some View {
        SortHeaderButton(
            title: title,
            isSorted: browser.sortField == field,
            ascending: browser.sortAscending,
            alignment: alignment
        ) {
            if browser.sortField == field {
                browser.sortAscending.toggle()
            } else {
                browser.sortField = field
                browser.sortAscending = true
            }
        }
    }
}

private struct SortHeaderButton: View {
    let title: String
    let isSorted: Bool
    let ascending: Bool
    let alignment: HorizontalAlignment
    let action: () -> Void

    @Environment(\.reducedMotion) private var reducedMotion
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Space.hair) {
                if alignment == .trailing { Spacer(minLength: 0) }
                Text(title)
                    .font(Theme.Typo.captionStrong)
                    .foregroundStyle(isSorted ? Theme.Ink.primary : Theme.Ink.secondary)
                // The arrow, not colour alone, says which column is sorted.
                Image(systemName: ascending ? "chevron.up" : "chevron.down")
                    .font(.system(size: Theme.Icon.tiny, weight: .bold))
                    .foregroundStyle(Theme.Ink.secondary)
                    .opacity(isSorted ? 1 : (isHovering ? 0.35 : 0))
                if alignment == .leading { Spacer(minLength: 0) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            if reducedMotion { isHovering = hovering }
            else { withAnimation(Theme.Motion.hover) { isHovering = hovering } }
        }
        .accessibilityLabel(
            isSorted
                ? "\(title), sorted \(ascending ? "ascending" : "descending")"
                : "Sort by \(title)"
        )
        .accessibilityAddTraits(isSorted ? [.isSelected, .isHeader] : [.isHeader])
    }
}

private struct FileRow: View {
    @Environment(AppModel.self) private var model
    let item: CloudItem
    let pane: AppModel.Pane

    private var browser: BrowserModel { model.pane(pane) }

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: Theme.Space.sm) {
                Image(systemName: item.symbol)
                    .font(.system(size: Theme.Icon.sm))
                    .foregroundStyle(item.symbolColor)
                    .frame(width: Theme.Icon.lg)
                    // Decorative: the file name beside it already says what
                    // this is, so a second announcement is noise.
                    .accessibilityHidden(true)

                Text(item.name)
                    .font(Theme.Typo.body)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    // A truncated name must still be readable in full.
                    .help(item.name)

                if item.isSymlink {
                    Image(systemName: "arrow.turn.up.right")
                        .font(.system(size: Theme.Icon.tiny))
                        .foregroundStyle(Theme.Ink.secondary)
                        .accessibilityLabel("Symbolic link")
                }
                Spacer(minLength: Theme.Space.xs)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(item.isDirectory ? "—" : ByteFormat.bytes(item.size))
                .font(Theme.Typo.data)
                .foregroundStyle(Theme.Ink.secondary)
                .frame(width: Design.sizeColumn, alignment: .trailing)

            Text(ByteFormat.modified(item.modified))
                .font(Theme.Typo.caption)
                .foregroundStyle(Theme.Ink.secondary)
                .lineLimit(1)
                .frame(width: Design.dateColumn, alignment: .leading)

            Text(item.kindLabel)
                .font(Theme.Typo.caption)
                .foregroundStyle(Theme.Ink.secondary)
                .lineLimit(1)
                .frame(width: Design.kindColumn, alignment: .leading)
        }
        .padding(.horizontal, Theme.Space.md)
        .frame(height: Theme.Row.height)
        .contentShape(Rectangle())
        // A simultaneous gesture, so the List still receives the single clicks
        // it needs for shift-click ranges and command-click toggles. Consuming
        // them with `onTapGesture` silently breaks multi-select.
        .simultaneousGesture(
            TapGesture(count: 2).onEnded {
                model.activePane = pane
                model.open(item, in: pane)
            }
        )
        .draggable(dragToken()) {
            DragPreview(items: dragItems())
        }
        .dropDestination(for: DragToken.self) { tokens, _ in
            // Dropping onto a folder row targets that folder.
            guard item.isDirectory, let token = tokens.first else { return false }
            return model.handleDrop(token: token, into: item.path, pane: pane)
        }
        .contextMenu {
            ItemContextMenu(item: item, pane: pane)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityDescription)
        .accessibilityHint(item.isDirectory ? "Double-tap to open the folder" : "Double-tap to open")
    }

    /// One spoken phrase per row, rather than four disconnected cells.
    private var accessibilityDescription: String {
        var parts = [item.name, item.kindLabel]
        if !item.isDirectory, let size = item.size {
            parts.append(ByteFormat.bytes(size))
        }
        if let modified = item.modified {
            parts.append("modified \(ByteFormat.modified(modified))")
        }
        return parts.joined(separator: ", ")
    }

    /// Evaluated when the drag actually starts, not on every render.
    private func dragToken() -> DragToken {
        model.activePane = pane
        return model.beginDrag(items: dragItems(), from: pane)
    }

    /// Dragging an unselected row drags just that row; dragging a selected one
    /// drags the whole selection, the way Finder does.
    private func dragItems() -> [CloudItem] {
        browser.selection.contains(item.id) && browser.selection.count > 1
            ? browser.selectedItems
            : [item]
    }
}

private struct DragPreview: View {
    let items: [CloudItem]

    var body: some View {
        HStack(spacing: Theme.Space.sm) {
            Image(systemName: items.count == 1 ? items[0].symbol : "doc.on.doc")
                .foregroundStyle(items.count == 1 ? items[0].symbolColor : Color.accentColor)
            Text(items.count == 1 ? items[0].name : "\(items.count) items")
                .font(Theme.Typo.bodyStrong)
                .lineLimit(1)
        }
        .padding(.horizontal, Theme.Space.md)
        .padding(.vertical, Theme.Space.sm)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Theme.Radius.md))
    }
}

/// Appears at the end of a partially loaded directory and continues the listing
/// when it scrolls into view.
private struct LoadMoreRow: View {
    @Environment(AppModel.self) private var model
    let pane: AppModel.Pane

    @State private var hasRequested = false

    var body: some View {
        HStack {
            Spacer()
            if model.pane(pane).isLoading {
                HStack(spacing: Theme.Space.sm) {
                    ProgressView().controlSize(.mini)
                    Text("Loading more…")
                        .font(Theme.Typo.caption)
                        .foregroundStyle(Theme.Ink.secondary)
                }
                .accessibilityLabel("Loading more items")
            } else {
                Button("Load more") { request() }
                    .buttonStyle(.link)
                    .font(Theme.Typo.caption)
            }
            Spacer()
        }
        .frame(height: Theme.Row.height)
        .onAppear {
            // Guarded: without this the row fires a fetch on every recycle as
            // the user scrolls back and forth.
            guard !hasRequested else { return }
            hasRequested = true
            request()
        }
        .onDisappear { hasRequested = false }
    }

    private func request() {
        model.pane(pane).loadMore()
    }
}

// MARK: - Grid

struct FileGridView: View {
    @Environment(AppModel.self) private var model
    let pane: AppModel.Pane

    private var browser: BrowserModel { model.pane(pane) }

    private let columns = [
        GridItem(.adaptive(minimum: Design.gridItemWidth), spacing: Theme.Space.xl)
    ]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: Theme.Space.xl) {
                ForEach(browser.visibleItems) { item in
                    GridCell(item: item, pane: pane)
                }
            }
            .padding(Theme.Space.lg)

            if browser.hasMore {
                LoadMoreRow(pane: pane)
                    .padding(.bottom, Theme.Space.lg)
            }
        }
        .contextMenu { FolderContextMenu(pane: pane) }
        .accessibilityLabel("\(browser.title) contents, grid view")
    }
}

private struct GridCell: View {
    @Environment(AppModel.self) private var model
    @Environment(\.reducedMotion) private var reducedMotion
    let item: CloudItem
    let pane: AppModel.Pane

    @State private var isHovering = false

    private var browser: BrowserModel { model.pane(pane) }
    private var isSelected: Bool { browser.selection.contains(item.id) }

    var body: some View {
        VStack(spacing: Theme.Space.sm) {
            Image(systemName: item.symbol)
                .font(.system(size: Design.gridIconSize, weight: .light))
                .foregroundStyle(item.symbolColor)
                .frame(height: Design.gridIconSize + Theme.Space.sm)
                .accessibilityHidden(true)

            Text(item.name)
                .font(Theme.Typo.caption)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: Design.gridItemWidth - Theme.Space.md)
                .help(item.name)

            Text(item.isDirectory ? item.kindLabel : ByteFormat.bytes(item.size))
                .font(Theme.Typo.dataSmall)
                .foregroundStyle(Theme.Ink.secondary)
        }
        .padding(Theme.Space.sm)
        .frame(width: Design.gridItemWidth)
        .background(cellBackground, in: RoundedRectangle(cornerRadius: Theme.Radius.md))
        .overlay {
            // Selection carries a border as well as a fill, so it survives a
            // reduced-transparency or high-contrast setting.
            if isSelected {
                RoundedRectangle(cornerRadius: Theme.Radius.md)
                    .strokeBorder(Color.accentColor, lineWidth: 1.5)
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering in
            if reducedMotion { isHovering = hovering }
            else { withAnimation(Theme.Motion.hover) { isHovering = hovering } }
        }
        .onTapGesture(count: 2) {
            model.activePane = pane
            model.open(item, in: pane)
        }
        .onTapGesture {
            model.activePane = pane
            // Grid cells aren't inside a selectable List, so selection is
            // handled here. Shift and command extend it.
            if NSEvent.modifierFlags.contains(.command) {
                if isSelected { browser.selection.remove(item.id) }
                else { browser.selection.insert(item.id) }
            } else {
                browser.selection = [item.id]
            }
        }
        .draggable(dragToken()) { DragPreview(items: dragItems()) }
        .dropDestination(for: DragToken.self) { tokens, _ in
            guard item.isDirectory, let token = tokens.first else { return false }
            return model.handleDrop(token: token, into: item.path, pane: pane)
        }
        .contextMenu { ItemContextMenu(item: item, pane: pane) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.name), \(item.kindLabel)")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private var cellBackground: Color {
        if isSelected { return Color.accentColor.opacity(0.18) }
        return isHovering ? Color.primary.opacity(0.06) : .clear
    }

    private func dragToken() -> DragToken {
        model.activePane = pane
        return model.beginDrag(items: dragItems(), from: pane)
    }

    private func dragItems() -> [CloudItem] {
        browser.selection.contains(item.id) && browser.selection.count > 1
            ? browser.selectedItems
            : [item]
    }
}

// MARK: - Context menus

struct ItemContextMenu: View {
    @Environment(AppModel.self) private var model
    let item: CloudItem
    let pane: AppModel.Pane

    private var browser: BrowserModel { model.pane(pane) }
    private var selectionCount: Int {
        browser.selection.contains(item.id) ? max(1, browser.selection.count) : 1
    }

    var body: some View {
        Button("Open") {
            if item.isDirectory { browser.open(item) } else { model.open(item, in: pane) }
        }

        if model.isDualPane {
            Divider()
            Button(selectionCount > 1
                ? "Copy \(selectionCount) Items to Other Pane"
                : "Copy to Other Pane") {
                model.transferSelection(from: pane, isMove: false)
            }
            Button(selectionCount > 1
                ? "Move \(selectionCount) Items to Other Pane"
                : "Move to Other Pane") {
                model.transferSelection(from: pane, isMove: true)
            }
        }

        Divider()

        if browser.connection.kind != .local {
            Button("Download") { model.downloadSelection(from: pane) }
            if browser.capabilities.contains(.signedURL), !item.isDirectory {
                Button("Copy Share Link…") { model.shareLink(for: item, in: pane) }
            }
        } else {
            Button("Reveal in Finder") { model.revealInFinder(item, in: pane) }
        }

        Button("Copy Path") { model.copyPath(item, in: pane) }

        Divider()

        Button("Rename…") { model.presentation = .rename(pane, item) }
            .disabled(item.kind == .container && browser.connection.kind.isObjectStore)

        Button("Get Info") { model.showMetadata(for: item, in: pane) }

        Divider()

        Button(selectionCount > 1 ? "Delete \(selectionCount) Items" : "Delete", role: .destructive) {
            if !browser.selection.contains(item.id) {
                browser.selection = [item.id]
            }
            model.requestDelete(in: pane)
        }
    }
}

struct FolderContextMenu: View {
    @Environment(AppModel.self) private var model
    let pane: AppModel.Pane

    private var browser: BrowserModel { model.pane(pane) }

    private var isFavorite: Bool {
        model.places.isFavorite(connectionID: browser.connection.id, path: browser.path)
    }

    var body: some View {
        if browser.isAtContainerRoot {
            Button("New \(browser.connection.kind.containerNoun)…") {
                model.presentation = .newContainer(pane)
            }
        } else {
            Button("New Folder…") { model.presentation = .newFolder(pane) }
            Button("Upload…") { model.chooseFilesToUpload(into: pane) }
        }

        Divider()
        Button("Refresh") { browser.refresh() }

        Button(isFavorite ? "Remove from Favorites" : "Add to Favorites") {
            model.places.toggleFavorite(
                connectionID: browser.connection.id,
                path: browser.path,
                name: browser.path.isRoot ? browser.connection.name : browser.path.name
            )
        }

        Button("Add Bookmark") {
            model.places.addBookmark(
                connectionID: browser.connection.id,
                path: browser.path,
                name: browser.path.isRoot ? browser.connection.name : browser.path.name
            )
        }

        Divider()
        Picker("Sort By", selection: Binding(
            get: { browser.sortField },
            set: { browser.sortField = $0 }
        )) {
            ForEach(SortField.allCases) { field in
                Text(field.displayName).tag(field)
            }
        }
    }
}
