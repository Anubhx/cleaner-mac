# Security Policy

## Local-Only Privacy & Telemetry Guarantee

CleanerMac runs **100% locally on your Mac**:

- **Zero network requests:** The codebase contains no networking clients (`URLSession`, `Network.framework`, HTTP libraries, update-check pings, or analytics SDKs).
- **Zero telemetry:** No usage counters, filenames, hashes, paths, or diagnostics ever leave your machine.
- **Standalone verification:** Reviewers can inspect `Sources/` directly or inspect linked binaries with `otool -L` to confirm no networking frameworks beyond standard Foundation/AppKit/AVFoundation local APIs are linked for telemetry.

---

## What CleanerMac Can and Cannot Touch

### Permitted Scope (Under Explicit User Review)

- Files and folders inside your active user home directory (`$HOME`), such as `~/Downloads`, `~/Documents`, `~/Desktop`, `~/Movies`, `~/Library/Caches`, `~/Library/Saved Application State`, and user-selected external scan roots.
- Empty directories outside packages, hidden directories, and version control metadata.
- Explicitly selected items moved safely to `~/.Trash` (default) or permanently deleted only after explicit confirmation.

### Off-Limits Scope (Enforced by `SafetyGuard`)

CleanerMac **cannot** scan, modify, Trash, or delete:

1. Core macOS system directories (`/`, `/System`, `/Library`, `/usr`, `/bin`, `/sbin`, `/etc`, `/private/etc`, `/var/db`, `/var/root`, `/var/vm`, `/dev`, `/Network`, `/cores`).
2. Other macOS user home folders (`/Users/<otherUser>` or `/Users`).
3. Application bundles (`*.app` anywhere in the path) unless explicitly enabled by the user in Settings.
4. User-excluded folders (`ScanConfiguration.excludedFolders`).
5. Files protected by macOS SIP, parent write restrictions, or `UF_IMMUTABLE` / `SF_IMMUTABLE` / `UF_DATAVAULT` flags.
6. Symlink targets pointing out of authorized user scope into protected paths (mitigated via `validateResolvedTarget` immediately before deletion).
7. Active partial downloads (`< 24 hours` since modification), version control repositories (`.git`, `.svn`, `.hg`), and Apple package formats (`.photoslibrary`, `.xcodeproj`, etc.).

---

## Supported Versions

| Version | Supported |
| :--- | :--- |
| `1.x` (macOS 14 Sonoma+) | Active security & safety support |

---

## Reporting a Vulnerability

If you discover a safety guard bypass, symlink/TOCTOU vulnerability, restore receipt flaw, or false-positive risk rule:

1. **Do not** open a public GitHub issue with exploit details for unpatched safety bypasses.
2. Open a private GitHub Security Advisory on the repository or contact the maintainers directly via the repository's security contact channel.
3. Include macOS version, reproduction steps (preferring a failing unit test case in `Tests/`), and impacted module (`CleanerCore`, `CleanerSystem`, `CleanerPreview`, or `CleanerUI`).

We aim to acknowledge reports within 48 hours and issue a test-verified fix promptly.
