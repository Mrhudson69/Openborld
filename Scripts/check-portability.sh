#!/bin/bash
# Fails if an Apple-only framework or API reappears in the portable core.
#
# The core is meant to build on macOS, Linux, and Windows. That guarantee is
# easy to break by reflex — `import AppKit` for one convenience — and the break
# stays invisible until someone attempts a Linux build. This catches it here.
set -uo pipefail
cd "$(dirname "$0")/.."
CORE=Sources/OpenborldCore
python3 -I - "$CORE" <<'PY'
import pathlib, re, sys

core = pathlib.Path(sys.argv[1])

BANNED_IMPORTS = {
    "AppKit": "no window server on Linux or Windows",
    "SwiftUI": "the UI layer is macOS-only by design",
    "UIKit": "not a mobile target",
    "CryptoKit": "use swift-crypto's Crypto, which covers every platform",
    "SQLite3": "use the CSQLite system module",
}
BANNED_API = {
    "NSWorkspace": "AppKit",
    "trashItem": "Trash exists only on macOS",
    "UTType(": "UniformTypeIdentifiers",
    "SecItem": "Security framework",
}

problems = []
for path in sorted(core.rglob("*.swift")):
    lines = path.read_text().split("\n")
    guarded = False
    for number, line in enumerate(lines, start=1):
        stripped = line.strip()
        # Track whether we are inside a platform- or availability-guarded block.
        if stripped.startswith("#if") and ("canImport" in stripped or "os(" in stripped):
            guarded = True
        elif stripped.startswith("#endif"):
            guarded = False

        if guarded:
            continue

        match = re.match(r"import (\w+)", stripped)
        if match and match.group(1) in BANNED_IMPORTS:
            name = match.group(1)
            problems.append(f"{path}:{number}  import {name} — {BANNED_IMPORTS[name]}")

        for api, reason in BANNED_API.items():
            if api in line and not stripped.startswith("//"):
                problems.append(f"{path}:{number}  {api} — {reason}")

if problems:
    print("✗ Apple-only API outside a platform guard:")
    for problem in problems:
        print("    " + problem)
    sys.exit(1)
print("✓ OpenborldCore uses no unguarded Apple-only API")
PY
