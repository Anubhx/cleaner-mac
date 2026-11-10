import Foundation
import SwiftUI
import Observation
import CleanerCore
import CleanerPreview

public enum SidebarDestination: Hashable, Sendable {
    case category(ScanCategory)
    case history
    case settings
}

public enum ResultSortOrder: String, CaseIterable, Sendable {
    case sizeDescending = "Largest First"
    case dateOldest = "Oldest First"
    case nameAscending = "Name (A–Z)"
    case riskHighest = "Highest Risk"
}

@Observable
@MainActor
public final class CleanerWorkspaceStore {
    public var selectedSidebarDestination: SidebarDestination = .category(.duplicates)
    public var configuration: ScanConfiguration = ScanConfiguration()
    public var searchQuery: String = ""
    public var sortOrder: ResultSortOrder = .sizeDescending
    public var isDryRunEnabled: Bool = false
    public var isInspectorVisible: Bool = true

    public var progress: ScanProgress = ScanProgress()
    public var volumeStorage: VolumeStorageSnapshot?
    public var isScanning: Bool = false
    public var isPaused: Bool = false
    public var itemsByCategory: [ScanCategory: [ScannedItem]] = [:]
    public var duplicateGroups: [DuplicateGroup] = []
    public var historyEntries: [TrashHistoryEntry] = []

    public var selection: MultiSelectState = MultiSelectState()
    public var previewPayload: PreviewPayload?
    public var isLoadingPreview: Bool = false

    public var showingTrashConfirmation: Bool = false
    public var showingPermanentConfirmation: Bool = false
    public var pendingDeletionItems: [ScannedItem] = []
    public var lastExecutionReport: DeletionExecutionReport?
    public var statusBannerMessage: String?

    private let scanner: any ScanningServicing
    private let deleter: any DeletionServicing
    private let historyStore: any HistoryStoring
    private let previewService: PreviewService

    private var savedCheckpoint: ScanCheckpoint?
    private var scanRunnerTask: Task<Void, Never>?
    private var streamListenerTask: Task<Void, Never>?
    private var previewTask: Task<Void, Never>?

    public init(
        scanner: any ScanningServicing,
        deleter: any DeletionServicing,
        historyStore: any HistoryStoring,
        previewService: PreviewService = PreviewService()
    ) {
        self.scanner = scanner
        self.deleter = deleter
        self.historyStore = historyStore
        self.previewService = previewService
    }

    public func loadInitialHistory() async {
        historyEntries = await historyStore.loadEntries()
        await refreshVolumeStorage()
    }

    public func refreshVolumeStorage() async {
        let root = configuration.roots.first ?? FileManager.default.homeDirectoryForCurrentUser
        volumeStorage = await scanner.volumeStorageSnapshot(for: root)
    }

    public func items(for category: ScanCategory) -> [ScannedItem] {
        itemsByCategory[category] ?? []
    }

    public var activeCategory: ScanCategory? {
        if case .category(let cat) = selectedSidebarDestination { return cat }
        return nil
    }

    public var hasCompletedOrCancelledScan: Bool {
        progress.phase == .completed || progress.phase == .cancelled
    }

    public var primaryScanActionTitle: String {
        hasCompletedOrCancelledScan ? "Scan Again" : "Scan Mac"
    }

    public var primaryScanActionSymbol: String {
        hasCompletedOrCancelledScan ? "arrow.clockwise" : "magnifyingglass"
    }

    public var visibleItems: [ScannedItem] {
        guard let category = activeCategory else { return [] }
        let base = items(for: category)
        let filtered: [ScannedItem]
        if searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            filtered = base
        } else {
            let needle = searchQuery.lowercased()
            filtered = base.filter {
                $0.name.lowercased().contains(needle) || $0.url.path.lowercased().contains(needle)
            }
        }

        if category == .duplicates && sortOrder == .sizeDescending {
            return filtered
        }

        return filtered.sorted { lhs, rhs in
            switch sortOrder {
            case .sizeDescending:
                return lhs.reclaimableDiskBytes > rhs.reclaimableDiskBytes
            case .dateOldest:
                return (lhs.modifiedDate ?? .distantFuture) < (rhs.modifiedDate ?? .distantFuture)
            case .nameAscending:
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            case .riskHighest:
                return lhs.risk.level > rhs.risk.level
            }
        }
    }

    public var checkedItemsInAllCategories: [ScannedItem] {
        let all = ScanCategory.allCases.flatMap { items(for: $0) }
        var seenURLs = Set<URL>()
        return all.filter {
            selection.checkedIDs.contains($0.id) && seenURLs.insert($0.url).inserted
        }
    }

    public var checkedUniqueBytes: UInt64 {
        let all = ScanCategory.allCases.flatMap { items(for: $0) }
        return SelectionMetrics.uniqueSelectedBytes(items: all, selectedIDs: selection.checkedIDs)
    }

    public var pendingDeletionBytes: UInt64 {
        let ids = Set(pendingDeletionItems.map(\.id))
        return SelectionMetrics.uniqueSelectedBytes(items: pendingDeletionItems, selectedIDs: ids)
    }

    public func reclaimableBytes(for category: ScanCategory) -> UInt64 {
        let list = items(for: category).filter { !$0.isRecommendedKeep }
        var seen = Set<URL>()
        return list.reduce(0) { sum, item in
            guard seen.insert(item.url).inserted else { return sum }
            return sum &+ item.reclaimableDiskBytes
        }
    }

    public var filteredDuplicateGroups: [DuplicateGroup] {
        let trimmed = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let matched: [DuplicateGroup]
        if trimmed.isEmpty {
            matched = duplicateGroups
        } else {
            let needle = trimmed.lowercased()
            matched = duplicateGroups.filter { group in
                group.allItems.contains {
                    $0.name.lowercased().contains(needle) || $0.url.path.lowercased().contains(needle)
                }
            }
        }

        return matched.sorted { lhs, rhs in
            switch sortOrder {
            case .sizeDescending:
                return lhs.reclaimableBytes > rhs.reclaimableBytes
            case .dateOldest:
                let lDate = lhs.original.modifiedDate ?? .distantFuture
                let rDate = rhs.original.modifiedDate ?? .distantFuture
                return lDate < rDate
            case .nameAscending:
                return lhs.original.name.localizedStandardCompare(rhs.original.name) == .orderedAscending
            case .riskHighest:
                return lhs.reclaimableBytes > rhs.reclaimableBytes
            }
        }
    }

    public var focusedItem: ScannedItem? {
        guard let focusedID = selection.focusedID else { return nil }
        return visibleItems.first(where: { $0.id == focusedID })
    }

    public func startScan() async {
        scanRunnerTask?.cancel()
        streamListenerTask?.cancel()

        itemsByCategory = [:]
        duplicateGroups = []
        selection = MultiSelectState()
        previewPayload = nil
        savedCheckpoint = nil
        isScanning = true
        isPaused = false
        progress = ScanProgress(phase: .enumerating, currentPath: "Preparing scan…")

        let stream = await scanner.makeProgressStream()
        streamListenerTask = Task { @MainActor [weak self] in
            for await batch in stream {
                guard let self else { break }
                self.progress = batch.progress
                if !batch.items.isEmpty {
                    for item in batch.items {
                        var list = self.itemsByCategory[item.category, default: []]
                        if !list.contains(where: { $0.url == item.url }) {
                            list.append(item)
                            self.itemsByCategory[item.category] = list
                        }
                    }
                }
            }
        }

        let outcome = await scanner.runFullScan(configuration: configuration)
        await applyCompletedOutcome(outcome)
    }

    public func pauseScan() async {
        guard isScanning, !isPaused else { return }
        let checkpoint = await scanner.pause()
        guard isScanning else { return }
        savedCheckpoint = checkpoint
        isPaused = true
        progress.phase = .paused
    }

    public func resumeScan() async {
        guard let savedCheckpoint else { return }
        isPaused = false
        isScanning = true
        let outcome = await scanner.resume(from: savedCheckpoint)
        await applyCompletedOutcome(outcome)
    }

    public func cancelScan() async {
        let outcome = await scanner.cancel()
        streamListenerTask?.cancel()
        isScanning = false
        isPaused = false
        savedCheckpoint = nil
        progress = outcome.progress
    }

    public func selectAllInActiveCategory() {
        selection.selectAllEligible(in: visibleItems)
        refreshPreviewForFocus()
    }

    public func clearChecksInActiveCategory() {
        selection.clearChecks(in: visibleItems)
    }

    public func clickRow(_ item: ScannedItem, modifiers: EventModifiers) {
        selection.handleClick(id: item.id, modifiers: modifiers, orderedIDs: visibleItems.map(\.id))
        refreshPreviewForFocus()
    }

    public func moveSelection(offset: Int, extend: Bool) {
        selection.moveFocus(offset: offset, orderedIDs: visibleItems.map(\.id), extendSelection: extend)
        refreshPreviewForFocus()
    }

    public func toggleCheck(for item: ScannedItem) {
        selection.toggleCheck(id: item.id)
    }

    public func toggleHighlightedChecks() {
        selection.toggleCheckedForHighlighted(items: visibleItems)
    }

    public func refreshPreviewForFocus() {
        previewTask?.cancel()
        guard let item = focusedItem else {
            previewPayload = nil
            isLoadingPreview = false
            return
        }
        isLoadingPreview = true
        previewTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let payload = await self.previewService.loadPreview(for: item)
            guard !Task.isCancelled, self.focusedItem?.id == item.id else { return }
            self.previewPayload = payload
            self.isLoadingPreview = false
        }
    }

    public func requestBatchTrash() {
        let targets = checkedItemsInAllCategories
        guard !targets.isEmpty else { return }
        pendingDeletionItems = targets
        showingTrashConfirmation = true
    }

    public func requestBatchPermanentDelete() {
        let targets = checkedItemsInAllCategories
        guard !targets.isEmpty else { return }
        pendingDeletionItems = targets
        showingPermanentConfirmation = true
    }

    public func requestSingleTrash(item: ScannedItem) {
        guard !item.isRecommendedKeep else { return }
        pendingDeletionItems = [item]
        showingTrashConfirmation = true
    }

    public func requestSinglePermanentDelete(item: ScannedItem) {
        guard !item.isRecommendedKeep else { return }
        pendingDeletionItems = [item]
        showingPermanentConfirmation = true
    }

    public func executePendingCleanup(mode: DeletionMode) async {
        let targets = pendingDeletionItems.isEmpty ? checkedItemsInAllCategories : pendingDeletionItems
        pendingDeletionItems = []
        await executeCleanup(targets: targets, mode: mode)
    }

    public func executeSelectedCleanup(mode: DeletionMode) async {
        await executeCleanup(targets: checkedItemsInAllCategories, mode: mode)
    }

    private func executeCleanup(targets: [ScannedItem], mode: DeletionMode) async {
        guard !targets.isEmpty else { return }

        do {
            let report = try await deleter.execute(
                items: targets,
                mode: mode,
                dryRun: isDryRunEnabled,
                excludedFolders: configuration.excludedFolders,
                allowAppBundles: configuration.allowAppBundles
            )
            lastExecutionReport = report

            if !report.isDryRun {
                let removedURLs = Set(report.succeededItems.map(\.url))
                removeURLsFromResults(removedURLs)
                if !report.trashHistoryEntries.isEmpty {
                    await historyStore.append(report.trashHistoryEntries)
                    historyEntries = await historyStore.loadEntries()
                }
                await refreshVolumeStorage()
            }
        } catch {
            statusBannerMessage = error.localizedDescription
        }
    }

    public func restoreHistoryEntry(_ entry: TrashHistoryEntry) async {
        let result = await deleter.restore(entries: [entry])
        if !result.restoredIDs.isEmpty {
            await historyStore.remove(ids: result.restoredIDs)
            historyEntries = await historyStore.loadEntries()
            statusBannerMessage = "Restored \(URL(fileURLWithPath: entry.originalPath).lastPathComponent) to original location."
        } else if let failure = result.failures.first {
            statusBannerMessage = failure.reason
        }
    }

    private func applyCompletedOutcome(_ outcome: ScanOutcome) async {
        if outcome.progress.phase == .paused {
            progress = outcome.progress
            return
        }
        isScanning = false
        isPaused = false
        savedCheckpoint = nil
        progress = outcome.progress
        if !outcome.wasCancelled {
            for category in ScanCategory.allCases {
                if configuration.categories.contains(category) {
                    itemsByCategory[category] = outcome.items(in: category)
                }
            }
            duplicateGroups = outcome.duplicateGroups
        }
        if let first = visibleItems.first, selection.focusedID == nil {
            selection.handleClick(id: first.id, modifiers: [], orderedIDs: visibleItems.map(\.id))
            refreshPreviewForFocus()
        }
        await refreshVolumeStorage()
    }

    private func removeURLsFromResults(_ removedURLs: Set<URL>) {
        guard !removedURLs.isEmpty else { return }
        for category in ScanCategory.allCases {
            itemsByCategory[category] = items(for: category).filter { !removedURLs.contains($0.url) }
        }
        duplicateGroups = duplicateGroups.compactMap { group in
            let remainingDups = group.duplicates.filter { !removedURLs.contains($0.url) }
            if removedURLs.contains(group.original.url) || remainingDups.isEmpty {
                return nil
            }
            return DuplicateGroup(id: group.id, original: group.original, duplicates: remainingDups)
        }
        let validIDs = Set(ScanCategory.allCases.flatMap { items(for: $0).map(\.id) })
        selection.pruneRemoved(validIDs: validIDs)
        refreshPreviewForFocus()
    }
}
