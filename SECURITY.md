# Security Policy

Openborld holds credentials for people's cloud storage accounts. A bug here can
expose an entire S3 bucket or Azure container, so security reports are taken
seriously and handled before feature work.

## Reporting a vulnerability

**Do not open a public issue.** Use GitHub's private reporting instead:

> Security → Report a vulnerability

on this repository. That opens a private advisory visible only to maintainers.

Please include what you can: affected version or commit, the provider involved
(Azure, S3, WebDAV, local), reproduction steps, and what an attacker gains. A
proof of concept helps, but a clear description is enough — don't withhold a
report because you haven't finished exploiting it.

You can expect an acknowledgement within 72 hours and an assessment within a
week. If a fix needs longer, you'll get progress updates rather than silence.
Credit in the release notes is offered unless you'd rather stay anonymous.

## Scope

In scope, and especially valuable:

- Credential leakage — secrets written to logs, caches, crash reports, temp
  files, or the listing database.
- Request signing flaws — anything that lets a request be forged, replayed,
  or sent with wider scope than intended (Azure SharedKey, SAS, AWS SigV4).
- Path handling that escapes the intended container, bucket, or local folder.
- TLS verification weaknesses, or credentials sent over plaintext HTTP.
- Anything that causes the wrong remote object to be overwritten or deleted.

Out of scope:

- The lack of Developer ID signing on unofficial builds. Known, documented.
- The reduced protection of `EncryptedFileSecretStore` on Linux and Windows.
  This is a documented trade-off, not a bug: it defends a stolen backup, not
  local malware. A way to *improve* it is welcome as a feature.
- Attacks needing an already-compromised user account on the same machine.

## What this project does with your credentials

Worth stating plainly, because it is checkable:

- Secrets go to the macOS Keychain, or to an AES-GCM encrypted file elsewhere.
  They are never written to `connections.json`.
- Nothing is sent anywhere except the storage endpoint you configure. There is
  no telemetry, no analytics, and no update check.
- The listing cache stores file names and sizes, never file contents or
  credentials.
