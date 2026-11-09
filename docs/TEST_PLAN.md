# CleanerMac Test Plan & TDD Verification Matrix

## 1. Testing Philosophy

CleanerMac follows strict **Red-Green-Refactor** Test-Driven Development (`tdd-workflow`):
- Tests are authored **before** production logic for safety guards, duplicate detection, orphan matching, scanning checkpoints, deletion planning, and preview providers.
- Pure domain policies in `CleanerCore` execute hermetically with zero filesystem or UI dependencies.
- Filesystem scanners and deletion executors in `CleanerSystem` run against isolated temporary sandboxes (`FileManager.default.temporaryDirectory`) using an injected trash sink so automated tests never touch `~/.Trash` or real user files.

---

## 2. Test Suites & Coverage Goals

| Target | Focus | Runner | Target Coverage | Measured Line Coverage |
| :--- | :--- | :--- | :--- | :--- |
| `CleanerCoreTests` | `SafetyGuard`, `RiskEvaluator`, `OrphanAppDetector`, `DuplicateGrouper`, `HardLinkTracker`, `DeletionPlanner`, `TrashReceiptPolicy` | `./scripts/run-tests.sh` | `>= 85%` | `89.71%` |
| `CleanerSystemTests` | Staged SHA-256 duplicate pipeline, large/old/dead scanners, Pause/Resume frontier parity, Cancel responsiveness, Dry-Run invariance, Trash vs Permanent Delete, `CleanHistoryStore` | `./scripts/run-tests.sh` | `>= 85%` | `90.88%` |
| `CleanerPreviewTests` | Image, Video, PDF, Text/Code (including truncation & UTF-16), Audio metadata, Fallback metadata inspection | `./scripts/run-tests.sh` | `>= 80%` | `94.66%` |
| `CleanerUITests` | Multi-select state (`Shift`/`Cmd`/`Cmd+A`/`Space`), category filtering, sorting, Pause/Resume/Cancel, Dry-Run gating, Confirmation sheet invariants, Font registration | `./scripts/run-tests.sh` | `>= 80%` (ViewModels & State) | `84.85%` |

---

## 3. Critical Verification Matrix

### 3.1 Duplicate Detection Accuracy
| Case ID | Scenario | Expected Outcome |
| :--- | :--- | :--- |
| `DUP-01` | Two files with different filenames (`a.bin`, `b.bin`) and identical content | Grouped together; oldest/canonical marked `Keep`, second marked removable with moderate risk reason |
| `DUP-02` | Same size + identical first 4 KiB + identical last 4 KiB, differing by 1 byte in the middle | **NOT** grouped as duplicates (full SHA-256 mismatch caught in Stage 3) |
| `DUP-03` | Hard-linked paths pointing to same `(st_dev, st_ino)` | Deduplicated via `HardLinkTracker`; never counted twice in reclaimable bytes and never falsely surfaced as deletable duplicate |
| `DUP-04` | Files smaller than `minDuplicateSize` threshold | Excluded from duplicate hashing pipeline |
| `DUP-05` | Multi-category overlap (item in both Large & Old) | `selectedSize` counts each URL exactly once |

### 3.2 Safety Guards & Protected-Path Rules
| Case ID | Scenario | Expected Outcome |
| :--- | :--- | :--- |
| `SAF-01` | Empty path or path containing NUL (`\0`) byte | Rejected with `SafetyError.invalidPath` |
| `SAF-02` | Protected system prefixes (`/System`, `/Library/...`, `/usr`, `/bin`, `/sbin`, `/private/etc`, `/private/var/db`, `/dev`) | Rejected with `SafetyError.protectedPath` |
| `SAF-03` | Other user home directory (`/Users/someoneelse/Downloads/file`) | Rejected with `SafetyError.outsideUserScope` |
| `SAF-04` | Symlink inside home pointing into `/System` or `/Library` | Rejected with `SafetyError.symlinkEscape` after resolving symlinks |
| `SAF-05` | App bundle (`*.app`) when `allowAppBundles == false` vs `true` | Rejected by default (`appBundleProtected`); allowed only when explicitly opted in |
| `SAF-06` | User-excluded folder `/Users/me/Work` vs sibling `/Users/me/WorkBackup` | `/Users/me/Work/a` rejected (`userExcluded`); `/Users/me/WorkBackup/a` allowed |
| `SAF-07` | Batch exceeding `maxFilesPerOperation` (`10,000`) | Rejected with `SafetyError.tooManyFiles` |
| `SAF-08` | Orphan detector when `installedBundleIDs` is empty | Returns `false` for all candidates (fail-safe) |
| `SAF-09` | Orphan detector on `com.apple.*`, shared runtimes, and `.helper` of installed app | Never flagged; sibling company apps (e.g., installed Photoshop vs uninstalled Illustrator) remain distinct |

### 3.3 Background Scanning, Pause/Resume, Cancel & Dry-Run
| Case ID | Scenario | Expected Outcome |
| :--- | :--- | :--- |
| `SCN-01` | Pause active scan after initial batch, then resume from `ScanCheckpoint` | Resumed scan finishes with exact same file set as uninterrupted scan (zero duplicates, zero drops) |
| `SCN-02` | Cancel mid-scan on nested directory tree | Scan terminates promptly (`< 500 ms`), transitions to `.cancelled`, leaves partial state consistent |
| `SCN-03` | Execute cleanup with `dryRun == true` | Returns `DeletionExecutionReport(isDryRun: true)` with expected byte savings; all files remain untouched on disk |
| `SCN-04` | Permanent deletion requested without `confirmed == true` | Throws `DeletionPlanError.permanentConfirmationRequired` without touching disk |
| `SCN-05` | Move to Trash + Restore receipt verification | Records Trash path and inode; refuses restore if Trash inode changed or outside Trash root |

---

## 4. Verification Commands

```bash
# Run full unit + integration test suite (51 tests across 8 suites)
./scripts/run-tests.sh

# Run with LLVM code coverage instrumentation
./scripts/run-tests.sh --enable-code-coverage
```

