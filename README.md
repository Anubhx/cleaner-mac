# CleanerMac

**CleanerMac** is a native, local-only macOS disk-hygiene utility written in Swift 6 and SwiftUI for macOS 14+ on Apple Silicon (`arm64` only). It finds duplicates, oversized files, stale untouched files, and dead leftovers (orphaned app data, caches, broken downloads, empty folders) using a background scanner, live multi-type preview inspector, Trash-first reversibility, and strict protected-path safety guards.

---

## Core Capabilities

- **Four Focused Scan Categories**
  - **Duplicates:** Multi-stage detection (`size bucketing -> head/tail 4 KB digest -> partial sample -> full streaming SHA-256`) with hard-link `(st_dev, st_ino)` deduplication and automatic **Keep Original** protection on the canonical copy.
  - **Large Files:** Configurable size threshold across your chosen roots and non-sensitive app containers (`APFS` physical allocated and logical sizes displayed, accurately handling sparse virtual disks).
  - **Old Files:** Configurable inactivity threshold measured by **Last Accessed or Modified** (or **Last Modified Only**).
  - **Dead & Leftover Files:** Orphaned app data verified via dotted bundle-ID lineage, stale (`>= 30 days`) and heavy active (`>= 50 MB`) third-party `~/Library/Caches`, rebuildable developer/package caches (`.npm/_cacache`, `.npm/_npx`, `.gradle/caches`, `.pnpm-store`, `.bun`, `.cache`, `Xcode DerivedData`, `iOS DeviceSupport`), partial downloads past 24 hours, and empty directories.
- **Live Volume Capacity & Background Scan HUD**
  - Sidebar displays real macOS volume usage (`used`, `free`, percentage full) alongside live `.utility`-priority background scan progress with **Pause**, **Resume**, and **Cancel**.
- **All-Type Live Preview Inspector**
  - Inline preview support for **Images**, **Video** (poster frame, codec, resolution, duration), **PDF** (`PDFView`), **Text & Code** (with automatic `256 KB` truncation protection for huge logs), **Audio** (metadata & local playback preview), plus a detailed filesystem **Metadata & Risk Panel** fallback for any file type.
- **Safety-First Deletion & Undo History**
  - **Move to Trash by default** via `FileManager.trashItem`, saving verified Trash inode receipts in **Restore History** for one-click safe restoration.
  - **Permanent deletion** bypasses Trash only after entering a secondary confirmation sheet with explicit checkbox acknowledgment.
  - **Dry-Run Mode:** Simulates cleanup batches, reports projected savings, and surfaces blocked protected paths with zero disk mutations.
- **Responsive Background Scanning**
  - Runs at low `.utility` priority with frontier checkpointing for **Pause**, **Resume**, and **Cancel** while streaming results into the UI.
- **Editorial Translucent Native Design**
  - Styled around Apple HIG guidelines using **Instrument Serif** (SIL OFL 1.1) display headings, **SF Pro** / **SF Mono** metrics, `.ultraThinMaterial` / `.thinMaterial` / `.regularMaterial` surfaces, **zero emoji**, Light & Dark Mode, Dynamic Type, keyboard navigation, and VoiceOver actions.

---

## Requirements & Privacy Guarantee

- **OS:** macOS 14.0 (Sonoma) or newer (Apple Silicon / `arm64` only)
- **Toolchain:** Swift 6.0+ (`Xcode 16+` or standalone Apple Command Line Tools)
- **Privacy:** 100% offline. **Zero network requests, zero analytics, zero telemetry.**

---

## Architecture Overview

CleanerMac separates domain policy, filesystem I/O, file previewing, and UI cleanly into five Swift Package targets:

```
CleanerApp
 └── wires concrete actors into ──> CleanerUI (SwiftUI + Design System)
       ├── imports ──> CleanerPreview (AVFoundation, PDFKit, ImageIO, QuickLook)
       └── imports ──> CleanerCore (Pure domain models, SafetyGuard, RiskEvaluator, DeletionPlanner)
CleanerSystem
 └── imports ──> CleanerCore (Background frontier walker, SHA-256 pipeline, Trash executor, History store)
```

Detailed documents:
- [Architecture Overview](docs/ARCHITECTURE.md)
- [Design System Specification](docs/DESIGN_SYSTEM.md)
- [Safety & Protected-Path Rules](docs/SAFETY_RULES.md)
- [Test Plan & TDD Matrix](docs/TEST_PLAN.md)
- [Security Policy](SECURITY.md)

---

## Getting Started

### Clone & Test

```bash
git clone https://github.com/cleaner-mac/cleaner-mac.git
cd cleaner-mac
./scripts/run-tests.sh
```

> `./scripts/run-tests.sh` works seamlessly on both full Xcode installations and standalone Apple Command Line Tools (`/Library/Developer/CommandLineTools`).

### Build & Launch `.app` Bundle

```bash
./scripts/package-app.sh
open dist/CleanerMac.app
```

Alternatively, run directly with Swift Package Manager:

```bash
swift run CleanerApp
```

### Full Disk Access Note

To inspect protected user containers (`~/Library/Containers`, Mail/Safari caches), grant Terminal or `CleanerMac.app` **Full Disk Access** in **System Settings -> Privacy & Security -> Full Disk Access**. CleanerMac still strictly blocks OS system volumes (`/System`, `/Library`, `/usr`, `/bin`, `/sbin`) and other user home directories even when Full Disk Access is enabled.

---

## Keyboard Shortcuts

| Action | Shortcut |
| :--- | :--- |
| Start Full Scan / Scan Again | `Cmd+R` |
| Pause / Resume Scan | `Cmd+Shift+P` |
| Cancel Scan | `Cmd+.` |
| Toggle Dry-Run Mode | `Cmd+Shift+D` |
| Toggle Preview Inspector | `Cmd+Opt+I` |
| Multi-select Rows | `Click`, `Cmd+Click`, `Shift+Click`, `Up`/`Down` Arrows |
| Toggle Checked State on Highlighted Rows | `Space` |
| Select All Eligible in Active Category | `Cmd+A` (list focus) or `Cmd+Opt+A` |
| Move Checked Items to Trash | `Cmd+Delete` |
| Permanently Delete Checked Items… | `Cmd+Shift+Delete` |

---

## Contributing

Contributions are welcome under our TDD and design standards. Read [CONTRIBUTING.md](CONTRIBUTING.md) and our [Code of Conduct](CODE_OF_CONDUCT.md) before opening a pull request.

---

## Acknowledgments

CleanerMac is original Swift software whose scanning heuristics and safety defense-in-depth drew inspiration from two open-source macOS utilities studied during architecture design:

- **[guhcostan/mac-cleaner-cli](https://github.com/guhcostan/mac-cleaner-cli)** — Inspired conservative risk categorization (never auto-selecting ambiguous user files), Dry-Run workflow clarity, and the 24-hour grace window on active browser downloads.
- **[iliyami/MacSai](https://github.com/iliyami/MacSai)** — Inspired APFS firmlink canonicalization, symlink TOCTOU target validation, dotted bundle-ID lineage with helper-suffix stripping and empty-app-index fail-safes, `(st_dev, st_ino)` hard-link tracking, and inode-verified Trash restore receipts.

Bundled editorial typography uses **Instrument Serif**, licensed under the [SIL Open Font License 1.1](Sources/CleanerUI/Resources/Fonts/OFL.txt).

---

## License

Licensed under the MIT License. See [LICENSE](LICENSE) for full text.
