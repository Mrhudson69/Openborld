# Contributing to Openborld

Thanks for considering it. This document covers how to get set up, the
conventions this codebase actually follows, and how to add a storage provider —
which is the most useful thing most people can contribute.

If anything here is wrong or out of date, that's a bug. Open an issue.

---

## Contents

- [Getting set up](#getting-set-up)
- [Before you open a PR](#before-you-open-a-pr)
- [Developer Certificate of Origin](#developer-certificate-of-origin)
- [What we're looking for](#what-were-looking-for)
- [Adding a provider](#adding-a-provider)
- [Code conventions](#code-conventions)
- [UI conventions](#ui-conventions)
- [Testing](#testing)
- [Cross-platform UI](#cross-platform-ui)

---

## Getting set up

You need Swift 6.0+ and Python 3 (for the mock server the tests use). Xcode is
not required.

```bash
git clone https://github.com/Mrhudson69/Openborld.git
cd Openborld
swift build
swift run openborld-tests
bash Scripts/build-app.sh && open build/Openborld.app
```

If `swift build` can't find `sqlite3.h`, install the headers:
`apt-get install libsqlite3-dev` on Debian/Ubuntu. macOS has them in the SDK.

### Working on the UI without an Apple Developer account

You don't need one. `Scripts/build-app.sh` ad-hoc signs the bundle, which runs
fine on the machine that built it.

---

## Before you open a PR

Run these three. CI runs them too, but finding out locally is faster:

```bash
swift build -c release            # must build with no warnings
swift run openborld-tests         # must be 100% green
bash Scripts/check-portability.sh # no Apple-only API in the core
```

Then:

- **Keep the diff to one concern.** A provider fix and a UI refactor are two
  PRs. Large, focused PRs are fine; large, mixed ones are not.
- **Add a test for behaviour you changed**, especially anything touching
  request signing, path handling, or transfer resume. If a bug reached `main`,
  it means no test covered it — the fix should include the test that would
  have.
- **Describe what you verified**, not just what you wrote. "Tested against a
  real Wasabi bucket" is worth more than a green checkbox.
- **Say what you *didn't* verify.** We'd much rather merge "works on S3,
  untested on GCS" than discover that later.

Maintainers may ask for changes or decline a PR. That's a scoping judgement,
not a verdict on your work.

---

## Developer Certificate of Origin

Openborld uses the [DCO](https://developercertificate.org/). There's no CLA and
no paperwork — you just certify that you have the right to submit the code, by
signing off each commit:

```bash
git commit -s -m "Add OpenStack Swift provider"
```

That appends a line to the message:

```
Signed-off-by: Your Name <your.email@example.com>
```

Use your real name and a working email. If you forget, fix the last commit
with `git commit --amend -s`, or a whole branch with
`git rebase --signoff main`.

---

## What we're looking for

Ordered roughly by how much they'd help:

1. **Provider implementations.** OpenStack Swift and SFTP are the most
   requested. See [Adding a provider](#adding-a-provider).
2. **Verifying the Linux build.** The core was made portable but has never
   been compiled on Linux. Getting `swift run openborld-tests` green in a
   `swift:6.0` container — and fixing whatever corelibs-Foundation gaps turn
   up — would turn a claim into a fact.
3. **Testing against real services.** The integration suite runs against a
   local mock. Reports of real-world behaviour with Wasabi, R2, MinIO, Ceph,
   sovereign Azure clouds, or Nextcloud are genuinely valuable, and so are
   bug reports from them.
4. **Column view.** The view-mode picker offers List and Grid; Columns is
   declared but falls back to List.
5. **Accessibility and localisation.** Everything is currently English-only.

### OAuth providers

Google Drive, Dropbox, OneDrive, SharePoint, and Box all need an OAuth app
registered with the vendor, which means a client ID shipped in the binary and
a redirect flow. This is a design question as much as a coding one — a public
client ID in an open-source app is normal practice but has trade-offs. Please
open an issue to discuss the approach before writing the code.

---

## Adding a provider

Every backend implements one protocol and the UI needs no changes. Here's the
whole path.

### 1. Declare the kind

In `Sources/OpenborldCore/Models/ProviderKind.swift`, add a case and fill in
`displayName`, `symbol` (an SF Symbol), `category`, and `containerNoun` (what
this service calls a top-level namespace — "Bucket", "Container", "Share").

Leave it out of `isImplemented` until it works. That flag is what makes the
connection picker grey it out instead of offering something broken.

### 2. Implement `StorageProvider`

Create `Sources/OpenborldCore/Providers/<Name>Provider.swift`. The protocol is
in `Providers/StorageProvider.swift`; sensible defaults exist for most of it,
so a minimal provider implements:

```swift
var connection: Connection { get }
var capabilities: ProviderCapabilities { get }
func validate() async throws
func list(_ path: RemotePath, cursor: String?, pageSize: Int) async throws -> Listing
func createFolder(at path: RemotePath) async throws
func delete(_ item: CloudItem) async throws
func download(_ item: CloudItem, to localURL: URL, progress: ProgressHandler?) async throws
func upload(_ localURL: URL, to path: RemotePath, contentType: String?, progress: ProgressHandler?) async throws -> CloudItem
func readStream(_ item: CloudItem) async throws -> AsyncThrowingStream<Data, Error>
```

Things that matter more than they look:

- **Be honest in `capabilities`.** The UI disables what you don't advertise.
  Claiming `.serverSideCopy` you haven't implemented produces a confusing
  failure mid-transfer instead of a clean greyed-out menu item.
- **Stream; never buffer a whole object.** Use `HTTPClient.download(_:to:)`
  and `upload(_:fromFile:)`. A 50 GB file must not cost 50 GB of RAM.
- **Honour `Task.cancellation`** in any loop.
- **Page properly.** Return a `nextCursor`; don't enumerate a million objects
  in one call.
- **Throw `StorageError` with a message a user can act on.** `"Enter the
  storage account name."` beats `"invalid configuration"`.

### 3. Build it in the factory

Add your case to `ProviderFactory.make` in
`Sources/OpenborldCore/Services/ProviderRegistry.swift`.

### 4. Add the credential form

In `Sources/Openborld/Views/CredentialForms.swift`, add a `View` following the
existing ones, and route to it from `ConnectionEditor.credentialForm(for:)`.
Use `FormField` for layout and `SecretEditor` for anything secret — it masks
by default and offers a reveal toggle.

Non-secret settings go in `Connection.settings` via `SettingKey`; secrets go in
`ConnectionSecrets` via `SecretKey`, which routes to the Keychain. **Never put
a secret in `settings`** — that file is written to disk in the clear.

### 5. Teach the mock server about it

If your provider speaks HTTP, add a front end to `Tests/Support/mock_cloud.py`
and an integration suite in
`Sources/OpenborldTestRunner/ProviderTests.swift`. If it has its own request
signing, **verify signatures in the mock independently** rather than trusting
the client — that's the pattern that caught the trailing-slash bug, and it's
the difference between a test that proves something and one that doesn't.

### 6. Flip `isImplemented`

Only once it genuinely works.

---

## Code conventions

The codebase is consistent about a few things. Please match them.

**Comments explain *why*, never *what*.** The code already says what it does.

```swift
// Good — explains a decision the code can't:
// Azure wants an empty string rather than "0" for an absent body.
let lengthField = contentLength > 0 ? String(contentLength) : ""

// Noise — delete this:
// Set lengthField to the content length
```

**Errors name the fix, not just the failure.**

```swift
throw StorageError.invalidConfiguration(
    "The account key isn't valid base64. Copy it again from the Azure portal."
)
```

**Concurrency:** providers are `Sendable`; UI state is `@MainActor` and
`@Observable`. Never block the main actor on network work.

**No new third-party dependencies** without discussion. The project currently
depends on swift-crypto and nothing else, and that's deliberate — it's part of
why the app is 6 MB.

**Portability:** `OpenborldCore` must not import AppKit, SwiftUI, CryptoKit,
or UniformTypeIdentifiers outside a `#if canImport(…)` guard.
`Scripts/check-portability.sh` will fail the build if it does.

---

## UI conventions

The app layer follows rules derived from WCAG and Apple's HIG. CI can't check
most of these, so reviewers do.

- **Use design tokens, never literals.** Sizes, spacing, colours, and
  animation durations all live in `Sources/Openborld/Views/Theme.swift`.
  A raw `.font(.system(size: 13))` or `Color.red` in a view is a review
  comment.
- **Every icon-only control needs an accessible name.** Use `IconButton`,
  which requires a `label`. A `.help()` tooltip is not a substitute — it's
  invisible to VoiceOver and to keyboard users.
- **Never signal state with colour alone.** Pair it with a glyph or text, the
  way `StatusIndicator` does.
- **Respect reduced motion.** Read `@Environment(\.reducedMotion)` and skip
  the animation when it's set.
- **Check contrast in both appearances.** New colours must clear 4.5:1 for
  text and 3:1 for non-text UI, in light *and* dark. macOS's own
  `secondaryLabelColor` measures 3.98:1 and `tertiaryLabelColor` 1.88:1 — this
  is why `Theme.Ink.secondary` is a measured custom grey rather than the
  system one.

---

## Testing

```bash
swift run openborld-tests
swift run openborld-tests --diagnose   # prints signature mismatches in full
```

The runner is a plain executable (`Sources/OpenborldTestRunner`) rather than
XCTest, because XCTest requires Xcode and this project deliberately builds with
just the Command Line Tools. Add unit tests to `UnitTests.swift` and provider
tests to `ProviderTests.swift`.

A test should fail for exactly one reason and say which in its name.
`"a trailing slash survives into the canonical path"` is a good name;
`"testSigning"` is not.

When fixing a bug, add the test that would have caught it, and put the *reason*
in a comment — the regression tests in `UnitTests.swift` under
"Signing regressions" are the model.

---

## Cross-platform UI

The core is portable; the SwiftUI app is not and cannot be. Shipping on Linux
and Windows needs a UI strategy, and this is an open design question. The
options, with their honest costs:

1. **Local service + web UI** (Tauri, or the system webview). The core runs as
   a local daemon; the UI talks to it over HTTP. Keeps all the provider and
   signing code. Loses the native macOS feel. *Largest reuse.*
2. **Qt or GTK front end** over a C ABI exposed from Swift. Native-ish
   everywhere, but Swift bindings for both are immature and the FFI boundary
   is real work.
3. **Full rewrite** in Electron, Flutter, or Compose Multiplatform. Discards
   the tested Azure and SigV4 implementations; Electron also contradicts the
   project's size goals.
4. **Keep SwiftUI for macOS and ship a CLI elsewhere.** Smallest step; the
   core already supports it.

Option 1 preserves the most value. Nothing has been decided — if you have
experience here, please open an issue rather than a 10,000-line PR.
