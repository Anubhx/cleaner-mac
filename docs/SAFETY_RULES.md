# CleanerMac Safety & Protected-Path Rules

CleanerMac treats every filesystem mutation as potentially destructive unless proven safe, scoped, and reversible. Safety rules are enforced at **three independent layers**:

1. **Enumeration Frontier (`CleanerSystem`)** — Prevents protected trees and other users' home folders from even being traversed.
2. **Domain Planning (`CleanerCore.SafetyGuard` & `DeletionPlanner`)** — Pure, unit-tested rules that validate every candidate path before planning or simulation.
3. **Pre-Execution Re-Verification (`CleanerSystem.DeletionExecutor`)** — Re-resolves symlinks and checks live macOS file flags immediately before touching disk to stop Time-of-Check to Time-of-Use (TOCTOU) attacks.

---

## 1. Hard-Blocked System & OS Prefixes

The following prefixes (matched strictly on path component boundaries, never naive substrings) are **permanently blocked** for both scanning and deletion, with **no user override**:

| Prefix | Reason |
| :--- | :--- |
| `/` | Root volume guard |
| `/System` | Sealed macOS SSV system volume |
| `/Library` | Shared system-wide frameworks, daemons, extensions |
| `/usr`, `/bin`, `/sbin` | UNIX system binaries and libraries |
| `/etc` (and `/private/etc`) | System configuration |
| `/var/db`, `/var/root`, `/var/vm` | System databases, root user data, swap/sleep images |
| `/dev`, `/Network`, `/cores` | Kernel device nodes, network mounts, core dumps |

### Firmlink Canonicalization

On macOS APFS volumes, `/private/var`, `/private/tmp`, and `/private/etc` map to `/var`, `/tmp`, and `/etc`. `SafetyGuard.canonicalizeFirmlink` normalizes `/private` prefixes before running boundary checks so `/private/etc/hosts` or `/private/var/db/...` cannot bypass `/etc` or `/var/db` rules.

---

## 2. Cross-User Isolation Guard

- Paths under `/Users` (or `/Users/<otherUser>`) outside the active `currentUserHome` throw `SafetyError.outsideUserScope`.
- Multi-user privacy boundaries cannot be bypassed even if permissions on another home folder are loose.

---

## 3. Application Bundle Protection (`*.app`)

- Any path containing an `.app` path component is blocked by default (`SafetyError.appBundleProtected`).
- Users may explicitly opt in via **Settings -> Allow App Bundles When Explicitly Selected** (`allowAppBundles = true`), and even then system locations (`/System/Applications/...`) remain blocked.

---

## 4. Symlink & TOCTOU Protection

Before moving or deleting any item, `DeletionExecutor` calls `FilesystemProbes.resolveRealPath(item.url)` and `SafetyGuard.validateResolvedTarget(original:resolved:)`:

- If a symlink inside `~/Downloads` or `~/Temp` resolves to `/System`, `/Library`, another user's home, or an `.app` bundle, execution aborts with `SafetyError.symlinkEscape`.
- Even inside **Dry-Run Mode**, protected rules are evaluated and reported in `ExecutionReportSheet.blockedItems`.

---

## 5. POSIX Permissions, SIP & File Flags

Before calling `FileManager.trashItem` or `removeItem`, `FilesystemProbes.isCleanableByCurrentProcess` verifies:

1. Parent directory is writable by current process (`access(parent, W_OK) == 0`).
2. Item metadata via `lstat` does not carry `UF_IMMUTABLE`, `SF_IMMUTABLE`, or `UF_DATAVAULT` lock flags.
3. For directories, `R_OK | W_OK | X_OK` permissions hold.

---

## 6. Risk Tiers & Zero Auto-Selection Guarantee

Every `ScannedItem` carries a human-readable `RiskAssessment(level:reason:)`:

| Category / Condition | Risk Level | Auto-Select Allowed (`Select All`)? | Explained Reason |
| :--- | :--- | :--- | :--- |
| iCloud Dataless Placeholder | **High Risk** | Never | Deleting a stub may affect synced iCloud Drive files across devices. |
| Duplicates — **Keep Original** | **Pinned Keep** | **Never** (Checkbox disabled) | Oldest/shortest path selected as canonical original to preserve data. |
| Duplicates — Extra Copy | **Review Carefully** | Explicit category opt-in only | SHA-256 verified identical bytes; confirm external links or projects. |
| Large Files | **Review Carefully** | No auto-selection on scan | Exceeds user size threshold; could be archives, VMs, or raw media. |
| Old Files | **Review Carefully** | No auto-selection on scan | Untouched past age threshold; confirm it is not an intentional archive. |
| Orphaned `Application Support` | **Review Carefully** | Never | May hold presets, templates, SQLite databases, or license keys. |
| Orphaned Caches / Saved State | **Low Risk** | Dead category safe | Owning app bundle ID absent (verified with dotted-lineage matching). |
| Stale Caches | **Low Risk** | Dead category safe | Regenerable application cache files. |
| Broken Downloads | **Low Risk** | Dead category safe | Partial extensions (`.download`, `.crdownload`, `.part`, `.partial`, `.opdownload`) untouched `>= 24 hours`. |
| Empty Folders | **Low Risk** | Dead category safe | Excludes `.git`, `.svn`, `.hg`, `.Trash`, `.app`, `.xcodeproj`, `.photoslibrary`, etc. |

### Orphaned App Fail-Safe

`InstalledAppIndex` discovers apps across `/Applications`, `/Applications/Setapp`, `/System/Applications`, `~/Applications`, and CoreServices/Spotlight where available. If the discovered installed bundle ID set is empty (e.g., restricted sandbox failure), `OrphanAppDetector.isOrphan` returns `false` across all entries to prevent false-positive deletion of active app data.

---

## 7. Trash-First Deletion, Restore Receipts & Confirmation Gates

- **Default Action:** Move to Trash (`DeletionMode.moveToTrash`), logging a `TrashHistoryEntry` with `originalPath`, `trashPath`, byte count, timestamp, and `trashInode`.
- **Safe Restoration:** `TrashReceiptPolicy.planRestore` verifies the file still resides inside canonical `~/.Trash`, matches the stored inode, and never overwrites a newly created file at the original path.
- **Permanent Deletion:** Requires `DeletionMode.permanentDelete(confirmed: true)` AND checking an explicit acknowledgement toggle in `PermanentDeleteConfirmationSheet`. Calling `DeletionPlanner.plan` with `confirmed: false` throws `DeletionPlanError.permanentConfirmationRequired`.
- **Dry-Run Mode:** Simulates planning and safety validation cleanly and reports exact reclaimable bytes and blocked items without modifying disk or history.
- **Batch Limit:** Single operations cap at `SafetyGuard.maxFilesPerOperation = 10,000` items.
