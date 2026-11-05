import SwiftUI
import OpenborldCore

/// Azure Blob Storage credentials.
///
/// The SAS URL path is first and preselected: it's the one route that needs
/// nothing but a paste, and it's how most people are handed access to a
/// container in practice.
struct AzureForm: View {
    @Binding var draft: Connection
    @Binding var secrets: ConnectionSecrets

    private var method: AzureAuthMethod {
        AzureAuthMethod(rawValue: draft.setting(.authMethod)) ?? .sasURL
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            FormField(label: "Authentication") {
                Picker("", selection: Binding(
                    get: { method },
                    set: { draft[.authMethod] = $0.rawValue }
                )) {
                    ForEach(AzureAuthMethod.allCases) { option in
                        Text(option.displayName)
                            .tag(option)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)

                Text(method.detail)
                    .font(Theme.Typo.micro)
                    .foregroundStyle(Theme.Ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            switch method {
            case .sasURL:
                FormField(
                    label: "SAS URL",
                    hint: "The whole container URL including the token, e.g. https://account.blob.core.windows.net/mycontainer?sv=…&sig=… The container it points at becomes this connection's root."
                ) {
                    SecretEditor(
                        text: binding(.sasURL),
                        placeholder: "https://account.blob.core.windows.net/container?sv=…",
                        multiline: true
                    )
                }
                SASPreview(url: secrets[.sasURL] ?? "")

            case .accountKey:
                FormField(label: "Storage Account Name") {
                    TextField("myaccount", text: setting(.accountName))
                        .textFieldStyle(.roundedBorder)
                }
                FormField(
                    label: "Account Key",
                    hint: "From the Azure portal, under Access keys. Stored in your login Keychain."
                ) {
                    SecretEditor(text: binding(.accountKey), placeholder: "base64 key")
                }
                FormField(
                    label: "Blob Endpoint (optional)",
                    hint: "Leave blank for the standard https://account.blob.core.windows.net. Set it for a sovereign cloud or a local emulator."
                ) {
                    TextField("https://account.blob.core.windows.net", text: setting(.blobEndpoint))
                        .textFieldStyle(.roundedBorder)
                }
                containerScopeField

            case .connectionString:
                FormField(
                    label: "Connection String",
                    hint: "Works with either an AccountKey or an embedded SharedAccessSignature."
                ) {
                    SecretEditor(
                        text: binding(.connectionString),
                        placeholder: "DefaultEndpointsProtocol=https;AccountName=…;AccountKey=…",
                        multiline: true
                    )
                }
                containerScopeField

            case .accountURLAndSAS:
                FormField(label: "Account URL") {
                    TextField("https://account.blob.core.windows.net", text: setting(.blobEndpoint))
                        .textFieldStyle(.roundedBorder)
                }
                FormField(label: "SAS Token", hint: "Just the query string — a leading ? is fine.") {
                    SecretEditor(text: binding(.sasToken), placeholder: "sv=…&ss=b&srt=sco&sp=rl&sig=…")
                }
                containerScopeField

            case .managedIdentity:
                UnsupportedNotice(provider: .azureBlob)
            }

            AdvancedTransferSettings(draft: $draft)
        }
    }

    private var containerScopeField: some View {
        FormField(
            label: "Container (optional)",
            hint: "Leave blank to browse every container in the account. Set it to start inside one container."
        ) {
            TextField("mycontainer", text: setting(.containerScope))
                .textFieldStyle(.roundedBorder)
        }
    }

    private func setting(_ key: SettingKey) -> Binding<String> {
        Binding(
            get: { draft.setting(key) },
            set: { draft[key] = $0 }
        )
    }

    private func binding(_ key: SecretKey) -> Binding<String> {
        Binding(
            get: { secrets.secret(key) ?? "" },
            set: { secrets[key] = $0 }
        )
    }
}

/// Decodes a pasted SAS URL and shows what it actually grants, so a wrong or
/// expired token is caught before the first request rather than after.
private struct SASPreview: View {
    let url: String

    private struct Parsed {
        var account: String
        var container: String?
        var permissions: String?
        var expiry: Date?
        var resource: String?
    }

    private var parsed: Parsed? {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let components = URLComponents(string: trimmed),
              let host = components.host,
              let items = components.queryItems,
              items.contains(where: { $0.name == "sig" })
        else { return nil }

        let path = components.path.split(separator: "/").map(String.init)
        func value(_ name: String) -> String? {
            items.first { $0.name == name }?.value
        }
        return Parsed(
            account: host.split(separator: ".").first.map(String.init) ?? host,
            container: path.first,
            permissions: value("sp"),
            expiry: value("se").flatMap(HTTPDate.parseISO8601),
            resource: value("srt") ?? value("sr")
        )
    }

    var body: some View {
        if let parsed {
            VStack(alignment: .leading, spacing: 5) {
                row("Account", parsed.account)
                if let container = parsed.container {
                    row("Container", container)
                } else {
                    row("Scope", "Whole account")
                }
                if let permissions = parsed.permissions {
                    row("Permissions", describe(permissions))
                }
                if let expiry = parsed.expiry {
                    let expired = expiry < Date()
                    HStack(spacing: 5) {
                        Text("Expires")
                            .font(Theme.Typo.micro)
                            .foregroundStyle(Theme.Ink.secondary)
                            .frame(width: 72, alignment: .leading)
                        Text(DateFormatter.openborldFull.string(from: expiry))
                            .font(Theme.Typo.mono)
                        if expired {
                            Label("Expired", systemImage: "exclamationmark.triangle.fill")
                                .font(Theme.Typo.micro)
                                .foregroundStyle(.red)
                        }
                    }
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.accentColor.opacity(0.07), in: RoundedRectangle(cornerRadius: Theme.Radius.md))
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(spacing: 5) {
            Text(label)
                .font(Theme.Typo.micro)
                .foregroundStyle(Theme.Ink.secondary)
                .frame(width: 72, alignment: .leading)
            Text(value)
                .font(Theme.Typo.mono)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    /// Turns `rwdl` into words, since the letters are easy to misread.
    private func describe(_ permissions: String) -> String {
        let names: [Character: String] = [
            "r": "read", "w": "write", "d": "delete", "l": "list",
            "a": "add", "c": "create", "u": "update", "p": "process",
            "t": "tags", "f": "filter", "i": "set-immutability", "y": "permanent-delete",
            "x": "delete-version", "m": "move", "e": "execute",
        ]
        let described = permissions.compactMap { names[$0] }
        return described.isEmpty ? permissions : described.joined(separator: ", ")
    }
}

/// S3 and every S3-compatible endpoint.
struct S3Form: View {
    @Binding var draft: Connection
    @Binding var secrets: ConnectionSecrets
    let provider: ProviderKind

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            FormField(label: "Access Key ID") {
                TextField("AKIA…", text: setting(.accessKeyID))
                    .textFieldStyle(.roundedBorder)
            }

            FormField(label: "Secret Access Key", hint: "Stored in your login Keychain.") {
                SecretEditor(text: binding(.secretAccessKey), placeholder: "secret")
            }

            if provider == .s3 || provider == .backblazeB2 {
                FormField(label: "Region") {
                    TextField(
                        provider == .backblazeB2 ? "us-west-004" : "us-east-1",
                        text: setting(.region)
                    )
                    .textFieldStyle(.roundedBorder)
                }
            }

            if provider == .s3Compatible {
                FormField(
                    label: "Endpoint",
                    hint: "The S3 API endpoint, e.g. https://s3.wasabisys.com, https://minio.example.com, or an R2 account URL."
                ) {
                    TextField("https://s3.example.com", text: setting(.endpoint))
                        .textFieldStyle(.roundedBorder)
                }
                FormField(label: "Region", hint: "Many compatible providers accept us-east-1 or auto.") {
                    TextField("us-east-1", text: setting(.region))
                        .textFieldStyle(.roundedBorder)
                }
            }

            if provider == .gcs {
                FormField(
                    label: "Interoperability",
                    hint: "Google Cloud Storage is reached through its S3-compatible XML API. Create an HMAC key under Cloud Storage › Settings › Interoperability and use it above."
                ) {
                    EmptyView()
                }
            }

            FormField(
                label: "Bucket (optional)",
                hint: "Leave blank to list every bucket. Set it when the credentials only allow one — listing buckets would fail."
            ) {
                TextField("my-bucket", text: setting(.bucketScope))
                    .textFieldStyle(.roundedBorder)
            }

            Toggle(isOn: Binding(
                get: { draft.boolSetting(.usePathStyle, default: provider != .s3) },
                set: { draft[.usePathStyle] = $0 ? "true" : "false" }
            )) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Path-style addressing").font(Theme.Typo.caption)
                    Text("Puts the bucket in the path instead of the hostname. Required by most non-AWS endpoints.")
                        .font(Theme.Typo.micro)
                        .foregroundStyle(Theme.Ink.secondary)
                }
            }
            .toggleStyle(.checkbox)

            AdvancedTransferSettings(draft: $draft)
        }
    }

    private func setting(_ key: SettingKey) -> Binding<String> {
        Binding(get: { draft.setting(key) }, set: { draft[key] = $0 })
    }

    private func binding(_ key: SecretKey) -> Binding<String> {
        Binding(get: { secrets.secret(key) ?? "" }, set: { secrets[key] = $0 })
    }
}

struct WebDAVForm: View {
    @Binding var draft: Connection
    @Binding var secrets: ConnectionSecrets
    let provider: ProviderKind

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            FormField(label: "Server Address") {
                TextField("https://cloud.example.com", text: setting(.host))
                    .textFieldStyle(.roundedBorder)
            }

            FormField(label: "Username") {
                TextField("", text: setting(.username))
                    .textFieldStyle(.roundedBorder)
            }

            FormField(
                label: "Password",
                hint: provider == .nextcloud
                    ? "Use an app password if your account has two-factor authentication."
                    : "Stored in your login Keychain."
            ) {
                SecretEditor(text: binding(.password), placeholder: "password")
            }

            FormField(
                label: "Base Path (optional)",
                hint: provider == .webdav
                    ? "The WebDAV root on the server, e.g. /dav or /remote.php/dav/files/user."
                    : "Leave blank — /remote.php/dav/files/<username> is used automatically."
            ) {
                TextField(
                    provider == .webdav ? "/dav" : "/remote.php/dav/files/username",
                    text: setting(.basePath)
                )
                .textFieldStyle(.roundedBorder)
            }

            AdvancedTransferSettings(draft: $draft)
        }
    }

    private func setting(_ key: SettingKey) -> Binding<String> {
        Binding(get: { draft.setting(key) }, set: { draft[key] = $0 })
    }

    private func binding(_ key: SecretKey) -> Binding<String> {
        Binding(get: { secrets.secret(key) ?? "" }, set: { secrets[key] = $0 })
    }
}

/// Per-connection transfer tuning, folded away because the defaults are right
/// for nearly everyone.
struct AdvancedTransferSettings: View {
    @Binding var draft: Connection
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 12) {
                FormField(
                    label: "Parallel chunks per file",
                    hint: "How many pieces of one large file upload at once."
                ) {
                    Stepper(
                        value: Binding(
                            get: { draft.intSetting(.maxConcurrentTransfers) ?? 4 },
                            set: { draft[.maxConcurrentTransfers] = String($0) }
                        ),
                        in: 1...16
                    ) {
                        Text("\(draft.intSetting(.maxConcurrentTransfers) ?? 4)")
                            .font(Theme.Typo.caption)
                            .monospacedDigit()
                    }
                    .controlSize(.small)
                }

                FormField(
                    label: "Chunk size",
                    hint: "Larger chunks mean fewer requests but more memory per transfer."
                ) {
                    Picker("", selection: Binding(
                        get: { draft.intSetting(.chunkSizeBytes) ?? (8 * 1024 * 1024) },
                        set: { draft[.chunkSizeBytes] = String($0) }
                    )) {
                        Text("4 MB").tag(4 * 1024 * 1024)
                        Text("8 MB").tag(8 * 1024 * 1024)
                        Text("16 MB").tag(16 * 1024 * 1024)
                        Text("32 MB").tag(32 * 1024 * 1024)
                        Text("64 MB").tag(64 * 1024 * 1024)
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 110)
                }
            }
            .padding(.top, 8)
        } label: {
            Text("Advanced")
                .font(Theme.Typo.captionStrong)
        }
    }
}

/// A secret field that can be revealed. Hiding it by default is right, but a
/// pasted key is too easy to get wrong to never be able to check.
struct SecretEditor: View {
    @Binding var text: String
    let placeholder: String
    var multiline = false

    @State private var revealed = false

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            if revealed {
                if multiline {
                    TextEditor(text: $text)
                        .font(Theme.Typo.mono)
                        .frame(height: 54)
                        .padding(3)
                        .overlay(
                            RoundedRectangle(cornerRadius: 5)
                                .strokeBorder(Color.primary.opacity(0.16), lineWidth: 1)
                        )
                } else {
                    TextField(placeholder, text: $text)
                        .textFieldStyle(.roundedBorder)
                        .font(Theme.Typo.mono)
                }
            } else {
                SecureField(placeholder, text: $text)
                    .textFieldStyle(.roundedBorder)
            }

            IconButton(
                symbol: revealed ? "eye.slash" : "eye",
                label: revealed ? "Hide value" : "Show value",
                detail: revealed
                    ? "Mask this credential again"
                    : "Reveal this credential to check it",
                size: Theme.Icon.xs,
                isActive: revealed
            ) {
                revealed.toggle()
            }
            .foregroundStyle(Theme.Ink.secondary)
        }
    }
}
