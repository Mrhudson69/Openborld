import SwiftUI
import AppKit
import OpenborldCore

/// Rules for container/bucket names, checked before the request so the user
/// gets a specific reason rather than a provider error.
enum ContainerNameRules {
    static func validate(_ name: String) -> String? {
        let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty { return nil }
        if value.count < 3 || value.count > 63 {
            return "Must be between 3 and 63 characters."
        }
        if value != value.lowercased() {
            return "Must be lowercase."
        }
        if value.hasPrefix("-") || value.hasSuffix("-") {
            return "Can't start or end with a hyphen."
        }
        if value.contains("--") {
            return "Can't contain two hyphens in a row."
        }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-")
        if value.unicodeScalars.contains(where: { !allowed.contains($0) }) {
            return "Use only lowercase letters, numbers, and hyphens."
        }
        return nil
    }
}

/// One text field, one confirm button — new folder, new container, rename.
struct TextPromptSheet: View {
    @Environment(\.dismiss) private var dismiss

    let title: String
    let message: String
    let placeholder: String
    var initialValue: String = ""
    let confirmLabel: String
    var validator: ((String) -> String?)? = nil
    let onConfirm: (String) -> Void

    @State private var text = ""
    @FocusState private var focused: Bool

    private var validationError: String? {
        validator?(text)
    }

    private var canConfirm: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && validationError == nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(Theme.Typo.title)
                Text(message).font(Theme.Typo.caption).foregroundStyle(Theme.Ink.secondary)
            }

            TextField(placeholder, text: $text)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit { confirm() }

            if let validationError {
                Label(validationError, systemImage: "exclamationmark.circle")
                    .font(Theme.Typo.caption)
                    .foregroundStyle(.orange)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(confirmLabel) { confirm() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canConfirm)
            }
        }
        .padding(18)
        .frame(width: 360)
        .onAppear {
            text = initialValue
            focused = true
        }
    }

    private func confirm() {
        guard canConfirm else { return }
        onConfirm(text)
        dismiss()
    }
}

struct DeleteConfirmSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let pane: AppModel.Pane
    let items: [CloudItem]

    private var isLocal: Bool { model.pane(pane).connection.kind == .local }
    private var hasFolders: Bool { items.contains(where: \.isDirectory) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "trash")
                    .font(.system(size: Theme.Icon.hero, weight: .light))
                    .foregroundStyle(.red)
                VStack(alignment: .leading, spacing: 3) {
                    Text(headline).font(Theme.Typo.title)
                    Text(detail).font(Theme.Typo.caption).foregroundStyle(Theme.Ink.secondary)
                }
            }

            if items.count > 1 {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(items) { item in
                            HStack(spacing: 5) {
                                Image(systemName: item.symbol)
                                    .font(Theme.Typo.micro)
                                    .foregroundStyle(item.symbolColor)
                                Text(item.name)
                                    .font(Theme.Typo.caption)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 130)
                .padding(8)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 5))
            }

            HStack {
                Toggle("Don't ask again", isOn: Binding(
                    get: { !model.settings.confirmDeletes },
                    set: { model.settings.confirmDeletes = !$0 }
                ))
                .font(Theme.Typo.caption)
                .toggleStyle(.checkbox)

                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Delete") {
                    model.performDelete(items, in: pane)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 400)
    }

    private var headline: String {
        items.count == 1
            ? "Delete “\(items[0].name)”?"
            : "Delete \(items.count) items?"
    }

    private var detail: String {
        if isLocal {
            // Only macOS has a Trash; elsewhere a local delete is permanent,
            // and the confirmation must not imply otherwise.
            return LocalProvider.deleteIsRecoverable
                ? "They'll be moved to the Trash."
                : "They'll be deleted permanently from this computer."
        }
        if hasFolders {
            return "Folders are deleted along with everything inside them. This can't be undone."
        }
        return "This can't be undone."
    }
}

struct ShareLinkSheet: View {
    @Environment(\.dismiss) private var dismiss
    let name: String
    let url: URL
    let isConnectionToken: Bool

    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Share “\(name)”").font(Theme.Typo.title)
                Text(isConnectionToken
                    ? "This link reuses the connection's own SAS token."
                    : "This link works for 24 hours, then expires.")
                    .font(Theme.Typo.caption)
                    .foregroundStyle(Theme.Ink.secondary)
            }

            if isConnectionToken {
                Label(
                    "It carries the same permissions and expiry as the token you connected with, which may allow more than reading this one file.",
                    systemImage: "exclamationmark.shield"
                )
                .font(Theme.Typo.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            }

            ScrollView {
                Text(url.absoluteString)
                    .font(Theme.Typo.mono)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 70)
            .padding(8)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 5))

            HStack {
                Button("Open in Browser") { NSWorkspace.shared.open(url) }
                Spacer()
                Button("Done") { dismiss() }
                Button(copied ? "Copied" : "Copy Link") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url.absoluteString, forType: .string)
                    copied = true
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 460)
    }
}

struct MetadataSheet: View {
    @Environment(\.dismiss) private var dismiss
    let connection: Connection
    let item: CloudItem

    @State private var rows: [(key: String, value: String)] = []
    @State private var isLoading = true
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 9) {
                Image(systemName: item.symbol)
                    .font(.system(size: Theme.Icon.hero, weight: .light))
                    .foregroundStyle(item.symbolColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name)
                        .font(Theme.Typo.title)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("\(connection.name) · /\(item.path.joined)")
                        .font(Theme.Typo.micro)
                        .foregroundStyle(Theme.Ink.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Divider()

            if isLoading {
                HStack(spacing: 7) {
                    ProgressView().controlSize(.small)
                    Text("Reading properties…").font(Theme.Typo.caption).foregroundStyle(Theme.Ink.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 120)
            } else if let error {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    Text(error).font(Theme.Typo.caption).foregroundStyle(Theme.Ink.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                            HStack(alignment: .top, spacing: 10) {
                                Text(row.key)
                                    .font(Theme.Typo.caption)
                                    .foregroundStyle(Theme.Ink.secondary)
                                    .frame(width: 140, alignment: .leading)
                                Text(row.value)
                                    .font(Theme.Typo.mono)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(.vertical, 4)
                            .padding(.horizontal, 8)
                            .background(
                                index.isMultiple(of: 2)
                                    ? Color.clear
                                    : Color.primary.opacity(0.03)
                            )
                        }
                    }
                }
                .frame(maxHeight: 340)
            }

            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 520)
        .task { await load() }
    }

    private func load() async {
        do {
            let provider = try await ProviderRegistry.shared.validatedProvider(for: connection)
            let result = try await provider.metadata(item.path)
            rows = result.isEmpty
                ? [(key: "Properties", value: "This provider reports no extra properties.")]
                : result
        } catch {
            self.error = TransferManager.describe(error)
        }
        isLoading = false
    }
}

struct ConflictSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let prompt: AppModel.ConflictPrompt

    @State private var applyToAll = true

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: Theme.Icon.hero, weight: .light))
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 3) {
                    Text(prompt.conflictingNames.count == 1
                        ? "“\(prompt.conflictingNames[0])” already exists"
                        : "\(prompt.conflictingNames.count) items already exist")
                        .font(Theme.Typo.title)
                    Text("In \(prompt.destination.label).")
                        .font(Theme.Typo.caption)
                        .foregroundStyle(Theme.Ink.secondary)
                }
            }

            if prompt.conflictingNames.count > 1 {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(prompt.conflictingNames, id: \.self) { name in
                            Text(name).font(Theme.Typo.caption).lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 100)
                .padding(8)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 5))
            }

            Toggle("Apply to all conflicts in this transfer", isOn: $applyToAll)
                .font(Theme.Typo.caption)
                .toggleStyle(.checkbox)

            HStack(spacing: 8) {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Skip") { resolve(.skip) }
                Button("Keep Both") { resolve(.rename) }
                Button("Replace") { resolve(.overwrite) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 440)
    }

    private func resolve(_ policy: ConflictPolicy) {
        if applyToAll { model.settings.conflictPolicy = policy }
        model.resolveConflict(prompt, with: policy)
        dismiss()
    }
}
