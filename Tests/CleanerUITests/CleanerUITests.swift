import Testing
import Foundation
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

    @Test("Material surfaces switch away from translucent backdrop layers when Reduce Transparency is enabled")
    @MainActor
    func reduceTransparencyDisablesMaterialSurfaces() {
        func countBackdropLayers(in layer: CALayer?) -> Int {
            guard let layer else { return 0 }
            let className = NSStringFromClass(type(of: layer))
            let isBackdrop = className.contains("Backdrop")
            return (isBackdrop ? 1 : 0) + (layer.sublayers ?? []).reduce(0) { $0 + countBackdropLayers(in: $1) }
        }

        func renderAndCountBackdrops<V: View>(_ view: V) -> Int {
            let host = NSHostingView(rootView: view)
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 520, height: 320),
                styleMask: [.titled],
                backing: .buffered,
                defer: false
            )
            window.contentView = host
            host.wantsLayer = true
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
            return countBackdropLayers(in: host.layer)
        }

        let store = CleanerWorkspaceStore(
            scanner: FakeScanningService(outcome: ScanOutcome()),
            deleter: FakeDeletionService(),
            historyStore: FakeHistoryService(),
            previewService: PreviewService()
        )
        store.isDryRunEnabled = true
        store.statusBannerMessage = "Test banner"

        let sampleSurfaces = VStack {
            DryRunRibbon()
            BackgroundScanHUD(
                progress: store.progress,
                isScanning: false,
                isPaused: false,
                onPause: {},
                onResume: {},
                onCancel: {}
            )
        }

        let standardCount = renderAndCountBackdrops(
            sampleSurfaces.environment(\.cleanerReduceTransparencyOverride, false)
        )
        let reducedCount = renderAndCountBackdrops(
            sampleSurfaces.environment(\.cleanerReduceTransparencyOverride, true)
        )
        #expect(standardCount >= 2)
        #expect(reducedCount == 0)

        // Exercise remaining material surfaces under Reduce Transparency
        _ = renderAndCountBackdrops(
            PreviewPaneView(
                item: nil,
                payload: nil,
                isLoading: false,
                isChecked: false,
                onToggleCheck: {},
                onTrashFocused: {},
                onPermanentDeleteFocused: {}
            )
            .frame(width: 360, height: 320)
            .environment(\.cleanerReduceTransparencyOverride, true)
        )
        _ = CleanerRootView(store: store).environment(\.cleanerReduceTransparencyOverride, true)
        _ = ResultsListView(store: store, category: .duplicates).environment(\.cleanerReduceTransparencyOverride, true)
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
        allowAppBundles: Bool
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
        allowAppBundles: Bool
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
