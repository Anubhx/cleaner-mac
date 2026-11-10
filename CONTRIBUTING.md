# Contributing to CleanerMac

Thank you for helping improve CleanerMac. This project prioritizes **safety, reversibility, test-driven engineering, and calm Apple-native UI craft**.

---

## Architecture Boundaries

CleanerMac uses a clean, 5-target Swift Package structure:

1. **`CleanerCore`** — Pure Swift domain models, safety rules (`SafetyGuard`, `RiskEvaluator`, `DeletionPlanner`), duplicate/hard-link/orphan logic, and restore receipt policies. **Zero UI frameworks (`SwiftUI`, `AppKit`, `PDFKit`, `AVFoundation`).**
2. **`CleanerSystem`** — Low-priority background filesystem walker (`ScanCoordinator`), streaming SHA-256 hashing, orphan detection adapters, Trash/delete executor, and JSON restore history storage.
3. **`CleanerPreview`** — On-demand, memory-bounded preview providers (`ImagePreviewProvider`, `VideoPreviewProvider`, `PDFPreviewProvider`, `TextPreviewProvider`, `AudioPreviewProvider`, `MetadataSnapshotProvider`).
4. **`CleanerUI`** — Design tokens (`Instrument Serif` + `SF Pro`/`SF Mono`), translucent SwiftUI components, multi-select state, and workspace views. Depends on `CleanerCore` and `CleanerPreview` via service protocols — **never imports `CleanerSystem` directly**.
5. **`CleanerApp`** — Application entry point binding concrete `CleanerSystem` actors to `CleanerUI`.

Respect these dependency arrows in every change (`docs/ARCHITECTURE.md`).

---

## Development Setup

### Prerequisites
- macOS 14.0 (Sonoma) or newer (Apple Silicon / `arm64` only)
- Swift 6.0+ toolchain (either full Xcode 16+ or Apple Command Line Tools)

### Running Tests

```bash
./scripts/run-tests.sh
```

> `scripts/run-tests.sh` automatically works on both full Xcode installations (`swift test`) and standalone Apple Command Line Tools (`swift test --disable-xctest --enable-swift-testing ...`).

### Building the `.app` Bundle

```bash
./scripts/package-app.sh
open dist/CleanerMac.app
```

---

## Engineering & Design Standards

1. **Test-Driven Development (TDD):**
   - Write a failing test (`RED`) in the matching target (`Tests/CleanerCoreTests`, `Tests/CleanerSystemTests`, `Tests/CleanerPreviewTests`, or `Tests/CleanerUITests`) before writing production code.
   - Make the minimal implementation pass (`GREEN`), then refactor cleanly (`REFACTOR`).
   - Maintain **>= 80% code coverage** for new modules and safety-critical logic.
2. **Design System Compliance (`docs/DESIGN_SYSTEM.md`):**
   - **Zero emoji anywhere** in UI strings, labels, icons, or logs shown to users. Use **SF Symbols** exclusively.
   - Use **Instrument Serif** for editorial display and section titles (`CleanerTypography`) and `SF Pro` / `SF Mono` for body text and numeric/path metrics.
   - Support Light & Dark Mode, Dynamic Type, Reduce Motion, keyboard navigation, and VoiceOver labels on every interactive control.
3. **Zero Network Calls:**
   - Do not import `Network` or call `URLSession` anywhere in `Sources/`. CleanerMac is strictly offline and local.
4. **Safety First:**
   - Never bypass `SafetyGuard` or `DeletionPlanner`.
   - Any destructive change must keep **Move to Trash** as the default and gate permanent deletion behind explicit confirmation.

---

## Pull Request Checklist

- [ ] Architecture boundaries preserved (`CleanerCore` pure; `CleanerUI` decoupled from `CleanerSystem`).
- [ ] New behavior covered by failing-first Swift Testing unit or integration tests.
- [ ] `./scripts/run-tests.sh` passes cleanly with zero compiler warnings.
- [ ] `swift build` passes cleanly.
- [ ] Zero emoji added to UI strings or components.
- [ ] Documentation (`docs/SAFETY_RULES.md`, `docs/TEST_PLAN.md`, `README.md`) updated if rules or behavior changed.
