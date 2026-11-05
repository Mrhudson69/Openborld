import SwiftUI
import OpenborldCore

/// Add or edit a connection: pick a provider, fill in credentials, test, save.
struct ConnectionEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let existing: Connection?

    @State private var kind: ProviderKind?
    @State private var draft = Connection(name: "", kind: .azureBlob)
    @State private var secrets = ConnectionSecrets()
    @State private var testState: TestState = .untested
    @State private var searchText = ""

    private enum TestState: Equatable {
        case untested
        case testing
        case passed
        case failed(String)
    }

    var body: some View {
        VStack(spacing: 0) {
            if let kind {
                credentialForm(for: kind)
            } else {
                providerPicker
            }
        }
        .frame(width: 540, height: 540)
        .onAppear(perform: prepare)
    }

    private func prepare() {
        if let existing {
            kind = existing.kind
            draft = existing
            secrets = model.connections.secrets(for: existing.id)
        }
    }

    // MARK: - Provider picker

    private var providerPicker: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Add a Connection")
                            .font(Theme.Typo.largeTitle)
                        Text("Pick where your files live.")
                            .font(Theme.Typo.caption)
                            .foregroundStyle(Theme.Ink.secondary)
                    }
                    Spacer()
                    Button("Cancel") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                }
                SearchField(text: $searchText, placeholder: "Search providers")
            }
            .padding(18)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(ProviderKind.Category.allCases) { category in
                        let providers = filtered(in: category)
                        if !providers.isEmpty {
                            VStack(alignment: .leading, spacing: 7) {
                                Text(category.rawValue.uppercased())
                                    .font(Theme.Typo.eyebrow)
                                    .foregroundStyle(Theme.Ink.secondary)
                                    .tracking(0.6)

                                LazyVGrid(
                                    columns: [GridItem(.adaptive(minimum: 158), spacing: 8)],
                                    spacing: 8
                                ) {
                                    ForEach(providers) { provider in
                                        ProviderTile(kind: provider) {
                                            select(provider)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(18)
            }
        }
    }

    private func filtered(in category: ProviderKind.Category) -> [ProviderKind] {
        ProviderKind.allCases
            .filter { $0 != .local && $0.category == category }
            .filter {
                searchText.isEmpty
                    || $0.displayName.localizedCaseInsensitiveContains(searchText)
            }
    }

    private func select(_ provider: ProviderKind) {
        kind = provider
        draft = Connection(
            name: model.connections.uniqueName(basedOn: provider.displayName),
            kind: provider
        )
        secrets = ConnectionSecrets()
        testState = .untested

        // Sensible starting auth method per provider.
        switch provider {
        case .azureBlob:
            draft[.authMethod] = AzureAuthMethod.sasURL.rawValue
        case .s3:
            draft[.region] = "us-east-1"
        case .backblazeB2:
            draft[.region] = "us-west-004"
        case .gcs:
            draft[.region] = "auto"
        default:
            break
        }
    }

    // MARK: - Credential form

    private func credentialForm(for provider: ProviderKind) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: provider.symbol)
                    .font(.system(size: Theme.Icon.hero))
                    .foregroundStyle(provider.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(existing == nil ? "Connect to \(provider.displayName)" : "Edit Connection")
                        .font(Theme.Typo.title)
                    Text(provider.displayName)
                        .font(Theme.Typo.caption)
                        .foregroundStyle(Theme.Ink.secondary)
                }
                Spacer()
                if existing == nil {
                    Button("Change") { kind = nil }
                        .controlSize(.small)
                }
            }
            .padding(18)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    FormField(label: "Display Name", hint: "What you'll see in the sidebar.") {
                        TextField("", text: $draft.name)
                            .textFieldStyle(.roundedBorder)
                    }

                    switch provider {
                    case .azureBlob:
                        AzureForm(draft: $draft, secrets: $secrets)
                    case .s3, .s3Compatible, .backblazeB2, .gcs:
                        S3Form(draft: $draft, secrets: $secrets, provider: provider)
                    case .webdav, .nextcloud, .ownCloud:
                        WebDAVForm(draft: $draft, secrets: $secrets, provider: provider)
                    default:
                        UnsupportedNotice(provider: provider)
                    }
                }
                .padding(18)
            }
            .onChange(of: draft.settings) { testState = .untested }
            .onChange(of: secrets.values) { testState = .untested }

            Divider()
            footer(for: provider)
        }
    }

    private func footer(for provider: ProviderKind) -> some View {
        HStack(spacing: 10) {
            switch testState {
            case .untested:
                Text("Test the connection before saving.")
                    .font(Theme.Typo.caption)
                    .foregroundStyle(Theme.Ink.secondary)
            case .testing:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("Connecting…").font(Theme.Typo.caption).foregroundStyle(Theme.Ink.secondary)
                }
            case .passed:
                Label("Connected", systemImage: "checkmark.circle.fill")
                    .font(Theme.Typo.caption)
                    .foregroundStyle(.green)
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(Theme.Typo.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }

            Spacer(minLength: 10)

            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)

            Button("Test") { test() }
                .disabled(!provider.isImplemented || testState == .testing)

            Button(existing == nil ? "Save" : "Save Changes") { save() }
                .keyboardShortcut(.defaultAction)
                .disabled(!provider.isImplemented || draft.name.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(.horizontal, 18)
        .frame(height: 50)
        .background(.bar)
    }

    private func test() {
        testState = .testing
        let connection = draft
        let credentials = secrets
        Task {
            do {
                try await ProviderRegistry.test(connection: connection, secrets: credentials)
                testState = .passed
            } catch {
                testState = .failed(TransferManager.describe(error))
            }
        }
    }

    private func save() {
        do {
            if existing == nil {
                try model.connections.add(draft, secrets: secrets)
                model.show("Added “\(draft.name)”.", level: .success)
                model.go(to: draft)
            } else {
                try model.connections.update(draft, secrets: secrets)
                model.show("Updated “\(draft.name)”.", level: .success)
            }
            dismiss()
        } catch {
            testState = .failed(TransferManager.describe(error))
        }
    }
}

private struct ProviderTile: View {
    let kind: ProviderKind
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: kind.symbol)
                    .font(.system(size: Theme.Icon.lg))
                    .foregroundStyle(kind.isImplemented ? AnyShapeStyle(kind.tint) : AnyShapeStyle(.tertiary))
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: 1) {
                    Text(kind.displayName)
                        .font(Theme.Typo.bodyStrong)
                        .lineLimit(1)
                    if !kind.isImplemented {
                        Text("Not available yet")
                            .font(.system(size: Theme.Icon.badge))
                            .foregroundStyle(Theme.Ink.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .background(
                hovering && kind.isImplemented
                    ? Color.accentColor.opacity(0.12)
                    : Color.primary.opacity(0.04),
                in: RoundedRectangle(cornerRadius: Theme.Radius.md)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.md)
                    .strokeBorder(
                        hovering && kind.isImplemented
                            ? Color.accentColor.opacity(0.4)
                            : Color.primary.opacity(0.06),
                        lineWidth: 1
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!kind.isImplemented)
        .onHover { hovering = $0 }
    }
}

/// Label, control, and an optional hint — the shape every credential field takes.
struct FormField<Content: View>: View {
    let label: String
    var hint: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(Theme.Typo.captionStrong)
            content
            if let hint {
                Text(hint)
                    .font(Theme.Typo.micro)
                    .foregroundStyle(Theme.Ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct UnsupportedNotice: View {
    let provider: ProviderKind

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Not available yet", systemImage: "wrench.and.screwdriver")
                .font(Theme.Typo.bodyStrong)
                .foregroundStyle(.orange)
            Text(reason)
                .font(Theme.Typo.caption)
                .foregroundStyle(Theme.Ink.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: Theme.Radius.md))
    }

    private var reason: String {
        switch provider.category {
        case .cloudDrive:
            return "\(provider.displayName) signs in through OAuth, which needs an app registration with the provider before it can be offered here."
        case .protocolBased:
            return "\(provider.displayName) needs its own protocol implementation rather than HTTP, so it's queued behind the object-storage providers."
        default:
            return "\(provider.displayName) isn't implemented yet."
        }
    }
}
