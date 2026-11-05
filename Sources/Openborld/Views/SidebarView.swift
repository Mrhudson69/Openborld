import SwiftUI
import OpenborldCore

/// The sidebar.
///
/// Rows are plain labels carrying a `tag`, not buttons: a `Button` inside a
/// selectable `List` consumes the click, so the row never highlights and
/// keyboard navigation never reaches it. Selection drives navigation through
/// `onChange` instead.
struct SidebarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        List(selection: selectionBinding) {
            activitySection
            favoritesSection
            connectionsSection
            bookmarksSection
            recentsSection
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) { bottomBar }
        // One place where a sidebar choice becomes a navigation.
        .onChange(of: model.sidebarSelection) { _, selection in
            guard case .location(let connectionID, let path) = selection else { return }
            model.navigateFromSidebar(connectionID: connectionID, path: path)
        }
    }

    private var selectionBinding: Binding<SidebarSelection?> {
        Binding(
            get: { model.sidebarSelection },
            set: { model.sidebarSelection = $0 ?? model.sidebarSelection }
        )
    }

    // MARK: Sections

    private var activitySection: some View {
        Section {
            Label {
                HStack(spacing: Theme.Space.sm) {
                    Text("Transfer Queue")
                    Spacer(minLength: 0)
                    if model.transfers.activeCount > 0 {
                        CountBadge(count: model.transfers.activeCount, noun: "active transfers")
                    } else if model.transfers.failedCount > 0 {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: Theme.Icon.badge))
                            .foregroundStyle(Theme.Status.danger)
                            .accessibilityLabel("\(model.transfers.failedCount) failed transfers")
                    }
                }
            } icon: {
                Image(systemName: "arrow.up.arrow.down")
            }
            .tag(SidebarSelection.transfers)

            Label("Activity History", systemImage: "clock.arrow.circlepath")
                .tag(SidebarSelection.history)
        }
    }

    @ViewBuilder
    private var favoritesSection: some View {
        if !model.places.favorites.isEmpty {
            Section("Favorites") {
                ForEach(model.places.favorites) { place in
                    PlaceRow(place: place, symbol: "star")
                        .contextMenu {
                            Button("Remove from Favorites") {
                                model.places.removeFavorite(place.id)
                            }
                        }
                }
            }
        }
    }

    private var connectionsSection: some View {
        Section("Connections") {
            ForEach(model.connections.all) { connection in
                ConnectionRow(connection: connection)
            }

            // Deliberately a prominent button rather than another quiet row:
            // connecting storage is the one thing a new user must find, and a
            // grey text row beside grey text rows does not announce itself.
            AddConnectionButton()
                .selectionDisabled()
        }
    }

    @ViewBuilder
    private var bookmarksSection: some View {
        if !model.places.bookmarks.isEmpty {
            Section("Bookmarks") {
                ForEach(model.places.bookmarks) { place in
                    PlaceRow(place: place, symbol: "bookmark")
                        .contextMenu {
                            Button("Remove Bookmark") {
                                model.places.removeBookmark(place.id)
                            }
                        }
                }
            }
        }
    }

    @ViewBuilder
    private var recentsSection: some View {
        if !model.places.recents.isEmpty {
            Section("Recents") {
                ForEach(model.places.recents.prefix(8)) { place in
                    PlaceRow(place: place, symbol: "clock")
                }
                Button("Clear Recents") { model.places.clearRecents() }
                    .buttonStyle(.plain)
                    .font(Theme.Typo.caption)
                    .foregroundStyle(Theme.Ink.secondary)
                    .selectionDisabled()
            }
        }
    }

    // MARK: Footer

    private var bottomBar: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: Theme.Space.xs) {
                IconButton(
                    symbol: "plus",
                    label: "Add Connection",
                    detail: "Connect a new storage account",
                    size: Theme.Icon.xs
                ) {
                    model.presentation = .addConnection
                }

                Spacer()

                IconButton(
                    symbol: model.isDualPane
                        ? "rectangle.split.2x1.fill"
                        : "rectangle.split.2x1",
                    label: "Dual Pane",
                    detail: model.isDualPane
                        ? "Switch back to a single pane"
                        : "Show two locations side by side",
                    size: Theme.Icon.xs,
                    isActive: model.isDualPane
                ) {
                    model.isDualPane.toggle()
                }

                SettingsLink {
                    Image(systemName: "gearshape")
                        .font(.system(size: Theme.Icon.xs, weight: .medium))
                        .frame(
                            width: Theme.Icon.hitSize.width,
                            height: Theme.Icon.hitSize.height
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Settings")
                .accessibilityLabel("Open Settings")
            }
            .foregroundStyle(Theme.Ink.secondary)
            .padding(.horizontal, Theme.Space.md)
            .frame(height: 30)
            .background(Theme.Surface.bar)
        }
    }
}

/// The primary call to action in the sidebar.
private struct AddConnectionButton: View {
    @Environment(AppModel.self) private var model
    @Environment(\.reducedMotion) private var reducedMotion
    @State private var isHovering = false
    @FocusState private var isFocused: Bool

    var body: some View {
        Button {
            model.presentation = .addConnection
        } label: {
            HStack(spacing: Theme.Space.sm) {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: Theme.Icon.lg))
                    .accessibilityHidden(true)
                Text("Add Connection")
                    .font(Theme.Typo.bodyStrong)
                Spacer(minLength: 0)
            }
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, Theme.Space.md)
            .frame(height: 32)
            .frame(maxWidth: .infinity)
            .background(
                Color.accentColor.opacity(isHovering ? 0.22 : 0.13),
                in: RoundedRectangle(cornerRadius: Theme.Radius.md)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.md)
                    .strokeBorder(
                        Color.accentColor.opacity(isFocused ? 0.95 : 0.35),
                        lineWidth: isFocused ? 2 : 1
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable()
        .focused($isFocused)
        .onHover { hovering in
            if reducedMotion { isHovering = hovering }
            else { withAnimation(Theme.Motion.hover) { isHovering = hovering } }
        }
        .padding(.vertical, Theme.Space.xs)
        .help("Connect Azure Blob Storage, S3, WebDAV, and more")
        .accessibilityLabel("Add Connection")
        .accessibilityHint("Connect a new cloud storage account")
    }
}

// MARK: - Rows

private struct PlaceRow: View {
    @Environment(AppModel.self) private var model
    let place: Place
    let symbol: String

    private var providerKind: ProviderKind? {
        model.connections.connection(id: place.connectionID)?.kind
    }

    var body: some View {
        HStack(spacing: Theme.Space.sm) {
            Image(systemName: symbol)
                .font(.system(size: Theme.Icon.xs))
                .frame(width: 14)
                .foregroundStyle(Theme.Ink.secondary)
                .accessibilityHidden(true)

            Text(place.name)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 0)

            if let kind = providerKind, kind != .local {
                Image(systemName: kind.symbol)
                    .font(.system(size: Theme.Icon.badge))
                    .foregroundStyle(kind.tint)
                    .accessibilityHidden(true)
            }
        }
        .tag(SidebarSelection.location(connectionID: place.connectionID, path: place.path))
        .help("/\(place.path.joined)")
        .accessibilityLabel(
            providerKind.map { "\(place.name), on \($0.displayName)" } ?? place.name
        )
    }
}

private struct ConnectionRow: View {
    @Environment(AppModel.self) private var model
    let connection: Connection

    private var status: ConnectionStatus {
        model.connections.status(of: connection.id)
    }

    var body: some View {
        HStack(spacing: Theme.Space.sm) {
            Image(systemName: connection.kind.symbol)
                .font(.system(size: Theme.Icon.sm))
                .frame(width: Theme.Icon.lg)
                .foregroundStyle(connection.kind.tint)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 0) {
                Text(connection.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if connection.kind != .local {
                    Text(connection.kind.displayName)
                        .font(Theme.Typo.micro)
                        .foregroundStyle(Theme.Ink.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)

            if connection.kind != .local {
                StatusIndicator(status: status)
            }
        }
        .tag(SidebarSelection.location(connectionID: connection.id, path: .root))
        .accessibilityLabel(
            connection.kind == .local
                ? connection.name
                : "\(connection.name), \(connection.kind.displayName), \(status.label)"
        )
        .contextMenu { contextMenu }
    }

    @ViewBuilder
    private var contextMenu: some View {
        Button("Open") { model.go(to: connection) }

        Button(model.isDualPane ? "Open in Other Pane" : "Open in Second Pane") {
            // Opens the second pane if it is closed, which is how a drag
            // between two services gets set up in one step.
            if !model.isDualPane { model.isDualPane = true }
            let other: AppModel.Pane = model.activePane == .left ? .right : .left
            model.pane(other).switchTo(connection: connection, path: .root)
        }

        if connection.kind != .local {
            Divider()
            Button("Reconnect") { model.connections.reconnect(connection.id) }
            Button("Edit…") { model.presentation = .editConnection(connection) }
            Divider()
            Button("Remove Connection", role: .destructive) {
                model.connections.remove(connection.id)
            }
            if let message = status.message {
                Divider()
                Section("Last error") {
                    Text(message)
                }
            }
        }
    }
}
