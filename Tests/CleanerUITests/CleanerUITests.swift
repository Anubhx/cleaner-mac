import Testing
import Foundation
import os
import AppKit
import SwiftUI
@testable import CleanerCore
@testable import CleanerPreview
@testable import CleanerUI

@Suite("CleanerUI Selection, Fonts & Workspace State")
struct CleanerUITests {
    private func makeItem(
        name: String,
        size: UInt64 = 1024,
        category: ScanCategory = .largeFiles,
        keep: Bool = false
    ) -> ScannedItem {
        ScannedItem(
            url: URL(fileURLWithPath: "/Users/alice/Downloads/\(name)"),
            name: name,
            logicalSize: size,
            allocatedSize: size,
            isDirectory: false,
            category: category,
            isRecommendedKeep: keep
        )
    }

    @Test("Registers bundled Instrument Serif Regular and Italic fonts")
    func registersInstrumentSerifFonts() {
        InstrumentSerifFontRegistrar.registerBundledFonts()
        #expect(NSFont(name: "InstrumentSerif-Regular", size: 28) != nil)
        #expect(NSFont(name: "InstrumentSerif-Italic", size: 22) != nil)
    }

    @Test("Supports single, Cmd-toggle, Shift-range, and Spacebar cleanup multi-selection")
    func multiSelectSupportsKeyboardAndModifiers() {
        let items = [
            makeItem(name: "a.zip"),
            makeItem(name: "b.zip"),
            makeItem(name: "c.zip"),
            makeItem(name: "d.zip"),
        ]
        var selection = MultiSelectState()

        selection.handleClick(id: items[0].id, modifiers: [], orderedIDs: items.map(\.id))
        #expect(selection.focusedID == items[0].id)
        #expect(selection.highlightedIDs == [items[0].id])

        selection.handleClick(id: items[2].id, modifiers: [.shift], orderedIDs: items.map(\.id))
        #expect(selection.highlightedIDs == [items[0].id, items[1].id, items[2].id])

        selection.handleClick(id: items[1].id, modifiers: [.command], orderedIDs: items.map(\.id))
        #expect(selection.highlightedIDs == [items[0].id, items[2].id])

        selection.toggleCheckedForHighlighted(items: items)
        #expect(selection.checkedIDs == [items[0].id, items[2].id])
    }

    @Test("Select All per category skips recommended Keep originals")
    func selectAllSkipsRecommendedKeepOriginals() {
        let keepOriginal = makeItem(name: "orig.png", category: .duplicates, keep: true)
        let dup1 = makeItem(name: "orig-copy.png", category: .duplicates, keep: false)
        let dup2 = makeItem(name: "orig-copy2.png", category: .duplicates, keep: false)
        var selection = MultiSelectState()

        selection.selectAllEligible(in: [keepOriginal, dup1, dup2])
        #expect(!selection.checkedIDs.contains(keepOriginal.id))
        #expect(selection.checkedIDs == [dup1.id, dup2.id])
    }

    @Test("Workspace Dry-Run preserves items and exposes report without mutating state")
    @MainActor
    func dryRunDoesNotRemoveItemsFromWorkspace() async {
        let item = makeItem(name: "archive.tar", size: 50_000)
        let fakeScanner = FakeScanningService(outcome: ScanOutcome(itemsByCategory: [.largeFiles: [item]]))
        let fakeDeleter = FakeDeletionService()
        let fakeHistory = FakeHistoryService()

        let store = CleanerWorkspaceStore(
            scanner: fakeScanner,
            deleter: fakeDeleter,
            historyStore: fakeHistory,
            previewService: PreviewService()
        )
        store.selectedSidebarDestination = .category(.largeFiles)
        await store.startScan()

        #expect(store.visibleItems.count == 1)
        store.selectAllInActiveCategory()
        store.isDryRunEnabled = true
        await store.executeSelectedCleanup(mode: .moveToTrash)

        #expect(store.lastExecutionReport?.isDryRun == true)
        #expect(store.lastExecutionReport?.succeededCount == 1)
        #expect(store.visibleItems.count == 1)
    }

    @Test("Moving to Trash removes deleted URL across overlapping categories and updates history")
    @MainActor
    func trashCleanupRemovesItemAcrossCategoriesAndLogsHistory() async {
        let sharedURL = URL(fileURLWithPath: "/Users/alice/Downloads/big-old.iso")
        let large = ScannedItem(url: sharedURL, name: "big-old.iso", logicalSize: 8000, allocatedSize: 8000, isDirectory: false, category: .largeFiles)
        let old = ScannedItem(url: sharedURL, name: "big-old.iso", logicalSize: 8000, allocatedSize: 8000, isDirectory: false, category: .oldFiles)

        let outcome = ScanOutcome(itemsByCategory: [.largeFiles: [large], .oldFiles: [old]])
        let fakeScanner = FakeScanningService(outcome: outcome)
        let fakeDeleter = FakeDeletionService()
        let fakeHistory = FakeHistoryService()

        let store = CleanerWorkspaceStore(
            scanner: fakeScanner,
            deleter: fakeDeleter,
            historyStore: fakeHistory,
            previewService: PreviewService()
        )
        store.selectedSidebarDestination = .category(.largeFiles)
        await store.startScan()
        store.selectAllInActiveCategory()
        store.isDryRunEnabled = false
        await store.executeSelectedCleanup(mode: .moveToTrash)

        #expect(store.items(for: .largeFiles).isEmpty)
        #expect(store.items(for: .oldFiles).isEmpty)
        #expect(store.historyEntries.count == 1)

        if let entry = store.historyEntries.first {
            await store.restoreHistoryEntry(entry)
            #expect(store.historyEntries.isEmpty)
            #expect(store.statusBannerMessage?.contains("Restored") == true)
        }
    }

    @Test("Keyboard arrow movement and Shift-extend update highlighted selection and toggle checks")
    func keyboardMoveAndSpaceToggle() {
        let items = [makeItem(name: "1.mov"), makeItem(name: "2.mov"), makeItem(name: "3.mov")]
        var selection = MultiSelectState()
        let ids = items.map(\.id)

        selection.handleClick(id: ids[0], modifiers: [], orderedIDs: ids)
        selection.moveFocus(offset: 1, orderedIDs: ids, extendSelection: true)
        #expect(selection.focusedID == ids[1])
        #expect(selection.highlightedIDs == [ids[0], ids[1]])

        selection.toggleCheckedForHighlighted(items: items)
        #expect(selection.checkedIDs == [ids[0], ids[1]])
    }

    @Test("Filters, sorts, and computes duplicate reclaimable bytes while respecting Keep originals")
    @MainActor
    func filteringSortingAndSingleItemTrashRequest() async {
        let orig = makeItem(name: "alpha-master.dmg", size: 5_000, category: .duplicates, keep: true)
        let copy = makeItem(name: "zeta-copy.dmg", size: 5_000, category: .duplicates, keep: false)
        let group = DuplicateGroup(id: "hash1", original: orig, duplicates: [copy])
        let outcome = ScanOutcome(
            itemsByCategory: [.duplicates: group.allItems],
            duplicateGroups: [group]
        )

        let store = CleanerWorkspaceStore(
            scanner: FakeScanningService(outcome: outcome),
            deleter: FakeDeletionService(),
            historyStore: FakeHistoryService(),
            previewService: PreviewService()
        )
        store.selectedSidebarDestination = .category(.duplicates)
        await store.startScan()

        #expect(store.reclaimableBytes(for: .duplicates) == 5_000)
        store.searchQuery = "zeta"
        #expect(store.filteredDuplicateGroups.count == 1)
        #expect(store.visibleItems.map(\.name) == ["zeta-copy.dmg"])

        store.searchQuery = ""
        store.sortOrder = .nameAscending
        #expect(store.visibleItems.map(\.name) == ["alpha-master.dmg", "zeta-copy.dmg"])

        store.requestSingleTrash(item: orig)
        #expect(store.showingTrashConfirmation == false)

        store.requestSingleTrash(item: copy)
        #expect(store.showingTrashConfirmation == true)
        #expect(store.pendingDeletionBytes == 5_000)
        await store.executePendingCleanup(mode: .moveToTrash)
        #expect(store.items(for: .duplicates).map(\.name) == ["alpha-master.dmg"])
    }

    @Test("Pausable background scan transitions between enumerating, paused, resume, and cancel")
    @MainActor
    func workspacePauseResumeAndCancelFlow() async {
        let scanner = ControllableFakeScanner()
        let store = CleanerWorkspaceStore(
            scanner: scanner,
            deleter: FakeDeletionService(),
            historyStore: FakeHistoryService(),
            previewService: PreviewService()
        )

        let scanTask = Task { await store.startScan() }
        await scanner.waitUntilStarted()
        #expect(store.isScanning == true)

        await store.pauseScan()
        #expect(store.isPaused == true)
        #expect(store.progress.phase == .paused)

        await store.cancelScan()
        _ = await scanTask.value
        #expect(store.isScanning == false)
        #expect(store.isPaused == false)
    }

    @Test("Rejects unconfirmed permanent deletion and surfaces safety error banner")
    @MainActor
    func unconfirmedPermanentDeleteBlockedAtWorkspaceLayer() async {
        let item = makeItem(name: "temp.iso", size: 2048)
        let store = CleanerWorkspaceStore(
            scanner: FakeScanningService(outcome: ScanOutcome(itemsByCategory: [.largeFiles: [item]])),
            deleter: StrictDeletionService(),
            historyStore: FakeHistoryService(),
            previewService: PreviewService()
        )
        store.selectedSidebarDestination = .category(.largeFiles)
        await store.startScan()
        store.selectAllInActiveCategory()
        await store.executeSelectedCleanup(mode: .permanentDelete(confirmed: false))
        #expect(store.statusBannerMessage?.contains("confirmation") == true)
        #expect(store.items(for: .largeFiles).count == 1)
    }

    @Test("Instantiates root SwiftUI views cleanly without missing design tokens or assets")
    @MainActor
    func rootViewsInstantiateCleanly() {
        let store = CleanerWorkspaceStore(
            scanner: FakeScanningService(outcome: ScanOutcome()),
            deleter: FakeDeletionService(),
            historyStore: FakeHistoryService(),
            previewService: PreviewService()
        )
        _ = CleanerRootView(store: store).body
        _ = HistoryView(store: store).body
        _ = ScanSettingsView(store: store).body
        _ = ResultsListView(store: store, category: .duplicates).body
    }

    @Test("Supports clear checks, sort orders, and resume scan transitions")
    @MainActor
    func clearChecksSortOrdersAndResumeFlow() async {
        let older = ScannedItem(
            url: URL(fileURLWithPath: "/Users/alice/Downloads/older.log"),
            name: "older.log",
            logicalSize: 100,
            allocatedSize: 100,
            isDirectory: false,
            modifiedDate: Date(timeIntervalSince1970: 1_000_000),
            category: .largeFiles,
            risk: RiskAssessment(level: .low, reason: "low")
        )
        let risky = ScannedItem(
            url: URL(fileURLWithPath: "/Users/alice/Downloads/risky.log"),
            name: "risky.log",
            logicalSize: 500,
            allocatedSize: 500,
            isDirectory: false,
            modifiedDate: Date(timeIntervalSince1970: 2_000_000),
            category: .largeFiles,
            risk: RiskAssessment(level: .high, reason: "high")
        )
        let scanner = ControllableFakeScanner()
        let store = CleanerWorkspaceStore(
            scanner: scanner,
            deleter: FakeDeletionService(),
            historyStore: FakeHistoryService(),
            previewService: PreviewService()
        )
        store.selectedSidebarDestination = .category(.largeFiles)
        store.itemsByCategory[.largeFiles] = [older, risky]

        store.sortOrder = .dateOldest
        #expect(store.visibleItems.map(\.name) == ["older.log", "risky.log"])

        store.sortOrder = .riskHighest
        #expect(store.visibleItems.map(\.name) == ["risky.log", "older.log"])

        store.selectAllInActiveCategory()
        #expect(store.checkedItemsInAllCategories.count == 2)
        store.clearChecksInActiveCategory()
        #expect(store.checkedItemsInAllCategories.isEmpty)

        let scanTask = Task { await store.startScan() }
        await scanner.waitUntilStarted()
        await store.pauseScan()
        #expect(store.isPaused == true)
        await store.resumeScan()
        #expect(store.isScanning == false)
        _ = await scanTask.value
    }

    @Test("Sorts duplicate groups using workspace sortOrder and omits zero-byte action size label")
    @MainActor
    func duplicateGroupSortingAndZeroByteActionLabel() async {
        let g1 = DuplicateGroup(
            id: "h1",
            original: makeItem(name: "z-file.png", size: 200, category: .duplicates, keep: true),
            duplicates: [makeItem(name: "z-copy.png", size: 200, category: .duplicates, keep: false)]
        )
        let g2 = DuplicateGroup(
            id: "h2",
            original: makeItem(name: "a-file.png", size: 900, category: .duplicates, keep: true),
            duplicates: [makeItem(name: "a-copy.png", size: 900, category: .duplicates, keep: false)]
        )
        let outcome = ScanOutcome(itemsByCategory: [.duplicates: g1.allItems + g2.allItems], duplicateGroups: [g1, g2])
        let store = CleanerWorkspaceStore(
            scanner: FakeScanningService(outcome: outcome),
            deleter: FakeDeletionService(),
            historyStore: FakeHistoryService(),
            previewService: PreviewService()
        )
        await store.startScan()

        store.sortOrder = .nameAscending
        #expect(store.filteredDuplicateGroups.map(\.original.name) == ["a-file.png", "z-file.png"])

        store.sortOrder = .sizeDescending
        #expect(store.filteredDuplicateGroups.map(\.original.name) == ["a-file.png", "z-file.png"])

        #expect(ByteFormatting.actionSizeSuffix(bytes: 0) == "")
        #expect(!ByteFormatting.actionSizeSuffix(bytes: 2048).isEmpty)
    }

    @Test("Exposes Scan Again title and symbol after scan completion or cancellation")
    @MainActor
    func scanAgainActionTransitions() async {
        let outcome = ScanOutcome(
            progress: ScanProgress(phase: .completed, scannedFiles: 12, bytesEvaluated: 4096)
        )
        let store = CleanerWorkspaceStore(
            scanner: FakeScanningService(outcome: outcome),
            deleter: FakeDeletionService(),
            historyStore: FakeHistoryService(),
            previewService: PreviewService()
        )
        #expect(store.hasCompletedOrCancelledScan == false)
        #expect(store.primaryScanActionTitle == "Scan Mac")
        #expect(store.primaryScanActionSymbol == "magnifyingglass")

        await store.startScan()
        #expect(store.hasCompletedOrCancelledScan == true)
        #expect(store.primaryScanActionTitle == "Scan Again")
        #expect(store.primaryScanActionSymbol == "arrow.clockwise")

        store.progress.phase = .cancelled
        #expect(store.hasCompletedOrCancelledScan == true)
        #expect(store.primaryScanActionTitle == "Scan Again")

        _ = BackgroundScanHUD(
            progress: store.progress,
            isScanning: false,
            isPaused: false,
            onPause: {},
            onResume: {},
            onCancel: {},
            onRescan: {}
        ).body
    }

    @Test("Workspace store releases cleanly during suspended preview load and cancels preview task on deinit")
    @MainActor
    func workspaceDeallocatesDuringInFlightPreviewLoad() async {
        let previewService = SuspendablePreviewService()
        let item = makeItem(name: "huge-video.mov", size: 4_096, category: .largeFiles)
        weak var weakStore: CleanerWorkspaceStore?

        do {
            let store = CleanerWorkspaceStore(
                scanner: FakeScanningService(outcome: ScanOutcome(itemsByCategory: [.largeFiles: [item]])),
                deleter: FakeDeletionService(),
                historyStore: FakeHistoryService(),
                previewService: previewService
            )
            weakStore = store
            store.selectedSidebarDestination = .category(.largeFiles)
            store.itemsByCategory[.largeFiles] = [item]
            store.clickRow(item, modifiers: [])
            await previewService.waitUntilStarted()
        }

        await Task.yield()
        #expect(weakStore == nil)
        #expect(await previewService.wasCancelled == true)
    }

    @Test("Overlapping startScan prevents stale scan outcome from overwriting newer scan results")
    @MainActor
    func overlappingStartScanIgnoresStaleOutcome() async {
        let staleItem = makeItem(name: "stale.iso", size: 100, category: .largeFiles)
        let freshItem = makeItem(name: "fresh.iso", size: 900, category: .largeFiles)
        let scanner = OverlappingGenerationsFakeScanner(staleItem: staleItem, freshItem: freshItem)

        let store = CleanerWorkspaceStore(
            scanner: scanner,
            deleter: FakeDeletionService(),
            historyStore: FakeHistoryService(),
            previewService: PreviewService()
        )
        store.selectedSidebarDestination = .category(.largeFiles)

        let firstScanTask = Task { await store.startScan() }
        await scanner.waitUntilFirstScanSuspended()

        let secondScanTask = Task { await store.startScan() }
        await secondScanTask.value

        #expect(store.items(for: .largeFiles).map(\.name) == ["fresh.iso"])
        #expect(store.isScanning == false)

        await scanner.releaseFirstScan()
        await firstScanTask.value

        #expect(store.items(for: .largeFiles).map(\.name) == ["fresh.iso"])
        #expect(store.isScanning == false)
        #expect(store.progress.phase == .completed)
    }

    @Test("Routes @FocusedValue command actions, guards Keep Originals, and instantiates headless Settings view")
    @MainActor
    func focusedValueCommandsAndSettingsSceneView() async {
        let keepItem = makeItem(name: "orig.dmg", size: 500, category: .duplicates, keep: true)
        let removableItem = makeItem(name: "copy.dmg", size: 500, category: .duplicates, keep: false)
        let store = CleanerWorkspaceStore(
            scanner: FakeScanningService(outcome: ScanOutcome(itemsByCategory: [.duplicates: [keepItem, removableItem]])),
            deleter: FakeDeletionService(),
            historyStore: FakeHistoryService(),
            previewService: PreviewService()
        )
        store.selectedSidebarDestination = .category(.duplicates)
        await store.startScan()

        // Focused Keep Original cannot be checked or trashed via Cleanup menu commands
        store.clickRow(keepItem, modifiers: [])
        #expect(store.canToggleHighlightedChecks == false)
        store.requestTrashSelectionOrFocused()
        #expect(store.showingTrashConfirmation == false)

        // Focused removable item supports Toggle Selection Check & Move to Trash
        store.clickRow(removableItem, modifiers: [])
        #expect(store.canToggleHighlightedChecks == true)
        store.toggleHighlightedChecks()
        #expect(store.selection.checkedIDs == [removableItem.id])
        store.copyFocusedPath()
        #expect(NSPasteboard.general.string(forType: .string) == removableItem.url.path)

        store.requestTrashSelectionOrFocused()
        #expect(store.showingTrashConfirmation == true)
        #expect(store.pendingDeletionItems == [removableItem])

        // Headless Settings scene view instantiates cleanly
        _ = ScanSettingsView(store: store, showsHeader: false).body
    }

    @Test("Opaque app chrome hosts zero app-owned translucent backdrop or visual-effect surfaces")
    @MainActor
    func reduceTransparencyDisablesMaterialSurfaces() {
        struct ProbeVisualEffectView: NSViewRepresentable {
            func makeNSView(context: Context) -> NSVisualEffectView {
                let view = NSVisualEffectView()
                view.blendingMode = .withinWindow
                view.material = .hudWindow
                view.state = .active
                return view
            }

            func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
        }

        func owningView(for layer: CALayer) -> NSView? {
            var current: CALayer? = layer
            while let candidate = current {
                if let view = candidate.delegate as? NSView {
                    return view
                }
                current = candidate.superlayer
            }
            return nil
        }

        func isSystemManagedChrome(_ view: NSView) -> Bool {
            var current: NSView? = view
            while let node = current {
                let className = NSStringFromClass(type(of: node))
                // 1. System scroll pockets, Liquid Glass chrome, and control internals are always AppKit-owned.
                if className.contains("NSScrollPocket")
                    || className.contains("NSGlassEffectView")
                    || className.contains("NSContainerConcentricGlassEffectView")
                    || className.contains("_NSCoreHostingView")
                    || className.contains("_NSScrollViewContentBackgroundView")
                {
                    return true
                }
                // 2. App content boundaries (hosting views, cell hosts, SwiftUI scroll views, custom representables)
                //    stop system chrome inheritance so any material/VEV inside app content is flagged.
                if className.contains("NSHostingView")
                    || className.contains("CellHostingView")
                    || className.contains("HostingScrollView")
                {
                    return false
                }
                if className.contains("AppKitPlatformViewHost") {
                    return className.contains("NavigationSplitRepresentable")
                        || className.contains("OutlineListRepresentable")
                }
                // 3. macOS 14/15 AppKit split-view, titlebar, and sidebar outline chrome.
                if className.contains("NSTitlebar")
                    || className.contains("NSSplitView")
                    || className.contains("ListCore")
                    || className.contains("OutlineList")
                    || node is NSSplitView
                    || node is NSTableView
                {
                    return true
                }
                current = node.superview
            }
            return false
        }

        func collectAppOwnedBackdropLayers(in layer: CALayer?) -> [CALayer] {
            guard let layer else { return [] }
            var found: [CALayer] = []
            let className = NSStringFromClass(type(of: layer))
            if className.contains("Backdrop") || className.contains("Chameleon") {
                if let owner = owningView(for: layer), !isSystemManagedChrome(owner) {
                    found.append(layer)
                } else if owningView(for: layer) == nil {
                    found.append(layer)
                }
            }
            for sublayer in layer.sublayers ?? [] {
                found.append(contentsOf: collectAppOwnedBackdropLayers(in: sublayer))
            }
            return found
        }

        func collectAllVisualEffectViews(in view: NSView) -> [NSVisualEffectView] {
            var found: [NSVisualEffectView] = []
            if let vef = view as? NSVisualEffectView {
                found.append(vef)
            }
            for subview in view.subviews {
                found.append(contentsOf: collectAllVisualEffectViews(in: subview))
            }
            return found
        }

        func collectAppOwnedVisualEffectViews(in view: NSView) -> [NSVisualEffectView] {
            collectAllVisualEffectViews(in: view).filter { !isSystemManagedChrome($0) }
        }

        func hostAndLayout<V: View>(_ view: V, size: NSSize) -> (NSWindow, NSView) {
            let host = NSHostingView(rootView: view)
            let window = NSWindow(
                contentRect: NSRect(origin: .zero, size: size),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.contentView = host
            host.wantsLayer = true
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
            return (window, host)
        }

        // Sanity checks: confirm detector catches both an app-owned NSVisualEffectView (macOS 14+)
        // and SwiftUI within-window Material backdrop layers (macOS 26+ Liquid Glass layer pipeline).
        let vefProbeHost = hostAndLayout(
            ProbeVisualEffectView().frame(width: 240, height: 120),
            size: NSSize(width: 240, height: 120)
        )
        #expect(!collectAppOwnedVisualEffectViews(in: vefProbeHost.1).isEmpty)

        let materialProbeHost = hostAndLayout(
            RoundedRectangle(cornerRadius: 8)
                .fill(.clear)
                .background(.regularMaterial)
                .frame(width: 240, height: 120),
            size: NSSize(width: 240, height: 120)
        )
        if #available(macOS 26, *) {
            #expect(!collectAppOwnedBackdropLayers(in: materialProbeHost.1.layer).isEmpty)
        }

        // Populate a realistic CleanerRootView across sidebar, HUDs, dry-run ribbon, banner, results, and inspector
        InstrumentSerifFontRegistrar.registerBundledFonts()
        let focusedItem = ScannedItem(
            url: URL(fileURLWithPath: "/Users/alice/Downloads/archive.zip"),
            name: "archive.zip",
            logicalSize: 52_000_000,
            allocatedSize: 52_000_000,
            isDirectory: false,
            modifiedDate: Date(),
            category: .largeFiles,
            risk: RiskAssessment(level: .low, reason: "Archive in Downloads"),
            isRecommendedKeep: false
        )
        let outcome = ScanOutcome(
            itemsByCategory: [.largeFiles: [focusedItem]],
            progress: ScanProgress(phase: .completed, scannedFiles: 120, bytesEvaluated: 52_000_000)
        )
        let store = CleanerWorkspaceStore(
            scanner: FakeScanningService(outcome: outcome),
            deleter: FakeDeletionService(),
            historyStore: FakeHistoryService(),
            previewService: PreviewService()
        )
        store.itemsByCategory = [.largeFiles: [focusedItem]]
        store.selectedSidebarDestination = .category(.largeFiles)
        store.volumeStorage = VolumeStorageSnapshot(
            volumeName: "Macintosh HD",
            totalBytes: 500_000_000_000,
            availableBytes: 50_000_000_000
        )
        store.isDryRunEnabled = true
        store.statusBannerMessage = "Test banner"
        store.isInspectorVisible = true
        store.clickRow(focusedItem, modifiers: [])

        let (rootWindow, rootHost) = hostAndLayout(
            CleanerRootView(store: store),
            size: NSSize(width: 1240, height: 780)
        )
        #expect(rootWindow.isOpaque == true)
        #expect(collectAppOwnedBackdropLayers(in: rootHost.layer).isEmpty)
        #expect(collectAppOwnedVisualEffectViews(in: rootHost).isEmpty)
        for vef in collectAllVisualEffectViews(in: rootHost) {
            if #available(macOS 26, *) {
                #expect(vef.blendingMode == .withinWindow)
            }
            #expect(isSystemManagedChrome(vef))
        }

        // Exercise standalone views, alternate destinations, Welcome onboarding, and all confirmation/report sheets
        let (_, resultsHost) = hostAndLayout(
            ResultsListView(store: store, category: .largeFiles),
            size: NSSize(width: 720, height: 520)
        )
        #expect(collectAppOwnedBackdropLayers(in: resultsHost.layer).isEmpty)
        #expect(collectAppOwnedVisualEffectViews(in: resultsHost).isEmpty)

        let (_, previewHost) = hostAndLayout(
            PreviewPaneView(
                item: focusedItem,
                payload: nil,
                isLoading: false,
                isChecked: true,
                onToggleCheck: {},
                onTrashFocused: {},
                onPermanentDeleteFocused: {}
            ),
            size: NSSize(width: 360, height: 640)
        )
        #expect(collectAppOwnedBackdropLayers(in: previewHost.layer).isEmpty)
        #expect(collectAppOwnedVisualEffectViews(in: previewHost).isEmpty)

        store.selectedSidebarDestination = .history
        let (_, historyHost) = hostAndLayout(HistoryView(store: store), size: NSSize(width: 720, height: 520))
        #expect(collectAppOwnedBackdropLayers(in: historyHost.layer).isEmpty)
        #expect(collectAppOwnedVisualEffectViews(in: historyHost).isEmpty)

        store.selectedSidebarDestination = .settings
        let (_, settingsHost) = hostAndLayout(ScanSettingsView(store: store), size: NSSize(width: 720, height: 520))
        #expect(collectAppOwnedBackdropLayers(in: settingsHost.layer).isEmpty)
        #expect(collectAppOwnedVisualEffectViews(in: settingsHost).isEmpty)

        let welcomeSuite = "CleanerUITests.OpaqueWelcome.\(UUID().uuidString)"
        let welcomeDefaults = UserDefaults(suiteName: welcomeSuite)!
        defer { welcomeDefaults.removePersistentDomain(forName: welcomeSuite) }
        let welcomeModel = WelcomeOnboardingModel(
            isFirstLaunch: true,
            userDefaults: welcomeDefaults,
            permissionChecker: MutablePermissionChecker(initialStatus: .notGranted),
            notificationCenter: NotificationCenter()
        )
        let (_, welcomeHost) = hostAndLayout(
            WelcomeOnboardingView(model: welcomeModel, reduceMotionOverride: true),
            size: WelcomeOnboardingPolicy.windowSize
        )
        #expect(collectAppOwnedBackdropLayers(in: welcomeHost.layer).isEmpty)
        #expect(collectAppOwnedVisualEffectViews(in: welcomeHost).isEmpty)

        let (_, trashSheetHost) = hostAndLayout(
            MoveToTrashConfirmationSheet(
                items: [focusedItem],
                totalBytes: focusedItem.logicalSize,
                isDryRun: false,
                onConfirm: {},
                onCancel: {}
            ),
            size: NSSize(width: 520, height: 420)
        )
        #expect(collectAppOwnedBackdropLayers(in: trashSheetHost.layer).isEmpty)
        #expect(collectAppOwnedVisualEffectViews(in: trashSheetHost).isEmpty)

        let (_, permanentSheetHost) = hostAndLayout(
            PermanentDeleteConfirmationSheet(
                items: [focusedItem],
                totalBytes: focusedItem.logicalSize,
                isDryRun: false,
                onConfirm: {},
                onCancel: {}
            ),
            size: NSSize(width: 540, height: 420)
        )
        #expect(collectAppOwnedBackdropLayers(in: permanentSheetHost.layer).isEmpty)
        #expect(collectAppOwnedVisualEffectViews(in: permanentSheetHost).isEmpty)

        let report = DeletionExecutionReport(
            isDryRun: false,
            mode: .moveToTrash,
            succeededItems: [focusedItem],
            reclaimedBytes: focusedItem.logicalSize
        )
        let (_, reportSheetHost) = hostAndLayout(
            ExecutionReportSheet(report: report, onDismiss: {}),
            size: NSSize(width: 520, height: 320)
        )
        #expect(collectAppOwnedBackdropLayers(in: reportSheetHost.layer).isEmpty)
        #expect(collectAppOwnedVisualEffectViews(in: reportSheetHost).isEmpty)
    }

    @Test("Inspector action deck fits within minimum 340pt column width without clipping Permanently Delete")
    @MainActor
    func inspectorFooterFitsWithinMinimumColumnWidth() {
        InstrumentSerifFontRegistrar.registerBundledFonts()
        let item = ScannedItem(
            url: URL(fileURLWithPath: "/Users/alice/Downloads/icon.png"),
            name: "icon.png",
            logicalSize: 30_400_000,
            allocatedSize: 30_400_000,
            isDirectory: false,
            modifiedDate: Date(),
            category: .duplicates,
            risk: RiskAssessment(level: .moderate, reason: "Exact SHA-256 content duplicate; verify references before removing."),
            isRecommendedKeep: false
        )
        let host = NSHostingView(
            rootView: PreviewPaneView(
                item: item,
                payload: nil,
                isLoading: false,
                isChecked: true,
                onToggleCheck: {},
                onTrashFocused: {},
                onPermanentDeleteFocused: {}
            )
            .frame(width: 340, height: 740)
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 740),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        host.layoutSubtreeIfNeeded()

        #expect(host.fittingSize.width <= 340)
    }

    @Test("Toolbar inspector toggle aligns right of the inspector divider without straddling it and stays accessible when collapsed")
    @MainActor
    func inspectorToolbarButtonAlignsCleanlyWithSplitDivider() {
        InstrumentSerifFontRegistrar.registerBundledFonts()
        let store = CleanerWorkspaceStore(
            scanner: FakeScanningService(outcome: ScanOutcome()),
            deleter: FakeDeletionService(),
            historyStore: FakeHistoryService(),
            previewService: PreviewService()
        )
        store.isInspectorVisible = true

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1240, height: 780),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: CleanerRootView(store: store))
        window.setContentSize(NSSize(width: 1240, height: 780))
        window.orderFront(nil)
        window.contentView?.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        window.contentView?.layoutSubtreeIfNeeded()
        defer { window.close() }

        let expectedRightEdge = window.frame.width - 10
        // Locate inspector column divider X from the outer NSSplitView hosting the inspector
        func findInspectorDividerX(in view: NSView) -> CGFloat? {
            if let split = view as? NSSplitView {
                for subview in split.subviews {
                    let frame = subview.convert(subview.bounds, to: nil)
                    if frame.width >= 340 && frame.width <= 460 && frame.maxX >= expectedRightEdge {
                        return frame.minX
                    }
                }
            }
            for sub in view.subviews {
                if let found = findInspectorDividerX(in: sub) {
                    return found
                }
            }
            return nil
        }

        guard let themeFrame = window.contentView?.superview,
              let dividerX = findInspectorDividerX(in: themeFrame) else {
            Issue.record("Expected inspector split view divider to be present")
            return
        }

        let items = window.toolbar?.items ?? []
        #expect(items.contains { $0.itemIdentifier.rawValue.contains("splitViewSeparator") && $0 is NSTrackingSeparatorToolbarItem })
        #expect(items.contains { $0.itemIdentifier.rawValue == "com.apple.SwiftUI.splitViewSeparator-0i" })

        let inspectorItem = items.first { $0.label == "Preview Inspector" }
        #expect(inspectorItem != nil)

        if let view = inspectorItem?.view {
            let itemFrame = view.convert(view.bounds, to: nil)
            #expect(itemFrame.minX > dividerX)
        }

        // Verify no visible toolbar control straddles the inspector split divider
        for item in items {
            guard let view = item.view else { continue }
            let f = view.convert(view.bounds, to: nil)
            if f.width > 0 {
                let straddles = f.minX < dividerX && f.maxX > dividerX
                #expect(!straddles, "Toolbar item '\(item.label)' frame \(f) straddles inspector divider at x=\(dividerX)")
            }
        }

        // Collapsing the inspector must still keep Preview Inspector accessible in the toolbar
        store.isInspectorVisible = false
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        let closedItems = window.toolbar?.items ?? []
        #expect(closedItems.contains { $0.label == "Preview Inspector" })
    }

    @Test("Welcome window uses fixed 680x440 non-resizable NSWindow and UserDefaults first-launch gating")
    @MainActor
    func welcomeWindowUsesNonResizableNSWindowAndUserDefaultsGating() {
        let suiteName = "CleanerUITests.Welcome.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let controller = WelcomeWindowController(
            userDefaults: defaults,
            permissionChecker: MutablePermissionChecker(initialStatus: .notGranted)
        )

        #expect(WelcomeOnboardingPolicy.shouldShowOnLaunch(userDefaults: defaults) == true)
        controller.showIfNeededOnLaunch()

        let window = controller.attachedWindow
        #expect(window != nil)
        #expect(window?.isSheet == false)
        #expect(window?.styleMask.contains(.resizable) == false)
        #expect(window?.contentMinSize == NSSize(width: 680, height: 440))
        #expect(window?.contentMaxSize == NSSize(width: 680, height: 440))
        #expect(controller.isVisible == true)
        #expect(controller.model.currentStep == .welcome)

        controller.model.completeOnboarding()
        #expect(WelcomeOnboardingPolicy.shouldShowOnLaunch(userDefaults: defaults) == false)
        #expect(controller.isVisible == false)

        // Second launch should not auto-show once completed
        let secondLaunchController = WelcomeWindowController(
            userDefaults: defaults,
            permissionChecker: MutablePermissionChecker(initialStatus: .notGranted)
        )
        secondLaunchController.showIfNeededOnLaunch()
        #expect(secondLaunchController.attachedWindow == nil)

        // App menu "Show Welcome" remains reachable and resets to .welcome
        controller.model.selectStep(.permissions)
        controller.show(isFirstLaunch: false)
        #expect(controller.isVisible == true)
        #expect(controller.model.currentStep == .welcome)
        controller.attachedWindow?.close()
    }

    @Test("Welcome transition policy enforces directional slide when motion is allowed and plain crossfade under Reduce Motion")
    @MainActor
    func welcomeTransitionPolicyAndReduceMotionFallback() {
        let normal = WelcomeTransitionPolicy.resolve(reduceMotion: false)
        #expect(normal.reduceMotion == false)
        #expect(normal.usesDirectionalSlide == true)
        #expect(normal.slideOffset > 0)

        let reduced = WelcomeTransitionPolicy.resolve(reduceMotion: true)
        #expect(reduced.reduceMotion == true)
        #expect(reduced.usesDirectionalSlide == false)
        #expect(reduced.slideOffset == 0)

        for reduceMotion in [false, true] {
            let model = WelcomeOnboardingModel(
                permissionChecker: MutablePermissionChecker(initialStatus: .notGranted)
            )
            let host = NSHostingView(rootView: WelcomeOnboardingView(model: model, reduceMotionOverride: reduceMotion))
            host.frame = NSRect(origin: .zero, size: WelcomeOnboardingPolicy.windowSize)
            for step in WelcomeStep.allCases {
                model.selectStep(step)
                host.layoutSubtreeIfNeeded()
                #expect(host.fittingSize.width <= 680.5)
                #expect(host.fittingSize.height <= 440.5)
            }
        }
    }

    @Test("Welcome keyboard navigation steps cleanly through Permissions and never skips it silently")
    @MainActor
    func welcomeKeyboardNavigationAndNeverSkipsPermissionsStep() {
        let suiteName = "CleanerUITests.WelcomeKeys.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let controller = WelcomeWindowController(
            userDefaults: defaults,
            permissionChecker: MutablePermissionChecker(initialStatus: .notGranted)
        )
        controller.showIfNeededOnLaunch()
        guard let window = controller.attachedWindow else {
            Issue.record("Expected Welcome NSWindow to be created")
            return
        }

        func makeKeyEvent(keyCode: UInt16) -> NSEvent {
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                characters: "",
                charactersIgnoringModifiers: "",
                isARepeat: false,
                keyCode: keyCode
            )!
        }

        // Return advances Welcome -> How It Works -> Permissions (must not skip Permissions) -> Ready
        #expect(controller.model.currentStep == .welcome)
        #expect(controller.handleKeyEvent(makeKeyEvent(keyCode: 36)) == true)
        #expect(controller.model.currentStep == .howItWorks)
        #expect(controller.handleKeyEvent(makeKeyEvent(keyCode: 36)) == true)
        #expect(controller.model.currentStep == .permissions)

        // Up/Left arrow steps backward cleanly; Down/Right steps forward
        #expect(controller.handleKeyEvent(makeKeyEvent(keyCode: 126)) == true)
        #expect(controller.model.currentStep == .howItWorks)
        #expect(controller.handleKeyEvent(makeKeyEvent(keyCode: 124)) == true)
        #expect(controller.model.currentStep == .permissions)
        #expect(controller.handleKeyEvent(makeKeyEvent(keyCode: 123)) == true)
        #expect(controller.model.currentStep == .howItWorks)
        #expect(controller.handleKeyEvent(makeKeyEvent(keyCode: 125)) == true)
        #expect(controller.model.currentStep == .permissions)

        // Advance to Ready and complete with Return ("Get Started")
        #expect(controller.handleKeyEvent(makeKeyEvent(keyCode: 36)) == true)
        #expect(controller.model.currentStep == .ready)
        #expect(controller.handleKeyEvent(makeKeyEvent(keyCode: 36)) == true)
        #expect(controller.isVisible == false)
        #expect(WelcomeOnboardingPolicy.shouldShowOnLaunch(userDefaults: defaults) == false)
    }

    @Test("Permissions step opens Full Disk Access deep link and updates live status")
    @MainActor
    func welcomePermissionsStepDeepLinksAndReflectsLiveStatus() {
        let suiteName = "CleanerUITests.WelcomePerm.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let checker = MutablePermissionChecker(initialStatus: .notGranted)
        var openedURLs: [URL] = []

        let model = WelcomeOnboardingModel(
            isFirstLaunch: true,
            userDefaults: defaults,
            permissionChecker: checker,
            openURLHandler: { url in
                openedURLs.append(url)
                return true
            }
        )

        #expect(model.permissionStatus == .notGranted)
        model.selectStep(.permissions)

        enableSwiftUIAccessibilityTree()
        let hostingController = NSHostingController(rootView: WelcomeOnboardingView(model: model, reduceMotionOverride: true))
        let window = NSWindow(contentViewController: hostingController)
        window.setContentSize(WelcomeOnboardingPolicy.windowSize)
        window.makeKeyAndOrderFront(nil)
        window.contentView?.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        window.contentView?.layoutSubtreeIfNeeded()
        defer { window.close() }

        let fittedSize = hostingController.sizeThatFits(in: WelcomeOnboardingPolicy.windowSize)
        #expect(fittedSize.width <= 680.5)
        #expect(fittedSize.height <= 440.5)
        #expect(containsText("Quit & Reopen", in: window.contentView))
        #expect(containsText("Later", in: window.contentView))

        #expect(model.openFullDiskAccessSettings() == true)
        #expect(openedURLs == [SystemFullDiskAccessChecker.fullDiskAccessSettingsURL])

        checker.currentStatus = .granted
        #expect(model.refreshPermissionStatus() == .granted)
        #expect(model.permissionStatus == .granted)
    }

    @Test("Escape before granting Full Disk Access exits safely into documented limited scan mode")
    @MainActor
    func welcomeEscapeDismissalPreservesSafeDegradedMode() async {
        let suiteName = "CleanerUITests.WelcomeEscape.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let checker = MutablePermissionChecker(initialStatus: .notGranted)
        let store = CleanerWorkspaceStore(
            scanner: FakeScanningService(outcome: ScanOutcome(progress: ScanProgress(phase: .completed, skippedProtectedDirectories: 2))),
            deleter: FakeDeletionService(),
            historyStore: FakeHistoryService(),
            permissionChecker: checker
        )

        let controller = WelcomeWindowController(
            userDefaults: defaults,
            permissionChecker: checker,
            onDismissedWithoutCompletion: { _ in
                store.handleWelcomeDismissed(completed: false)
            }
        )
        controller.showIfNeededOnLaunch()
        guard let window = controller.attachedWindow else {
            Issue.record("Expected Welcome NSWindow to be created")
            return
        }

        let escapeEvent = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: 53
        )!

        #expect(controller.handleKeyEvent(escapeEvent) == true)
        #expect(controller.isVisible == false)
        #expect(store.permissionStatus == .notGranted)
        #expect(store.statusBannerMessage?.contains("Limited scan mode") == true)

        // App continues functioning cleanly in read-only scan mode
        await store.startScan()
        #expect(store.progress.phase == .completed)
        #expect(store.progress.skippedProtectedDirectories == 2)

        // Once granted and refreshed, degraded banner clears
        checker.currentStatus = .granted
        store.statusBannerMessage = "Limited scan mode: Full Disk Access is not granted"
        #expect(store.refreshPermissionStatus() == .granted)
        #expect(store.statusBannerMessage == nil)
    }

    @Test("App activation refreshes workspace FDA status and collapses limited-scan banner in hosted root view")
    @MainActor
    func applicationActivationRefreshesStatusAndClearsLimitedScanBannerInUI() {
        InstrumentSerifFontRegistrar.registerBundledFonts()
        let center = NotificationCenter()
        let checker = CountingPermissionChecker(initialStatus: .notGranted)
        let store = CleanerWorkspaceStore(
            scanner: FakeScanningService(outcome: ScanOutcome()),
            deleter: FakeDeletionService(),
            historyStore: FakeHistoryService(),
            previewService: PreviewService(),
            permissionChecker: checker,
            notificationCenter: center
        )
        store.selectedSidebarDestination = .category(.largeFiles)
        store.handleWelcomeDismissed(completed: false)
        #expect(store.permissionStatus == .notGranted)
        #expect(store.statusBannerMessage?.hasPrefix("Limited scan mode:") == true)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1240, height: 780),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: CleanerRootView(store: store))
        window.setContentSize(NSSize(width: 1240, height: 780))
        window.orderFront(nil)
        window.contentView?.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        window.contentView?.layoutSubtreeIfNeeded()
        defer { window.close() }

        guard let sortPopUpBefore = findPopUpButton(in: window.contentView) else {
            Issue.record("Expected ResultsListView sort NSPopUpButton in hosted CleanerRootView")
            return
        }
        let frameWithBanner = sortPopUpBefore.convert(sortPopUpBefore.bounds, to: nil)

        // Grant FDA and simulate switching back from System Settings
        checker.currentStatus = .granted
        let baselineChecks = checker.checkCount
        center.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        window.contentView?.layoutSubtreeIfNeeded()

        #expect(checker.checkCount - baselineChecks == 1)
        #expect(store.permissionStatus == .granted)
        #expect(store.statusBannerMessage == nil)

        guard let sortPopUpAfter = findPopUpButton(in: window.contentView) else {
            Issue.record("Expected ResultsListView sort NSPopUpButton after banner removal")
            return
        }
        let frameWithoutBanner = sortPopUpAfter.convert(sortPopUpAfter.bounds, to: nil)
        // AppKit window Y increases upward, so collapsing the banner above ResultsListView shifts actionBar upward.
        #expect(frameWithoutBanner.maxY - frameWithBanner.maxY >= 20)

        // Post-scan limited-scan banner also clears on activation without touching unrelated banners
        checker.currentStatus = .notGranted
        store.refreshPermissionStatus()
        store.statusBannerMessage = "Limited scan mode: Skipped 2 protected folders without Full Disk Access."
        checker.currentStatus = .granted
        center.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        #expect(store.statusBannerMessage == nil)

        store.statusBannerMessage = "Restored archive.zip to original location."
        center.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        #expect(store.statusBannerMessage == "Restored archive.zip to original location.")
    }

    @Test("Paired Welcome and main window perform only one FDA probe per activation while keeping both synced")
    @MainActor
    func pairedWelcomeAndMainWindowAvoidDuplicateActivationProbes() {
        let suiteName = "CleanerUITests.PairedActivation.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let center = NotificationCenter()
        let checker = CountingPermissionChecker(initialStatus: .notGranted)
        let store = CleanerWorkspaceStore(
            scanner: FakeScanningService(outcome: ScanOutcome()),
            deleter: FakeDeletionService(),
            historyStore: FakeHistoryService(),
            previewService: PreviewService(),
            permissionChecker: checker,
            notificationCenter: center
        )
        let controller = WelcomeWindowController(
            userDefaults: defaults,
            permissionChecker: checker,
            initialPermissionStatus: store.permissionStatus,
            observesApplicationActivation: false,
            notificationCenter: center,
            onDismissedWithoutCompletion: { [weak store] status in
                store?.handleWelcomeDismissed(completed: false, permissionStatus: status)
            },
            onCompleted: { [weak store] status in
                store?.handleWelcomeDismissed(completed: true, permissionStatus: status)
            },
            onPermissionStatusChanged: { [weak store] status in
                store?.applyPermissionStatus(status)
            }
        )
        store.onPermissionStatusDidChange = { [weak controller] status in
            controller?.model.syncPermissionStatus(status)
        }

        // Simulate degraded banner already present when user reopens Show Welcome
        store.handleWelcomeDismissed(completed: false)
        #expect(store.statusBannerMessage?.hasPrefix("Limited scan mode:") == true)

        controller.show(isFirstLaunch: false)
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        #expect(controller.isVisible == true)
        defer { controller.attachedWindow?.close() }

        // Grant FDA and return to app while BOTH Welcome and main store exist: must probe ONCE
        checker.currentStatus = .granted
        let baselineWithWelcomeOpen = checker.checkCount
        center.post(name: NSApplication.didBecomeActiveNotification, object: nil)

        #expect(checker.checkCount - baselineWithWelcomeOpen == 1)
        #expect(store.permissionStatus == .granted)
        #expect(controller.model.permissionStatus == .granted)
        #expect(store.statusBannerMessage == nil)

        // Closing Welcome still leaves main store active with a single probe per activation
        controller.attachedWindow?.close()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        #expect(controller.isVisible == false)

        checker.currentStatus = .notGranted
        let baselineAfterClose = checker.checkCount
        center.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        #expect(checker.checkCount == baselineAfterClose + 1)
        #expect(store.permissionStatus == .notGranted)

        // Manual "Check Status" in Welcome also syncs back to workspace store & clears banner with 1 probe
        store.handleWelcomeDismissed(completed: false)
        #expect(store.statusBannerMessage?.hasPrefix("Limited scan mode:") == true)
        controller.show(isFirstLaunch: false)
        checker.currentStatus = .granted
        let manualBaseline = checker.checkCount
        #expect(controller.model.refreshPermissionStatus() == .granted)
        #expect(checker.checkCount - manualBaseline == 1)
        #expect(store.permissionStatus == .granted)
        #expect(store.statusBannerMessage == nil)
    }

    @Test("Default NotificationCenter.default wiring refreshes workspace store on app activation")
    @MainActor
    func defaultNotificationCenterRefreshesWorkspaceStore() {
        let checker = CountingPermissionChecker(initialStatus: .notGranted)
        let store = CleanerWorkspaceStore(
            scanner: FakeScanningService(outcome: ScanOutcome()),
            deleter: FakeDeletionService(),
            historyStore: FakeHistoryService(),
            previewService: PreviewService(),
            permissionChecker: checker
        )
        store.statusBannerMessage = "Limited scan mode: Skipped 1 protected folder without Full Disk Access."
        #expect(store.permissionStatus == .notGranted)

        checker.currentStatus = .granted
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        #expect(store.permissionStatus == .granted)
        #expect(store.statusBannerMessage == nil)
    }

    @Test("Closed Welcome window does not re-probe Full Disk Access on app activation even with default observation")
    @MainActor
    func closedWelcomeWindowDoesNotProbeOnActivation() {
        let suiteName = "CleanerUITests.ClosedWelcomeActivation.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let center = NotificationCenter()
        let checker = CountingPermissionChecker(initialStatus: .notGranted)
        let controller = WelcomeWindowController(
            userDefaults: defaults,
            permissionChecker: checker,
            notificationCenter: center
        )
        controller.show(isFirstLaunch: false)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        #expect(controller.isVisible == true)

        // While visible, standalone Welcome refreshes on app activation
        checker.currentStatus = .granted
        let visibleBaseline = checker.checkCount
        center.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        #expect(checker.checkCount - visibleBaseline == 1)
        #expect(controller.model.permissionStatus == .granted)

        // Once closed, retained NSHostingView/window must not probe on activation
        controller.attachedWindow?.close()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        #expect(controller.isVisible == false)

        let closedBaseline = checker.checkCount
        center.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        #expect(checker.checkCount == closedBaseline)
    }

    @Test("Workspace activation observer releases cleanly on store deinit")
    @MainActor
    func workspaceActivationObserverUnregistersOnDeinit() {
        let center = NotificationCenter()
        let checker = CountingPermissionChecker(initialStatus: .notGranted)
        weak var weakStore: CleanerWorkspaceStore?

        do {
            let store = CleanerWorkspaceStore(
                scanner: FakeScanningService(outcome: ScanOutcome()),
                deleter: FakeDeletionService(),
                historyStore: FakeHistoryService(),
                previewService: PreviewService(),
                permissionChecker: checker,
                notificationCenter: center
            )
            weakStore = store
            checker.currentStatus = .granted
            center.post(name: NSApplication.didBecomeActiveNotification, object: nil)
            #expect(store.permissionStatus == .granted)
        }

        #expect(weakStore == nil)
        let countAfterDeinit = checker.checkCount
        center.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        #expect(checker.checkCount == countAfterDeinit)
    }

    @Test("Limited-scan banner offers direct Open Full Disk Access Settings action only for FDA warnings")
    @MainActor
    func limitedScanBannerExposesSettingsActionOnlyForPermissionWarnings() {
        enableSwiftUIAccessibilityTree()
        InstrumentSerifFontRegistrar.registerBundledFonts()
        let center = NotificationCenter()
        let checker = CountingPermissionChecker(initialStatus: .notGranted)
        var openedURLs: [URL] = []
        let store = CleanerWorkspaceStore(
            scanner: FakeScanningService(outcome: ScanOutcome()),
            deleter: FakeDeletionService(),
            historyStore: FakeHistoryService(),
            previewService: PreviewService(),
            permissionChecker: checker,
            notificationCenter: center,
            openURLHandler: { url in
                openedURLs.append(url)
                return true
            }
        )
        #expect(store.isLimitedScanBannerVisible == false)
        store.selectedSidebarDestination = .category(.largeFiles)
        store.handleWelcomeDismissed(completed: false)
        #expect(store.isLimitedScanBannerVisible == true)
        #expect(store.openFullDiskAccessSettings() == true)
        #expect(openedURLs == [SystemFullDiskAccessChecker.fullDiskAccessSettingsURL])
        openedURLs.removeAll()

        store.statusBannerMessage = "Limited scan mode: Skipped 2 protected folders without Full Disk Access."
        #expect(store.isLimitedScanBannerVisible == true)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: CleanerRootView(store: store))
        window.setContentSize(NSSize(width: 1100, height: 720))
        window.makeKeyAndOrderFront(nil)
        window.contentView?.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.25))
        window.contentView?.layoutSubtreeIfNeeded()
        defer { window.close() }

        guard let settingsButton = findButton(
            in: window,
            matchingIdentifier: "bannerOpenFullDiskAccessButton",
            fallbackText: "Open Full Disk Access Settings"
        ) else {
            Issue.record("Expected Open Full Disk Access Settings button inside limited-scan banner. Tree:\n\(dumpAccessibilityTree(in: window.contentView))")
            return
        }
        #expect(settingsButton.press())
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        #expect(openedURLs == [SystemFullDiskAccessChecker.fullDiskAccessSettingsURL])

        // Non-permission informational banners (e.g. restore confirmation) must NOT show the FDA settings shortcut
        store.statusBannerMessage = "Restored archive.zip to original location."
        #expect(store.isLimitedScanBannerVisible == false)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        window.contentView?.layoutSubtreeIfNeeded()
        #expect(findButton(
            in: window,
            matchingIdentifier: "bannerOpenFullDiskAccessButton",
            fallbackText: "Open Full Disk Access Settings"
        ) == nil)

        // Switching back to a limited-scan banner shows the action again; granting FDA on activation clears both
        store.statusBannerMessage = "Limited scan mode: Skipped 2 protected folders without Full Disk Access."
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        window.contentView?.layoutSubtreeIfNeeded()
        #expect(findButton(
            in: window,
            matchingIdentifier: "bannerOpenFullDiskAccessButton",
            fallbackText: "Open Full Disk Access Settings"
        ) != nil)

        checker.currentStatus = .granted
        center.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        window.contentView?.layoutSubtreeIfNeeded()
        #expect(store.isLimitedScanBannerVisible == false)
        #expect(findButton(
            in: window,
            matchingIdentifier: "bannerOpenFullDiskAccessButton",
            fallbackText: "Open Full Disk Access Settings"
        ) == nil)
    }

    @Test("ScanSettingsView surfaces live Full Disk Access status, Check Status refresh, and Settings action without clipping")
    @MainActor
    func scanSettingsViewExposesFullDiskAccessControlsAndFitsSettingsScene() {
        enableSwiftUIAccessibilityTree()
        InstrumentSerifFontRegistrar.registerBundledFonts()
        let checker = CountingPermissionChecker(initialStatus: .notGranted)
        var openedURLs: [URL] = []
        let store = CleanerWorkspaceStore(
            scanner: FakeScanningService(outcome: ScanOutcome()),
            deleter: FakeDeletionService(),
            historyStore: FakeHistoryService(),
            previewService: PreviewService(),
            permissionChecker: checker,
            notificationCenter: NotificationCenter(),
            openURLHandler: { url in
                openedURLs.append(url)
                return true
            }
        )

        var syncedStatuses: [FullDiskAccessStatus] = []
        store.handleWelcomeDismissed(completed: false)
        #expect(store.isLimitedScanBannerVisible == true)
        store.onPermissionStatusDidChange = { status in
            syncedStatuses.append(status)
        }

        let hostingController = NSHostingController(
            rootView: ScanSettingsView(store: store, showsHeader: false)
                .frame(minWidth: 580, minHeight: 520)
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 580, height: 520),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentViewController = hostingController
        window.setContentSize(NSSize(width: 580, height: 520))
        window.makeKeyAndOrderFront(nil)
        window.contentView?.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.25))
        window.contentView?.layoutSubtreeIfNeeded()
        defer { window.close() }

        let fittedAt580 = hostingController.sizeThatFits(in: CGSize(width: 580, height: 520))
        #expect(fittedAt580.width <= 580.5)
        if let scrollView = findScrollView(in: window.contentView),
           let documentView = scrollView.documentView {
            #expect(documentView.frame.width <= 580.5)
        }
        #expect(containsText("Full Disk Access Not Granted", in: window.contentView))

        guard let openSettingsButton = findButton(
            in: window,
            matchingIdentifier: "settingsOpenFullDiskAccessButton",
            fallbackText: "Open Full Disk Access Settings…"
        ),
        let checkStatusButton = findButton(
            in: window,
            matchingIdentifier: "settingsCheckPermissionButton",
            fallbackText: "Check Status"
        ) else {
            Issue.record("Expected Full Disk Access buttons in ScanSettingsView. Tree:\n\(dumpAccessibilityTree(in: window.contentView))")
            return
        }

        let openFrame = openSettingsButton.frameInWindow
        let checkFrame = checkStatusButton.frameInWindow
        #expect(openFrame.width > 40 && openFrame.height > 12)
        #expect(checkFrame.width > 40 && checkFrame.height > 12)
        #expect(openFrame.minX >= 0 && openFrame.maxX <= 580.5)
        #expect(checkFrame.minX >= 0 && checkFrame.maxX <= 580.5)
        #expect(!openFrame.intersects(checkFrame))

        #expect(openSettingsButton.press())
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        #expect(openedURLs == [SystemFullDiskAccessChecker.fullDiskAccessSettingsURL])

        checker.currentStatus = .granted
        let baselineChecks = checker.checkCount
        #expect(checkStatusButton.press())
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        window.contentView?.layoutSubtreeIfNeeded()
        #expect(checker.checkCount == baselineChecks + 1)
        #expect(store.permissionStatus == .granted)
        #expect(store.statusBannerMessage == nil)
        #expect(store.isLimitedScanBannerVisible == false)
        #expect(syncedStatuses.last == .granted)
        #expect(containsText("Full Disk Access Granted", in: window.contentView))
    }

    @MainActor
    private func enableSwiftUIAccessibilityTree() {
        let app = NSApplication.shared
        let sel = NSSelectorFromString("accessibilitySetValue:forAttribute:")
        if app.responds(to: sel) {
            _ = (app as AnyObject).perform(sel, with: kCFBooleanTrue, with: "AXEnhancedUserInterface")
        }
    }

    @MainActor
    private func findPopUpButton(in rootView: NSView?) -> NSPopUpButton? {
        guard let rootView else { return nil }
        if let popUp = rootView as? NSPopUpButton {
            return popUp
        }
        for subview in rootView.subviews {
            if let found = findPopUpButton(in: subview) {
                return found
            }
        }
        return nil
    }

    @MainActor
    private func findScrollView(in rootView: NSView?) -> NSScrollView? {
        guard let rootView else { return nil }
        if let scrollView = rootView as? NSScrollView {
            return scrollView
        }
        for subview in rootView.subviews {
            if let found = findScrollView(in: subview) {
                return found
            }
        }
        return nil
    }

    private struct ButtonHandle {
        let frameInWindow: NSRect
        let press: @MainActor () -> Bool
    }

    @MainActor
    private func accessibilityStringValue(of node: AnyObject) -> String? {
        let sel = NSSelectorFromString("accessibilityValue")
        guard (node as? NSObject)?.responds(to: sel) == true else { return nil }
        return node.perform(sel)?.takeUnretainedValue() as? String
    }

    @MainActor
    private func findButton(
        in window: NSWindow,
        matchingIdentifier identifier: String,
        fallbackText: String
    ) -> ButtonHandle? {
        guard let rootView = window.contentView else { return nil }

        var visitedObjects = Set<ObjectIdentifier>()

        func inspectAccessibilityNode(_ node: AnyObject) -> ButtonHandle? {
            let oid = ObjectIdentifier(node)
            guard visitedObjects.insert(oid).inserted else { return nil }

            if let button = node as? NSButton, !(button is NSPopUpButton) {
                let idMatch = button.accessibilityIdentifier() == identifier || button.identifier?.rawValue == identifier
                let textMatch = button.title == fallbackText
                    || button.accessibilityTitle() == fallbackText
                    || button.accessibilityLabel() == fallbackText
                if idMatch || textMatch {
                    return ButtonHandle(
                        frameInWindow: button.convert(button.bounds, to: nil),
                        press: {
                            button.performClick(nil)
                            return true
                        }
                    )
                }
            }

            let role = node.accessibilityRole?()
            let axIdentifier = node.accessibilityIdentifier?()
            let axTitle = node.accessibilityTitle?()
            let axLabel = node.accessibilityLabel?()
            let idMatch = axIdentifier == identifier
            let textMatch = axTitle == fallbackText
                || axLabel == fallbackText
                || (axTitle?.contains(fallbackText) == true)
                || (axLabel?.contains(fallbackText) == true)
            if role == .button && (idMatch || textMatch) {
                let screenFrame = node.accessibilityFrame?() ?? .zero
                let windowFrame = window.convertFromScreen(screenFrame)
                return ButtonHandle(
                    frameInWindow: windowFrame,
                    press: { node.accessibilityPerformPress?() ?? false }
                )
            }

            if let children = node.accessibilityChildren?() {
                for child in children {
                    if let found = inspectAccessibilityNode(child as AnyObject) {
                        return found
                    }
                }
            }

            if let view = node as? NSView {
                for subview in view.subviews {
                    if let found = inspectAccessibilityNode(subview) {
                        return found
                    }
                }
            }
            return nil
        }

        return inspectAccessibilityNode(rootView)
    }

    @MainActor
    private func containsText(_ needle: String, in rootView: NSView?) -> Bool {
        guard let rootView else { return false }
        var visited = Set<ObjectIdentifier>()

        func inspect(_ node: AnyObject) -> Bool {
            let oid = ObjectIdentifier(node)
            guard visited.insert(oid).inserted else { return false }

            if let field = node as? NSTextField, field.stringValue.contains(needle) {
                return true
            }
            if let val = accessibilityStringValue(of: node), val.contains(needle) {
                return true
            }
            if let title = node.accessibilityTitle?(), title.contains(needle) {
                return true
            }
            if let label = node.accessibilityLabel?(), label.contains(needle) {
                return true
            }
            if let children = node.accessibilityChildren?() {
                for child in children where inspect(child as AnyObject) {
                    return true
                }
            }
            if let view = node as? NSView {
                for subview in view.subviews where inspect(subview) {
                    return true
                }
            }
            return false
        }

        return inspect(rootView)
    }

    @MainActor
    private func dumpAccessibilityTree(in rootView: NSView?) -> String {
        guard let rootView else { return "<nil>" }
        var lines: [String] = []
        var visited = Set<ObjectIdentifier>()

        func walk(_ node: AnyObject, depth: Int) {
            let oid = ObjectIdentifier(node)
            guard visited.insert(oid).inserted, lines.count < 160 else { return }
            let indent = String(repeating: "  ", count: depth)
            let cls = NSStringFromClass(type(of: node))
            var desc = "\(indent)\(cls)"
            if let role = node.accessibilityRole?() { desc += " role=\(role.rawValue)" }
            if let id = node.accessibilityIdentifier?(), !id.isEmpty { desc += " id=\(id)" }
            if let title = node.accessibilityTitle?(), !title.isEmpty { desc += " title='\(title)'" }
            if let label = node.accessibilityLabel?(), !label.isEmpty { desc += " label='\(label)'" }
            if let val = accessibilityStringValue(of: node), !val.isEmpty { desc += " val='\(val)'" }
            lines.append(desc)
            for child in node.accessibilityChildren?() ?? [] {
                walk(child as AnyObject, depth: depth + 1)
            }
            if let view = node as? NSView {
                for sub in view.subviews {
                    walk(sub, depth: depth + 1)
                }
            }
        }

        walk(rootView, depth: 0)
        return lines.joined(separator: "\n")
    }
}

private final class MutablePermissionChecker: FullDiskAccessChecking, @unchecked Sendable {
    var currentStatus: FullDiskAccessStatus

    init(initialStatus: FullDiskAccessStatus) {
        self.currentStatus = initialStatus
    }

    var settingsURL: URL {
        SystemFullDiskAccessChecker.fullDiskAccessSettingsURL
    }

    func checkStatus() -> FullDiskAccessStatus {
        currentStatus
    }
}

private final class CountingPermissionChecker: FullDiskAccessChecking, @unchecked Sendable {
    private let state: OSAllocatedUnfairLock<(status: FullDiskAccessStatus, count: Int)>

    init(initialStatus: FullDiskAccessStatus) {
        self.state = OSAllocatedUnfairLock(initialState: (initialStatus, 0))
    }

    var settingsURL: URL {
        SystemFullDiskAccessChecker.fullDiskAccessSettingsURL
    }

    var currentStatus: FullDiskAccessStatus {
        get { state.withLock { $0.status } }
        set { state.withLock { $0.status = newValue } }
    }

    var checkCount: Int {
        state.withLock { $0.count }
    }

    func checkStatus() -> FullDiskAccessStatus {
        state.withLock { box in
            box.count += 1
            return box.status
        }
    }
}

private actor FakeScanningService: ScanningServicing {
    let outcome: ScanOutcome

    init(outcome: ScanOutcome) {
        self.outcome = outcome
    }

    func makeProgressStream() -> AsyncStream<ScanBatch> {
        let (stream, cont) = AsyncStream.makeStream(of: ScanBatch.self)
        cont.finish()
        return stream
    }

    func runFullScan(configuration: ScanConfiguration) async -> ScanOutcome {
        outcome
    }

    func start(configuration: ScanConfiguration) async throws {}
    func pause() async -> ScanCheckpoint {
        ScanCheckpoint(
            configuration: ScanConfiguration(),
            pendingDirectories: [],
            candidateFiles: [],
            deadItems: [],
            visitedDirectoryPaths: [],
            scannedFiles: 0,
            bytesEvaluated: 0,
            startedAt: Date()
        )
    }
    func resume(from checkpoint: ScanCheckpoint) async -> ScanOutcome { outcome }
    func cancel() async -> ScanOutcome { outcome }
}

private actor FakeDeletionService: DeletionServicing {
    func execute(
        items: [ScannedItem],
        mode: DeletionMode,
        dryRun: Bool,
        excludedFolders: [String],
        allowAppBundles: Bool,
        verifySnapshotItems: Bool
    ) async throws -> DeletionExecutionReport {
        let entries = dryRun ? [] : items.map {
            TrashHistoryEntry(
                originalPath: $0.url.path,
                trashPath: "/Users/alice/.Trash/\($0.name)",
                bytes: $0.logicalSize,
                trashInode: 1001
            )
        }
        return DeletionExecutionReport(
            isDryRun: dryRun,
            mode: mode,
            succeededItems: items,
            trashHistoryEntries: entries,
            reclaimedBytes: items.reduce(0) { $0 &+ $1.logicalSize }
        )
    }

    func restore(entries: [TrashHistoryEntry]) async -> (restoredIDs: Set<UUID>, failures: [DeletionFailure]) {
        (Set(entries.map(\.id)), [])
    }
}

private actor FakeHistoryService: HistoryStoring {
    private var entries: [TrashHistoryEntry] = []

    func loadEntries() async -> [TrashHistoryEntry] { entries }
    func append(_ newEntries: [TrashHistoryEntry]) async { entries.insert(contentsOf: newEntries, at: 0) }
    func remove(ids: Set<UUID>) async { entries.removeAll { ids.contains($0.id) } }
}

private actor StrictDeletionService: DeletionServicing {
    func execute(
        items: [ScannedItem],
        mode: DeletionMode,
        dryRun: Bool,
        excludedFolders: [String],
        allowAppBundles: Bool,
        verifySnapshotItems: Bool
    ) async throws -> DeletionExecutionReport {
        if case .permanentDelete(let confirmed) = mode, !confirmed {
            throw DeletionPlanError.permanentConfirmationRequired
        }
        return DeletionExecutionReport(isDryRun: dryRun, mode: mode, succeededItems: items, reclaimedBytes: 0)
    }

    func restore(entries: [TrashHistoryEntry]) async -> (restoredIDs: Set<UUID>, failures: [DeletionFailure]) {
        ([], [])
    }
}

private actor ControllableFakeScanner: ScanningServicing {
    private var started = false
    private var gate: CheckedContinuation<ScanOutcome, Never>?

    func makeProgressStream() -> AsyncStream<ScanBatch> {
        let (stream, cont) = AsyncStream.makeStream(of: ScanBatch.self)
        cont.yield(ScanBatch(items: [], progress: ScanProgress(phase: .enumerating, currentPath: "/Users/alice/Downloads", scannedFiles: 12, bytesEvaluated: 4096)))
        return stream
    }

    func runFullScan(configuration: ScanConfiguration) async -> ScanOutcome {
        started = true
        return await withCheckedContinuation { continuation in
            gate = continuation
        }
    }

    func waitUntilStarted() async {
        while !started {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    func start(configuration: ScanConfiguration) async throws {}

    func pause() async -> ScanCheckpoint {
        gate?.resume(returning: ScanOutcome(progress: ScanProgress(phase: .paused)))
        gate = nil
        return ScanCheckpoint(
            configuration: ScanConfiguration(),
            pendingDirectories: [],
            candidateFiles: [],
            deadItems: [],
            visitedDirectoryPaths: [],
            scannedFiles: 12,
            bytesEvaluated: 4096,
            startedAt: Date()
        )
    }

    func resume(from checkpoint: ScanCheckpoint) async -> ScanOutcome {
        ScanOutcome(progress: ScanProgress(phase: .completed))
    }

    func cancel() async -> ScanOutcome {
        let out = ScanOutcome(progress: ScanProgress(phase: .cancelled), wasCancelled: true)
        gate?.resume(returning: out)
        gate = nil
        return out
    }
}

private actor SuspendablePreviewService: PreviewServicing {
    private var started = false
    private(set) var wasCancelled = false
    private var continuation: CheckedContinuation<Void, Never>?

    func loadPreview(for item: ScannedItem) async -> PreviewPayload {
        started = true
        await withTaskCancellationHandler {
            await withCheckedContinuation { cont in
                if Task.isCancelled {
                    wasCancelled = true
                    cont.resume()
                } else {
                    continuation = cont
                }
            }
        } onCancel: {
            Task { await markCancelledAndResume() }
        }
        let snapshot = FileMetadataSnapshot(
            url: item.url,
            utiIdentifier: "public.data",
            kindDescription: "Document",
            logicalSize: item.logicalSize,
            allocatedSize: item.allocatedSize,
            createdDate: nil,
            modifiedDate: nil,
            accessedDate: nil,
            posixPermissions: "rw-r--r--",
            linkCount: 1,
            extendedAttributes: [],
            thumbnail: nil
        )
        return PreviewPayload(content: .fallback, metadata: snapshot)
    }

    func waitUntilStarted() async {
        while !started {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    private func markCancelledAndResume() {
        wasCancelled = true
        continuation?.resume()
        continuation = nil
    }
}

private actor OverlappingGenerationsFakeScanner: ScanningServicing {
    private let staleItem: ScannedItem
    private let freshItem: ScannedItem
    private var runCount = 0
    private var firstGate: CheckedContinuation<ScanOutcome, Never>?

    init(staleItem: ScannedItem, freshItem: ScannedItem) {
        self.staleItem = staleItem
        self.freshItem = freshItem
    }

    func makeProgressStream() -> AsyncStream<ScanBatch> {
        let (stream, cont) = AsyncStream.makeStream(of: ScanBatch.self)
        cont.finish()
        return stream
    }

    func runFullScan(configuration: ScanConfiguration) async -> ScanOutcome {
        runCount += 1
        if runCount == 1 {
            return await withCheckedContinuation { cont in
                firstGate = cont
            }
        }
        return ScanOutcome(
            itemsByCategory: [.largeFiles: [freshItem]],
            progress: ScanProgress(phase: .completed, scannedFiles: 1, bytesEvaluated: freshItem.logicalSize)
        )
    }

    func waitUntilFirstScanSuspended() async {
        while firstGate == nil {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    func releaseFirstScan() {
        firstGate?.resume(returning: ScanOutcome(
            itemsByCategory: [.largeFiles: [staleItem]],
            progress: ScanProgress(phase: .cancelled, scannedFiles: 0, bytesEvaluated: 0),
            wasCancelled: true
        ))
        firstGate = nil
    }

    func start(configuration: ScanConfiguration) async throws {}

    func pause() async -> ScanCheckpoint {
        ScanCheckpoint(
            configuration: ScanConfiguration(),
            pendingDirectories: [],
            candidateFiles: [],
            deadItems: [],
            visitedDirectoryPaths: [],
            scannedFiles: 0,
            bytesEvaluated: 0,
            startedAt: Date()
        )
    }

    func resume(from checkpoint: ScanCheckpoint) async -> ScanOutcome {
        ScanOutcome(progress: ScanProgress(phase: .completed))
    }

    func cancel() async -> ScanOutcome {
        ScanOutcome(progress: ScanProgress(phase: .cancelled), wasCancelled: true)
    }
}
