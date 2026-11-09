# CleanerMac Design System

> **Design Philosophy:** Calm editorial utility. CleanerMac treats disk hygiene with the precision of an archival catalog — pairing **Instrument Serif** editorial display typography with **SF Pro** / **SF Mono** functional clarity over translucent **macOS Sequoia / Tahoe** materials. Every surface prioritizes scannability, reversibility, and zero visual noise.

---

## 1. Non-Negotiable Visual Principles

1. **Zero Emoji Anywhere:** No emoji characters in headings, category rows, risk badges, empty states, alerts, or menus. Use **SF Symbols** (`>= SF Symbols 5`) or custom monochrome vector shapes exclusively.
2. **Translucent Depth Hierarchy:** Sidebars, toolbars, and floating progress HUDs sit on macOS system materials (`.ultraThinMaterial`, `.thinMaterial`, `.regularMaterial`), allowing desktop wallpaper tinting while preserving WCAG AA text contrast.
3. **Honest Safety Signaling:** Risky items explain *why* in plain prose. Safe/dry-run states are unmistakably differentiated from destructive states by both color and shape/iconography (never color alone).
4. **Full Keyboard & VoiceOver Parity:** Every interactive element supports keyboard focus, standard macOS shortcuts, Dynamic Type scaling, and meaningful `accessibilityLabel` / `accessibilityValue` / `accessibilityHint` descriptors.

---

## 2. Color Tokens

All color tokens resolve dynamically through semantic SwiftUI / AppKit colors and calibrated adaptive tokens for **Light Mode**, **Dark Mode**, and **Increased Contrast** (`accessibilityContrast == .increased`).

### 2.1 Surface & Material Tokens

| Token | Light Mode | Dark Mode | Usage |
| :--- | :--- | :--- | :--- |
| `surface.sidebar` | `.ultraThinMaterial` | `.ultraThinMaterial` | Navigation sidebar & category rail |
| `surface.toolbar` | `.ultraThinMaterial` | `.ultraThinMaterial` | Top window bar & dry-run status ribbon |
| `surface.canvas` | `Color(nsColor: .windowBackgroundColor)` | `Color(nsColor: .windowBackgroundColor)` | Primary list canvas behind file rows |
| `surface.card` | `Color.primary.opacity(0.035)` | `Color.white.opacity(0.055)` | Metric wells, summary tiles, metadata cards |
| `surface.inspector` | `.thinMaterial` | `.thinMaterial` | Right-hand live preview pane |
| `surface.hud` | `.regularMaterial` | `.regularMaterial` | Floating scan progress capsule & toast banner |
| `surface.sheet` | `.regularMaterial` | `.regularMaterial` | Confirmation & dry-run report sheets |
| `border.hairline` | `Color.primary.opacity(0.10)` | `Color.white.opacity(0.12)` | `1px` structural dividers & card strokes |
| `border.focusRing` | `Color.accentColor` | `Color.accentColor` | `2pt` focus indicator for keyboard navigation |

### 2.2 Text & Foreground Tokens

| Token | Resolution | Contrast Target | Usage |
| :--- | :--- | :--- | :--- |
| `text.primary` | `Color.primary` | `>= 7:1` | Display titles, file names, primary metrics |
| `text.secondary` | `Color.secondary` | `>= 4.5:1` | Relative paths, modified dates, secondary metadata |
| `text.tertiary` | `Color.primary.opacity(0.48)` | `>= 3:1` (large/icons) | Section kickers, subtle separators, disabled hints |
| `text.inverted` | `Color.white` (on accent/danger fill) | `>= 4.5:1` | Filled CTA button labels |

### 2.3 Semantic Status & Risk Tokens

| Token | Light Value | Dark Value | Paired SF Symbol | Meaning |
| :--- | :--- | :--- | :--- | :--- |
| `status.safe` | `#1E7F5C` (Forest Green) | `#48C78E` | `checkmark.shield` | Safe cache/empty folder, dry-run pass, Trash undo |
| `status.caution` | `#B25E09` (Warm Amber) | `#F5A623` | `exclamationmark.triangle` | Moderate risk (orphaned app data, large media, old files) |
| `status.danger` | `#C62828` (Crimson) | `#FF5F56` | `exclamationmark.octagon` | High risk or Permanent Delete destructive action |
| `status.info` | `Color.accentColor` | `Color.accentColor` | `sparkles` / `arrow.triangle.2.circlepath` | Active scan, dry-run mode indicator, selected item |
| `badge.keep` | `#1E7F5C` @ `12%` fill | `#48C78E` @ `16%` fill | `pin.fill` | Suggested "Keep Original" in Duplicate groups |

> **Accessibility Rule:** Risk indicators always pair semantic color with a distinct **SF Symbol** and explicit text label (`Low Risk`, `Review Carefully`, `High Risk`) so color-blind users and VoiceOver never rely on hue alone.

---

## 3. Typography Scale

### 3.1 Font Families
- **Display & Headings:** `Instrument Serif` (`InstrumentSerif-Regular`, `InstrumentSerif-Italic`), bundled under SIL OFL 1.1 in `Resources/Fonts/` and registered at launch via `CTFontManagerRegisterFontsForURL`. Fallback: `.system(..., design: .serif)`.
- **Body, Controls & Labels:** System sans-serif (`SF Pro`, via `Font.system(...)`).
- **Paths, Byte Sizes, Hashes & Timestamps:** System monospaced (`SF Mono`, via `Font.system(..., design: .monospaced).monospacedDigit()`).

### 3.2 Type Scale (Dynamic Type Enabled via `@ScaledMetric`)

| Token | Family & Weight | Base Size | Line Height | Tracking | Usage |
| :--- | :--- | :--- | :--- | :--- | :--- |
| `type.hero` | `InstrumentSerif-Regular` | `36 pt` | `40 pt` | `-0.02 em` | Empty/welcome state headline, Dry-Run total summary |
| `type.titleLarge` | `InstrumentSerif-Regular` | `28 pt` | `32 pt` | `-0.015 em` | Category header title ("Duplicates", "Large Files") |
| `type.titleSection` | `InstrumentSerif-Regular` | `21 pt` | `25 pt` | `-0.01 em` | Preview pane file title, confirmation sheet header |
| `type.titleItalic` | `InstrumentSerif-Italic` | `21 pt` | `25 pt` | `0 em` | Editorial sub-emphasis (e.g., *"reclaimable space"*) |
| `type.headline` | `SF Pro Semibold` | `14 pt` | `18 pt` | `0 em` | Group headers, card titles, primary CTA labels |
| `type.body` | `SF Pro Regular` | `13 pt` | `18 pt` | `0 em` | Explanations, risk reasons, list row titles |
| `type.callout` | `SF Pro Medium` | `12 pt` | `16 pt` | `0 em` | Badges, toolbar filter pills, sidebar items |
| `type.caption` | `SF Pro Regular` | `11 pt` | `14 pt` | `+0.01 em` | Secondary subtitles, status bar hints |
| `type.monoMetric` | `SF Mono Medium` (tabular) | `13 pt` | `17 pt` | `0 em` | File sizes (`1.42 GB`), byte counts, counters |
| `type.monoPath` | `SF Mono Regular` | `11 pt` | `15 pt` | `0 em` | File system paths, SHA-256 prefixes, UTI strings |

---

## 4. Spacing Grid & Layout Geometry

CleanerMac follows a strict **`4 pt` base grid**:

| Token | Value | Application |
| :--- | :--- | :--- |
| `space.2xs` | `4 pt` | Tight icon-to-label gap inside badges, inline dividers |
| `space.xs` | `8 pt` | Standard sibling spacing (checkbox to icon, pill padding) |
| `space.sm` | `12 pt` | List row vertical padding, inspector property gaps |
| `space.md` | `16 pt` | Card internal padding, sidebar section spacing, sheet margins |
| `space.lg` | `24 pt` | Pane header breathing room, section separation |
| `space.xl` | `32 pt` | Empty state spacing, confirmation sheet top/bottom anchor |
| `space.2xl` | `40 pt` | Hero welcome composition margins |

### Window & Pane Proportions
- **Minimum Window Size:** `980 × 640 pt` (ideal default `1240 × 780 pt`).
- **Left Sidebar (`NavigationSplitView` sidebar):** `min: 220 pt`, `ideal: 252 pt`, `max: 300 pt`.
- **Center Results Column:** `min: 400 pt`, flexible fill.
- **Right Preview Inspector:** `min: 310 pt`, `ideal: 360 pt`, `max: 440 pt`, collapsible via toolbar toggle or `Cmd+Opt+I`.

---

## 5. Corner Radii & Elevation Rules

### 5.1 Radii

| Token | Radius | Usage |
| :--- | :--- | :--- |
| `radius.xs` | `4 pt` | Risk pills, UTI badges, keyboard shortcut caps |
| `radius.sm` | `8 pt` | List row selection highlight, standard push buttons, text previews |
| `radius.md` | `12 pt` | Preview media frame, metadata property cards, grouped duplicate card |
| `radius.lg` | `16 pt` | Floating background-scan HUD capsule, modal confirmation sheets |
| `radius.pill` | `999 pt` | Dry-Run status badge, inline filter chips |

### 5.2 Elevation & Stroke Hierarchy
1. **Level 0 — Recessed Canvas:** Native window background with zero shadow.
2. **Level 1 — Grouped Surface (`surface.card`):** `1 px` `border.hairline` stroke, zero drop shadow.
3. **Level 2 — Translucent Chrome (`.ultraThinMaterial` / `.thinMaterial`):** Sidebar and Preview Inspector separated by native split dividers.
4. **Level 3 — Floating Scan HUD (`.regularMaterial`):** `1 px` `border.hairline` + soft ambient shadow (`Color.black.opacity(0.14)`, `radius: 14, y: 6`).
5. **Level 4 — Modal Sheet (`.regularMaterial`):** System macOS modal presentation with generous `24 pt` internal margins.

---

## 6. Iconography Specification

- **Strict SF Symbols Policy:** All icons derive from SF Symbols at `1.0` optical weight matching adjacent text. Zero emoji anywhere.
- **Category Symbols:**
  - Duplicates: `doc.on.doc`
  - Large Files: `externaldrive.badge.exclamationmark` or `arrow.up.left.and.arrow.down.right`
  - Old Files: `clock.arrow.circlepath`
  - Dead / Leftover Files: `tray.full` / `folder.badge.questionmark`
  - Restore History: `arrow.uturn.backward.circle`
- **Action & Safety Symbols:**
  - Start Scan: `magnifyingglass`
  - Pause / Resume: `pause.fill` / `play.fill`
  - Cancel: `xmark.circle`
  - Dry Run: `eye` / `testtube.2`
  - Move to Trash: `trash`
  - Permanent Delete: `flame` or `trash.slash` (styled in `status.danger`)
  - Protected Path / Shield: `lock.shield`
  - Reveal in Finder: `finder` or `folder`

---

## 7. Motion & Animation Guidelines

| Transition | Timing Curve | Reduce Motion Fallback |
| :--- | :--- | :--- |
| Selection / Hover Highlight | `easeOut(duration: 0.12)` | Instant opacity swap |
| Streaming Result Insertion | `easeInOut(duration: 0.18)` (batched every `80 ms`) | Instant list update |
| Preview Pane Crossfade | `easeInOut(duration: 0.20)` | Instant content swap |
| Inspector Collapse / Expand | `spring(response: 0.28, dampingFraction: 0.88)` | Instant width toggle |
| Floating Scan HUD Appear/Hide | `spring(response: 0.30, dampingFraction: 0.85)` | `opacity` fade `0.15 s` |
| Indeterminate / Progress Bar | Smooth linear interpolation (`0.20 s`) | Discrete step update |

All animated modifiers check `@Environment(\.accessibilityReduceMotion)` and downgrade spatial slides/scales to gentle opacity transitions or instant state updates.

---

## 8. Component Specifications

### 8.1 Buttons
- **Primary Safe Action ("Move to Trash"):** Height `30 pt` (regular controlSize), horizontal padding `14 pt`, `radius.sm`, `.borderedProminent` tint, SF Symbol `trash` + count & formatted bytes (`"Move 12 Items (1.84 GB) to Trash"`).
- **Secondary Action ("Pause", "Dry Run"):** `.bordered` material button, `1 px` `border.hairline`, height `28 pt`.
- **Destructive Gated Action ("Permanently Delete…"):** Never primary; uses trailing ellipsis (`…`) to signal mandatory confirmation sheet, tinted `status.danger` foreground with `trash.slash` symbol.

### 8.2 File Result Row
- **Height:** `56 pt` (two-line dense layout, expands dynamically under larger Dynamic Type sizes).
- **Anatomy (Leading -> Trailing):**
  1. Selection checkbox (`16 × 16 pt`, `Space` or click to toggle cleanup inclusion).
  2. File type thumbnail/icon (`28 × 28 pt` rounded `4 pt`).
  3. Primary column: File name (`type.body`, semibold when selected) + Risk Pill (`badge.risk`) on line 1; truncated parent path (`type.monoPath`, `.middle` truncation) + age/detail tag on line 2.
  4. Trailing column: Formatted byte size (`type.monoMetric`, right-aligned, tabular numerals) + quick status icon (e.g., `Keep` pin for duplicate original, `Lock` for protected/uncleanable).
- **Multi-Selection Behavior:**
  - Click: Focuses item in Preview Pane (does not accidentally check/uncheck cleanup box unless clicking the checkbox or pressing `Space`/`X`).
  - `Cmd + Click`: Adds/removes row from active multi-selection highlight.
  - `Shift + Click`: Range-selects rows between anchor and clicked row.
  - `Cmd + A`: Selects all actionable rows in the current category (never selects `Keep` duplicate originals or protected items unless explicitly forced).
  - `Space`: Toggles cleanup inclusion for all highlighted rows (or opens Quick Look / expands preview when focused on single action).

### 8.3 Preview Pane (`CleanerPreview`)
- **Header:** `Instrument Serif` (`type.titleSection`) file name, SF Symbol file-kind badge, `Reveal in Finder` icon button, and full selectable `type.monoPath`.
- **Visual Stage (`maxHeight: 280 pt`, `radius.md`, `surface.card`):**
  - *Image:* Aspect-fit downsampled preview + dimensions (`4032 × 3024 px`), color space, camera/EXIF summary.
  - *Video:* Scrubbed poster frame (`AVAssetImageGenerator`) + duration badge, resolution, codec, FPS.
  - *PDF:* Embedded `PDFView` with single/continuous page scroll + page count indicator.
  - *Text / Code:* Scrollable monospaced viewport with line numbers and explicit `"Showing first 256 KB of X"` banner when truncated.
  - *Audio:* Album/artist/title metadata card + duration, sample rate (`48 kHz`), channels, and Play/Pause local preview button (`AVAudioPlayer` / `AVPlayer`).
  - *Fallback:* Crisp `QLThumbnailGenerator` icon + quick summary banner.
- **Metadata & Safety Grid:**
  - Logical Size vs. Allocated Size (APFS), Created / Modified / Last Accessed dates, Hard-Link Count, POSIX permissions, UTI, and **Safety / Risk Card** explaining the exact rule or warning reason.

### 8.4 Background Scan Status HUD
- Docked pill (`radius.lg`, `.regularMaterial`) anchored in the bottom of the sidebar or top toolbar:
  - Phase label (`"Scanning ~/Downloads…"` in `type.callout`), live file & byte counters (`type.monoMetric`), determinate/indeterminate bar, and inline **Pause / Resume** (`pause.fill` / `play.fill`) + **Cancel** (`xmark`) buttons.

### 8.5 Dry-Run Banner & Report Sheet
- When **Dry-Run Mode** is toggled on in the toolbar (`status.info` pill with `eye` icon):
  - Top ribbon clearly states `"Dry-Run Active — No files will be moved or deleted"`.
  - Clicking `"Simulate Cleanup"` opens a sheet summarizing exact counts, simulated reclaimable space, and any items blocked by `SafetyGuard`.

### 8.6 Confirmation Sheets
- **Move to Trash Sheet:** Lists item count, total reclaimable size, destination (`~/.Trash`), and note that items can be restored from Trash or History. Primary CTA: `"Move to Trash"`.
- **Permanent Deletion Sheet (Double-Gated):**
  - High-contrast `status.danger` header (`Instrument Serif`), explicit irreversibility warning (*"Items will bypass the Trash and cannot be recovered."*), scrollable path list, and an explicit secondary confirmation toggle/checkbox (`"I understand these files will be permanently erased"`) before the `"Permanently Delete"` destructive button enables.

