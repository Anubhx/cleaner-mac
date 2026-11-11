# CleanerMac Architecture Overview

CleanerMac is a 100% local, privacy-preserving native macOS disk-cleaning utility built with **Swift 6** and **SwiftUI**, targeting **macOS 14.0+** on Apple Silicon (`arm64` only). It runs completely offline with zero network calls, zero analytics, and zero third-party SDK dependencies.

---

## 1. Design Goals & Architectural Principles

1. **Pure Domain Isolation:** All classification policies, safety path guards, risk explanations, duplicate grouping logic, dry-run planning, and restore verification live in `CleanerCore` with zero UI (`SwiftUI`/`AppKit`) or live disk mutation dependencies.
2. **Test-First Reliability:** Every scanning, grouping, safety, and deletion rule is verified through deterministic unit and sandboxed filesystem integration tests before UI integration.
3. **Reversibility & Explicit Consent:** Deletion defaults to **Move to Trash** with receipt logging and one-click restore verification. Permanent deletion requires explicit secondary user confirmation, and risky categories never auto-select.
4. **Responsive Background Execution:** Full-disk/user-home scans execute at `TaskPriority.utility` over an explicit directory frontier (`ScanCheckpoint`), yielding to UI frames and streaming batched discoveries while supporting true **Pause**, **Resume**, and **Cancel**.
5. **Zero Network Footprint:** `CleanerCore`, `CleanerSystem`, `CleanerPreview`, `CleanerUI`, and `CleanerApp` make zero network imports (`URLSession`, `Network`) and zero outbound connections.

---

## 2. Module Graph & Responsibilities

```text
┌────────────────────────────────────────────────────────────────┐
│                          CleanerApp                            │
│  @main App entry, Instrument Serif font registration, shortcuts│
└───────────────┬────────────────────────────────┬───────────────┘
                │                                │
                ▼                                ▼
┌───────────────────────────────┐  ┌─────────────────────────────┐
│           CleanerUI           │  │        CleanerSystem        │
│  SwiftUI views, DesignSystem, │  │  Actors: ScanCoordinator,   │
│  ViewModels, Accessibility,   │  │  StreamingHasher, AppIndex, │
│  Multi-select & Sheets        │  │  DeletionExecutor, FSProbes │
└───────────────┬───────────────┘  └──────────────┬──────────────┘
                │                                 │
                ▼                                 │
┌───────────────────────────────┐                 │
│        CleanerPreview         │                 │
│  Image, Video, PDF, Text,     │                 │
│  Audio & Fallback Metadata    │                 │
└───────────────┬───────────────┘                 │
                │                                 │
                └──────────────┬──────────────────┘
                               ▼
┌────────────────────────────────────────────────────────────────┐
│                          CleanerCore                           │
│  Domain models, SafetyGuard, RiskEvaluator, OrphanAppDetector, │
│  DuplicateGrouper, HardLinkTracker, DeletionPlanner,           │
│  TrashReceiptPolicy                                            │
└────────────────────────────────────────────────────────────────┘
```

### Target Breakdown

| Target | Dependencies | Purpose |
| :--- | :--- | :--- |
| **`CleanerCore`** | `Foundation`, `UniformTypeIdentifiers` | Pure domain models, safety rules, risk classification, duplicate grouping policies, orphan heuristics, dry-run planner, restore receipt policies. |
| **`CleanerSystem`** | `CleanerCore`, `CryptoKit`, `Darwin`, `AppKit` | Background directory enumerator (`ScanCoordinator` actor), streaming SHA-256 hasher, installed app discovery, POSIX/data-vault probes, Trash/Permanent deletion executor. |
| **`CleanerPreview`** | `CleanerCore`, `AppKit`, `PDFKit`, `AVFoundation`, `QuickLookThumbnailing`, `CoreGraphics` | Multi-format preview providers (image, video thumbnail + metadata, PDF, text/code, audio metadata, fallback inspector). |
| **`CleanerUI`** | `CleanerCore`, `CleanerPreview`, `SwiftUI` | Design tokens (`Instrument Serif` + system typography, materials), `NavigationSplitView` workspace, keyboard/mouse multi-select list, preview pane, confirmation & dry-run sheets. |
| **`CleanerApp`** | `CleanerCore`, `CleanerSystem`, `CleanerPreview`, `CleanerUI` | Executable entry point, runtime `CTFontManager` font registration, live state wiring, menu bar commands & keyboard shortcuts. |

---

## 3. Background Scanning, Pause/Resume & Streaming Architecture

### Explicit Frontier Queue (`ScanCheckpoint`)
Instead of relying solely on an opaque `FileManager.DirectoryEnumerator` loop that loses state on pause, `ScanCoordinator` drives a breadth-first **directory frontier**:

```text
User Roots ──▶ [Pending Directory Queue] ──▶ Pop Batch (utility QoS)
                       ▲                              │
                       │ (enqueue subdirs)            ▼
                       └────────────────── Evaluate Metadata & Filters
                                                      │
                                                      ▼
                                        Stream ScanBatch (every ~80ms / 64 items)
```

- **Pause:** Sets coordinator state to `.paused` and stops popping from the $O(1)$ frontier queue after the active directory entry finishes, preserving remaining `pendingDirectories`, `candidateFiles`, `deadItems`, `scannedFiles`, and `bytesEvaluated` inside `ScanCheckpoint`.
- **Resume:** Re-enters the loop from the exact remaining `pendingDirectories` in `ScanCheckpoint` without rescanning already-visited folders.
- **Cancel:** Cancels the active `TaskGroup` / `Task`, drains gracefully, and freezes partial results cleanly.
- **Throttled Streaming:** Discoveries buffer briefly and emit via `AsyncStream<ScanBatch>` every `~80 ms` or `64` items so SwiftUI list updates remain smooth on ProMotion (`120 Hz`) displays without main-actor congestion.
- **Volume Capacity HUD:** `FilesystemProbes.volumeStorageSnapshot(for:)` queries real APFS volume capacity (`used`, `free`, percentage full) for the sidebar `DiskCapacityHUD`.

---

## 4. Category Pipelines

### 4.1 Duplicate Files (Content-Hash Pipeline)
1. **Stage 1 — Size Grouping (`CleanerCore`):** Group regular files (outside `~/Library` unless explicitly rooted) by logical size (`>= userMinDuplicateSize`, default `1 MiB`), discarding unique sizes immediately.
2. **Stage 2 — Partial Pre-Hash (`CleanerSystem`):** In parallel (`TaskGroup` bounded to active core count), hash the first `4 KiB` + last `4 KiB` (for files `> 8 KiB`) using `CryptoKit.SHA256`. Unique `(size, partialDigest)` pairs are discarded without reading full files.
3. **Stage 3 — Full Streaming SHA-256 (`CleanerSystem`):** Hash remaining candidates in `64 KiB` streaming chunks, checking `Task.isCancelled` and pause gates between chunks.
4. **Stage 4 — Hard-Link Deduplication (`CleanerCore`):** Lazily resolve `(st_dev, st_ino)` for verified duplicate candidates and deduplicate via `HardLinkTracker` so hard-linked files are never mistaken for separate duplicate copies or over-counted in reclaimable space.
5. **Original Selection Heuristic:** Mark one recommended "Keep" original per group (prioritizing oldest creation date, shortest/most canonical path outside `Downloads`/`Trash`), while leaving **zero** duplicates auto-selected until reviewed or explicitly toggled.

### 4.2 Large Files
- Descends across user-selected roots—explicitly entering macOS `UF_HIDDEN` `~/Library` while skipping sensitive internals (`Preferences`, `Keychains`, `Cookies`, `Mail`, `Messages`, `Safari`, `Group Containers`, nested `Containers/*/Data/Library/<blocked>`)—so oversized user media, VMs, and assets inside `Containers` / `Application Support` / `Developer` surface exceeding `ScanConfiguration.largeFileThresholdBytes` (`100 MB` default).
- Computes `reclaimableDiskBytes` using APFS allocated blocks for sparse virtual disks (such as `Docker.raw`) and `0` for iCloud dataless stubs, while still showing both logical and allocated sizes in the Preview Inspector.

### 4.3 Old Files
- Evaluates user files outside `~/Library` (unless explicitly targeted) older than `ScanConfiguration.oldFileThresholdDays` (`180 days` default) using `AgeBasis`:
  - `.lastAccessedOrModified` (uses `contentAccessDateKey` when strictly later/valid, falling back to `contentModificationDateKey` on APFS volumes mounted with `noatime`/`relatime`).
  - `.lastModifiedOnly` (strictly `contentModificationDateKey`).

### 4.4 Dead & Leftover Files
1. **Orphaned App Data:** Enumerates installed `CFBundleIdentifier` values across `/Applications`, `/Applications/Utilities`, `/System/Applications`, `/System/Applications/Utilities`, and `~/Applications` (including nested vendor folders). Safety fail-safe: if zero installed apps are found, orphan detection aborts without flagging anything. Checks `~/Library/Caches`, `~/Library/Logs`, `~/Library/HTTPStorages`, `~/Library/Saved Application State`, `~/Library/WebKit`, and (flagged as `.moderate` risk with explicit explanation) `~/Library/Application Support` for reverse-DNS entries (`>= 3` components) not sharing lineage with any installed app or helper suffix (`.helper`, `.agent`, `.daemon`, `.updater`, `.xpc`, etc.), and never matching `com.apple.*` or shared runtimes (`org.chromium.*`, `com.electron.*`, `com.google.keystone`, etc.).
2. **Stale & Heavy Active Third-Party Caches:** Scans `~/Library/Caches` (`com.apple.*` spared) for caches untouched `>= 30 days` (`Low Risk`) as well as heavy active caches `>= 50 MB` (`Review Carefully`).
3. **Developer & Package Caches:** Targets rebuildable build/package stores (`.npm/_cacache`, `.npm/_npx`, `.gradle/caches`, `.pnpm-store`, `.bun/install/cache`, `.cache/*`, `Xcode DerivedData`, `iOS DeviceSupport`, `CoreSimulator/Caches`).
4. **Broken / Incomplete Downloads:** `*.download`, `*.crdownload`, `*.part`, `*.partial`, `*.opdownload` in `~/Downloads` untouched past a 24-hour active-transfer grace period.
5. **Empty Directories:** Bottom-up emptiness checks outside `~/Library` internals, skipping package bundles (`.app`, `.bundle`, `.framework`, `.xcodeproj`, `.xcworkspace`, `.git`), `.Trash`, and protected prefixes.

---

## 5. Multi-Layer Safety & Reversibility Architecture

Every path passes through `SafetyGuard` both during scan classification (to tag risk reasons or suppress forbidden system paths) and immediately prior to deletion (**TOCTOU mitigation**):

1. **System & Protected-Path Blocklist:** `/System`, `/Library` (unless explicitly opted into safe user-authorized items), `/usr`, `/bin`, `/sbin`, `/private/etc`, `/private/var/db`, `/dev`, `/Volumes` metadata, other users' home directories (`/Users/<other>`), and application bundles (`*.app`) unless explicitly selected by the user.
2. **Firmlink & Symlink Normalization:** Maps `/private/var`, `/private/tmp`, and `/private/etc` consistently and rejects suspicious symlink escapes where resolving symlinks redirects into a protected root or outside the authorized user scope.
3. **Kernel & POSIX Writability Filter (`CleanFilter`):** Checks `access(parent, W_OK)` and `UF_DATAVAULT` / `UF_IMMUTABLE` flags before presenting items as actionable, preventing noisy `EPERM`/`EACCES` failures.
4. **Cloud / Dataless Guard:** Flags `.ubiquitousItem` / dataless iCloud placeholders as risky with explicit explanation rather than blindly treating virtual files as local disk savings.
5. **Trash-First & Audit Receipt (`DeletionExecutor` + `CleanHistoryStore`):**
   - Default action moves items to Trash via `FileManager.default.trashItem(at:resultingItemURL:)`.
   - Records original path, resulting Trash path, byte count, timestamp, and Trash file inode (`fileSystemFileNumber`) so Restore never restores a later-colliding file.
   - **Dry-Run Mode:** Simulates all checks and computes exact reclaimable bytes and per-item disposition without invoking any filesystem write API.
   - **Permanent Deletion:** Disabled by default behind a dedicated confirmation flow showing exact item count, total bytes, affected paths, and an explicit irreversibility acknowledgment.

---

## 6. Project Directory Structure

```text
cleaner-mac/
├── .agents/skills/                   # Workspace AI skills (software-architecture, tdd-workflow, clean-code)
├── .github/
│   ├── ISSUE_TEMPLATE/
│   │   ├── bug_report.yml
│   │   ├── feature_request.yml
│   │   └── config.yml
│   ├── workflows/
│   │   ├── ci.yml
│   │   └── release.yml
│   └── pull_request_template.md
├── Resources/
│   ├── CleanerMac.entitlements
│   ├── CleanerMac.icns
│   └── Info.plist
├── Sources/
│   ├── CleanerCore/
│   │   ├── Analysis/
│   │   ├── History/
│   │   ├── Models/
│   │   ├── Planning/
│   │   └── Safety/
│   ├── CleanerSystem/
│   │   ├── Deletion/
│   │   ├── Discovery/
│   │   ├── Hashing/
│   │   ├── History/
│   │   └── Scanning/
│   ├── CleanerPreview/
│   │   ├── Models/
│   │   └── Providers/
│   ├── CleanerUI/
│   │   ├── Components/
│   │   ├── DesignSystem/
│   │   ├── Resources/
│   │   │   └── Fonts/
│   │   │       ├── InstrumentSerif-Regular.ttf
│   │   │       ├── InstrumentSerif-Italic.ttf
│   │   │       └── OFL.txt
│   │   ├── ViewModels/
│   │   └── Views/
│   └── CleanerApp/
│       ├── CleanerApp.swift
│       └── SystemServiceAdapters.swift
├── Tests/
│   ├── CleanerCoreTests/
│   ├── CleanerSystemTests/
│   ├── CleanerPreviewTests/
│   └── CleanerUITests/
├── docs/
│   ├── images/
│   │   ├── cleanermac-walkthrough.gif
│   │   ├── welcome-permissions.png
│   │   └── workspace-preview.png
│   ├── ARCHITECTURE.md
│   ├── DESIGN_SYSTEM.md
│   ├── SAFETY_RULES.md
│   └── TEST_PLAN.md
├── scripts/
│   ├── notarize-app.sh
│   ├── package-app.sh
│   └── run-tests.sh
├── Package.swift
├── README.md
├── CONTRIBUTING.md
├── CODE_OF_CONDUCT.md
├── SECURITY.md
└── LICENSE
```

---

## 7. Acknowledgments & Originality

CleanerMac adopts proven macOS safety and scanning patterns pioneered by:
- **[`iliyami/MacSai`](https://github.com/iliyami/MacSai)** — pure-logic/I/O separation, `SafetyGuard` firmlink & TOCTOU patterns, `HardLinkTracker`, `OrphanedAppFiles` dotted-lineage matching, and Trash receipt verification.
- **[`guhcostan/mac-cleaner-cli`](https://github.com/guhcostan/mac-cleaner-cli)** — zero auto-selection on risky categories, dry-run discipline, grace periods for active temp files, and concise error-code summaries.

All Swift modules, checkpointed scanning logic, preview providers, and SwiftUI interfaces in CleanerMac are written originally from scratch.

