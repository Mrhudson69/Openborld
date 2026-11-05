<div align="center">

# Openborld

**A free, open-source cloud storage manager for macOS — S3, Azure Blob, and WebDAV in one window.**

[![CI](https://github.com/Mrhudson69/Openborld/actions/workflows/ci.yml/badge.svg)](https://github.com/Mrhudson69/Openborld/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-macOS%2014%2B-lightgrey.svg)](#install)
[![Swift](https://img.shields.io/badge/Swift-6.0-orange.svg)](https://swift.org)
[![PRs welcome](https://img.shields.io/badge/PRs-welcome-brightgreen.svg)](CONTRIBUTING.md)

[Install](#install) · [Setup](#setup-adding-a-connection) · [Features](#features) · [Contributing](CONTRIBUTING.md) · [Alternatives](#how-it-compares)

</div>

---

Openborld is a **free and open-source desktop client** for cloud object
storage. Connect **Amazon S3**, **Azure Blob Storage**, **Backblaze B2**,
**Google Cloud Storage**, **MinIO**, **Wasabi**, **Cloudflare R2**,
**Nextcloud**, **ownCloud**, or any **S3-compatible** or **WebDAV** endpoint,
and browse them like folders on your Mac — with a dual-pane file manager for
dragging files between two different clouds.

No subscription. No account. No telemetry. No file-size limits.
A 6 MB app that idles around 60 MB of memory.

> **Status: early, and honest about it.** The Azure, S3, and WebDAV providers
> are implemented and covered by an integration suite that verifies every
> request signature against an independent implementation. The cloud-drive
> providers (Google Drive, Dropbox, OneDrive…) and the file-transfer protocols
> (FTP, SFTP, SMB) are **not** implemented — the connection picker marks them
> unavailable rather than offering something that fails on first use.
> See [Provider support](#provider-support).

---

## Contents

- [Features](#features)
- [Install](#install)
- [Build from source](#build-from-source)
- [Setup: adding a connection](#setup-adding-a-connection)
- [Using Openborld](#using-openborld)
- [Provider support](#provider-support)
- [Where your data lives](#where-your-data-lives)
- [Architecture](#architecture)
- [Testing](#testing)
- [Cross-platform status](#cross-platform-status)
- [Contributing](#contributing)
- [Licence](#licence)

---

## Features

**Browse**
Finder-like list and grid views, sortable columns, breadcrumb path bar with
copy-path, search within a folder, favourites, bookmarks, and recents.

**Dual pane**
Put two locations side by side — local and Azure, S3 and Azure, one container
and another — and drag between them. Each pane's connection is switchable from
its path bar.

**Transfer**
A queue with per-transfer progress, speed, and ETA; pause, resume, retry, and
cancel; configurable concurrency; conflict handling (replace / skip / keep
both). Transfers stream, so a 50 GB file costs no more memory than a 50 KB one.

**Resume that actually resumes**
Interrupted uploads pick up where they stopped — Azure block staging is queried
for already-committed blocks, S3 multipart uploads for already-sent parts.
Downloads resume with HTTP range requests.

**Server-side copy**
Copying within one account never round-trips through your machine.

**Accessible**
Every control has an accessible name, visible keyboard focus, and a non-colour
indicator for state. All 30 colour tokens are verified against WCAG contrast
floors in both light and dark appearance.

---

## Install

### Download a release

Grab the latest `Openborld-<version>.zip` from
[Releases](../../releases), unzip, and drag `Openborld.app` to
`/Applications`.

**Unsigned builds need one extra step.** Builds that aren't signed with an
Apple Developer ID are quarantined by Gatekeeper, which reports the app as
damaged. To run it anyway:

```bash
xattr -dr com.apple.quarantine /Applications/Openborld.app
```

Then right-click the app → **Open**. This is a limitation of distributing
macOS software without a $99/yr Apple Developer account, not a sign of a
problem with the build. If a release is marked *notarized*, you can skip this.

### Requirements

macOS 14 (Sonoma) or later, Apple Silicon or Intel.

---

## Build from source

You need **Swift 6.0+**. Xcode is *not* required — the Command Line Tools are
enough.

```bash
xcode-select --install          # if you don't have the tools yet
git clone https://github.com/Mrhudson69/Openborld.git
cd Openborld

swift build -c release          # build everything
swift run openborld-tests       # run the test suite (needs python3)
bash Scripts/build-app.sh       # assemble build/Openborld.app
open build/Openborld.app
```

### Scripts

| Script | What it does |
|---|---|
| `Scripts/build-app.sh [debug\|release]` | Compiles and assembles `Openborld.app`, generates the icon, ad-hoc signs it. |
| `Scripts/release.sh ["Developer ID …"]` | Builds and packages a distributable `.zip`. Prints notarization steps. |
| `Scripts/check-portability.sh` | Fails if Apple-only API appears in the portable core. |
| `Scripts/make-icon.sh <out.icns>` | Draws the app icon from code. |

---

## Setup: adding a connection

Click **Add Connection** in the sidebar, choose a provider, fill in the
credentials, press **Test**, then **Save**. Credentials go to your Keychain,
never to a config file.

You can add as many connections as you like, including several of the same
provider — "Azure Production", "Azure Staging", "S3 Backups".

### Azure Blob Storage

Four ways in. Pick whichever matches what you were given.

**1. SAS URL** — the quickest. Paste a container URL that already contains its
token:

```
https://myaccount.blob.core.windows.net/mycontainer?sv=2022-11-02&ss=b&srt=sco&sp=rl&se=2026-01-01T00:00:00Z&sig=…
```

Openborld decodes it as you type and shows the account, container,
permissions (spelled out — `rwdl` becomes *read, write, delete, list*), and
expiry, flagging the token in red if it has already expired. The container
becomes the root of that connection. A URL with a folder path after the
container roots the connection at that folder.

**2. Account name + key** — full access to the whole account. Find the key in
the Azure portal under *Storage account → Security + networking → Access keys*.
Leave *Blob endpoint* blank unless you're on a sovereign cloud or an emulator.

**3. Connection string** — the whole string from the portal. Works with either
an `AccountKey=` or an embedded `SharedAccessSignature=`.

**4. Account URL + SAS token** — the endpoint and the token as separate fields.

> Only the account-key method can mint a fresh, narrowly-scoped link for an
> individual blob. With a SAS-based connection, **Copy Share Link** hands back
> the connection's own token, which may grant more than read on more than that
> one file. Openborld warns you when that happens.

*Managed Identity* is listed but unavailable: it requires running on Azure
infrastructure that exposes the IMDS endpoint, which a desktop Mac is not.

### Amazon S3

Access key ID, secret access key, and region. Leave the endpoint blank.
Set **Bucket** if your credentials only permit one bucket — otherwise
Openborld tries to list all buckets and the request is refused.

### S3-compatible (MinIO, Wasabi, Cloudflare R2, Ceph…)

Choose **S3-Compatible Storage**, give the endpoint
(`https://s3.wasabisys.com`, `https://minio.example.com:9000`, an R2 account
URL), and keep **Path-style addressing** on — most non-AWS endpoints require
it, and it's the default outside AWS.

### Backblaze B2

Use its S3-compatible credentials (*Application Keys* in the B2 console), with
the region shown on your bucket, e.g. `us-west-004`.

### Google Cloud Storage

GCS is reached through its S3-compatible XML API. Create an HMAC key under
*Cloud Storage → Settings → Interoperability* and use it as the access key and
secret. Region is `auto`.

### WebDAV, Nextcloud, ownCloud

Server address, username, password. For Nextcloud and ownCloud leave **Base
path** blank — `/remote.php/dav/files/<username>` is filled in for you. If
your account has two-factor authentication, generate an app password rather
than using your login password.

---

## Using Openborld

### Keyboard

| Shortcut | Action |
|---|---|
| `⌘N` | New folder |
| `⇧⌘N` | New connection |
| `⌘U` | Upload |
| `⇧⌘D` | Download selection |
| `⌘R` | Refresh (bypasses the cache) |
| `⌘[` / `⌘]` | Back / Forward |
| `⌘↑` | Enclosing folder |
| `⌥⌘2` | Toggle dual pane |
| `⌥⌘I` | Toggle inspector |
| `⇧⌘T` | Transfer queue |
| `⇧⌘.` | Show hidden files |
| `Return` | Open selection |

### Transferring between two services

1. Turn on dual pane (`⌥⌘2`).
2. Click the connection name in each pane's path bar to point it somewhere —
   left at your Mac, right at Azure, or S3 on one side and Azure on the other.
3. Drag files across, or use the arrow button in the toolbar.

Within one account the copy happens server-side. Across two different services
the data is streamed source → destination without being staged on disk.

You can also drag files in from Finder to upload them.

### Performance notes

Folder listings are cached, so revisiting a folder paints immediately while a
fresh listing loads behind it. Large directories page in progressively rather
than blocking on a full enumeration. Connections and their TLS sessions are
reused, so changing folders costs one request, not a reconnect.

If you'd rather always wait for live data, turn off *Show cached listings while
refreshing* in Settings → Cache.

---

## Provider support

| Provider | Status |
|---|---|
| **Azure Blob Storage** | ✅ SAS URL, account key, connection string, account URL + SAS. Block upload with resume, server-side copy, SAS minting, metadata, containers. |
| **Amazon S3** | ✅ SigV4, multipart upload with resume, batch delete, multipart copy >5 GB, presigned links. |
| **S3-compatible** (MinIO, Wasabi, R2, Ceph) | ✅ Same engine, path-style addressing. |
| **Backblaze B2** | ✅ Via the S3 API. |
| **Google Cloud Storage** | ✅ Via the S3-compatible XML API with HMAC keys. |
| **WebDAV / Nextcloud / ownCloud** | ✅ Full CRUD, atomic server-side move. |
| **Local disk** | ✅ APFS clone copies, Trash-aware delete. |
| Google Drive, Dropbox, OneDrive, SharePoint, Box, DRACOON, Files.com | ❌ Each needs an OAuth app registration with the vendor. See [#oauth-providers](CONTRIBUTING.md#adding-a-provider). |
| FTP, FTPS, SFTP, SMB | ❌ Not HTTP; SFTP needs a vendored libssh2. |
| OpenStack Swift | ❌ Not started. |

Help with any of the ❌ rows is very welcome — see
[CONTRIBUTING.md](CONTRIBUTING.md).

---

## How it compares

People usually arrive here looking for a **free S3 client for Mac**, an
**Azure Blob Storage GUI**, or an alternative to a paid tool. Honest summary:

| | Openborld | Cyberduck | Transmit | ForkLift | Azure Storage Explorer |
|---|---|---|---|---|---|
| Price | **Free, MIT** | Free / donation | Paid | Paid | Free |
| Open source | **Yes** | Yes | No | No | No |
| S3 + S3-compatible | Yes | Yes | Yes | Yes | No |
| Azure Blob | Yes, 4 auth methods | Yes | No | No | Yes |
| Dual-pane cross-cloud drag | Yes | No | Yes | Yes | No |
| Server-side copy | Yes | Partial | Partial | No | Yes |
| Resumable multipart upload | Yes | Yes | Yes | Yes | Yes |
| App size | **~6 MB** | ~200 MB | ~100 MB | ~80 MB | ~400 MB |
| Google Drive / Dropbox / OneDrive | **Not yet** | Yes | Yes | Yes | No |
| SFTP / FTP | **Not yet** | Yes | Yes | Yes | No |
| Telemetry | **None** | None | Varies | Varies | Yes |

Openborld is younger and narrower than any of them. If you need SFTP or Google
Drive today, Cyberduck is free and excellent. If you mainly move objects
between S3 and Azure and want something small, fast, and hackable, that's the
gap this fills.

---

## Where your data lives

| What | Location |
|---|---|
| Credentials | macOS Keychain, service `dev.openborld.connections` |
| Connections, settings, favourites | `~/Library/Application Support/Openborld/` |
| Listing cache, staged previews | `~/Library/Caches/Openborld/` (safe to delete) |

`connections.json` holds account names, endpoints, and regions — but never
secrets. Nothing leaves your machine except requests to the storage endpoints
you configure.

---

## Architecture

```
Sources/
  OpenborldCore/        portable core — no SwiftUI, no AppKit
    Platform/           crypto, secret store, MIME table, migration
    Providers/          Azure, S3 family, WebDAV, local disk
    Transfers/          queue, progress, conflict policy
    Services/           HTTP, listing cache, settings, connections
    Models/             paths, items, connections, capabilities
  Openborld/            SwiftUI app — macOS only
    Models/             app and per-pane state
    Views/              window, sidebar, panes, sheets, design tokens
  OpenborldTestRunner/  the test suite
  CSQLite/              system sqlite3 module map
Tests/Support/
  mock_cloud.py         local Azure + S3 double
```

Two rules hold the shape together:

1. **Everything the UI touches goes through `StorageProvider`.** Adding a
   provider never requires editing a view.
2. **`OpenborldCore` imports no Apple-only framework** outside a platform
   guard. `Scripts/check-portability.sh` enforces it.

---

## Testing

```bash
swift run openborld-tests              # 56 tests
swift run openborld-tests --diagnose   # dump signature mismatches side by side
```

The suite is a plain executable rather than XCTest, so it runs without Xcode.

Integration tests run against `Tests/Support/mock_cloud.py`, a local stand-in
that reimplements Azure SharedKey and AWS SigV4 **verification** from the specs
in Python. Two independent implementations agreeing is what gives the signing
code credibility — and it earned its keep immediately: it caught a bug where
`URL.path` silently drops a trailing slash, so the client signed `/bucket`
while sending `/bucket/`. That would have failed against real Azure *and* real
S3, with nothing but a `403` to debug from.

---

## Cross-platform status

| Target | macOS | Linux | Windows |
|---|---|---|---|
| `OpenborldCore` | ✅ verified in CI | ✅ verified in CI | 🟡 by construction, **unverified** |
| `openborld-tests` | ✅ 56/56 | ✅ 56/56 | 🟡 unverified |
| `Openborld` (the app) | ✅ | ❌ impossible | ❌ impossible |

The core's Apple-only dependencies were replaced: CryptoKit → swift-crypto,
Keychain → a `SecretStore` protocol with an encrypted-file fallback,
UniformTypeIdentifiers → an explicit MIME table, `SQLite3` → a `CSQLite` system
module, and per-task URLSession delegates → a session-level delegate (per-task
delegates don't exist in swift-corelibs-foundation).

**Linux is verified in CI** on every push: the core builds and all 56 tests
pass, including the Azure and S3 integration suites driving
swift-corelibs-foundation's `URLSession`. Reproduce it locally with:

```bash
docker run --rm -v "$PWD":/src -w /src swift:6.4 bash -c \
  "apt-get update && apt-get install -y libsqlite3-dev python3 && \
   swift build --product openborld-tests && swift run openborld-tests"
```

**Windows is still unverified.** The same split-Foundation handling should
apply, but no one has run it. A CI job for it is a welcome contribution.

**There is no cross-platform UI**, and this is the big open question. SwiftUI
does not exist on Linux or Windows, so the app layer cannot be ported. The
realistic options are discussed in
[CONTRIBUTING.md § Cross-platform](CONTRIBUTING.md#cross-platform-ui). If this
matters to you, that discussion is the place to weigh in.

---

## Contributing

Contributions are welcome — bug reports, provider implementations, platform
work, documentation. Start with [CONTRIBUTING.md](CONTRIBUTING.md), which
covers the dev setup, the conventions this codebase actually follows, and a
walkthrough of adding a new storage provider.

By contributing you agree to the [Code of Conduct](CODE_OF_CONDUCT.md) and to
signing off your commits under the [DCO](CONTRIBUTING.md#developer-certificate-of-origin).

Found a security issue? Please read [SECURITY.md](SECURITY.md) first — don't
open a public issue.

---

## Licence

[MIT](LICENSE). Use it, fork it, ship it.

Openborld bundles no third-party code. It depends on
[swift-crypto](https://github.com/apple/swift-crypto) (Apache-2.0), Apple's own
cryptography package.

---

<div align="center">

**If Openborld is useful to you, a ⭐ helps other people find it.**

</div>

<!--
Keywords: free open source cloud storage manager, S3 client macOS, Amazon S3
GUI, Azure Blob Storage explorer for Mac, S3 browser, MinIO client, Wasabi
client, Cloudflare R2 client, Backblaze B2 GUI, Google Cloud Storage client,
WebDAV client macOS, Nextcloud desktop client, ownCloud client, dual pane file
manager, cloud file transfer tool, Cyberduck alternative, Transmit
alternative, ForkLift alternative, Azure Storage Explorer alternative, free
SFTP alternative, open source object storage browser, macOS native SwiftUI
app, multi cloud file manager, cross cloud transfer, resumable upload,
presigned URL generator, SAS URL browser.
-->
