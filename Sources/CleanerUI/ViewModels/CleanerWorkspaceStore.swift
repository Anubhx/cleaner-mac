import Foundation
import os
import AppKit
import SwiftUI
import Observation
import CleanerCore
import CleanerPreview

private struct WorkspaceStoreFocusedKey: FocusedValueKey {
    typealias Value = CleanerWorkspaceStore
}

public extension FocusedValues {
    var workspaceStore: CleanerWorkspaceStore? {
        get { self[WorkspaceStoreFocusedKey.self] }
        set { self[WorkspaceStoreFocusedKey.self] = newValue }
    }
}

private final class WorkspaceCancellationBag: Sendable {
    private let tasks = OSAllocatedUnfairLock(initialState: [String: Task<Void, Never>]())

    func replace(_ key: String, with task: Task<Void, Never>?) {
        let previous = tasks.withLock { store in
            let old = store[key]
            if let task {
                store[key] = task
            } else {
                store.removeValue(forKey: key)
            }
            return old
        }
        previous?.cancel()
    }

    func cancel(_ key: String) {
        replace(key, with: nil)
    }

    func cancelAll() {
        let all = tasks.withLock { store -> [Task<Void, Never>] in
            let values = Array(store.values)
            store.removeAll()
            return values
        }
        for task in all {
            task.cancel()
        }
    }
}

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

public struct SnapshotBannerPresentation: Equatable, Sendable {
    public let staleness: SnapshotStaleness
    public let primaryText: String
    public let secondaryText: String?

    public init(staleness: SnapshotStaleness, primaryText: String, secondaryText: String?) {
        self.staleness = staleness
        self.primaryText = primaryText
        self.secondaryText = secondaryText
    }
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

    public private(set) var loadedSnapshotFinishedAt: Date?
    public private(set) var loadedSnapshotAge: TimeInterval?
    public var isSnapshotBannerDismissed: Bool = false
    public private(set) var unavailableSnapshotRoots: [URL] = []
    public private(set) var unavailableSnapshotItems: [ScannedItem] = []

    public var selection: MultiSelectState = MultiSelectState()
    public var previewPayload: PreviewPayload?
    public var isLoadingPreview: Bool = false

    public var showingTrashConfirmation: Bool = false
    public var showingPermanentConfirmation: Bool = false
    public var pendingDeletionItems: [ScannedItem] = []
    public var lastExecutionReport: DeletionExecutionReport?
    public var statusBannerMessage: String?
    public var permissionStatus: FullDiskAccessStatus
    public var onPermissionStatusDidChange: (@MainActor (FullDiskAccessStatus) -> Void)?

    private let scanner: any ScanningServicing
    private let deleter: any DeletionServicing
    private let historyStore: any HistoryStoring
    private let snapshotStore: (any ScanSnapshotStoring)?
    private let previewService: any PreviewServicing
    private let permissionChecker: any FullDiskAccessChecking
    private let pathExists: @Sendable (URL) -> Bool
    private let nowProvider: @Sendable () -> Date
    private let appVersionProvider: @Sendable () -> String
    private let openURLHandler: @MainActor (URL) -> Bool

    private var savedCheckpoint: ScanCheckpoint?
    private var activeScanID = UUID()
    private var activeScanConfiguration: ScanConfiguration?
    private var lastCompletedSnapshotConfiguration: ScanConfiguration?
    private var lastCompletedStartedAt: Date?
    private var lastCompletedFinishedAt: Date?
    private var lastCompletedProgress: ScanProgress?
    private let cancellationBag = WorkspaceCancellationBag()
    private let activationObserver = ApplicationActivationObserver()

    public init(
        scanner: any ScanningServicing,
        deleter: any DeletionServicing,
        historyStore: any HistoryStoring,
        snapshotStore: (any ScanSnapshotStoring)? = nil,
        previewService: any PreviewServicing = PreviewService(),
        permissionChecker: any FullDiskAccessChecking = SystemFullDiskAccessChecker(),
        notificationCenter: NotificationCenter = .default,
        pathExists: @escaping @Sendable (URL) -> Bool = {
            FileManager.default.fileExists(atPath: $0.standardizedFileURL.path(percentEncoded: false))
        },
        nowProvider: @escaping @Sendable () -> Date = { Date() },
        appVersionProvider: @escaping @Sendable () -> String = {
            Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
        },
        openURLHandler: @escaping @MainActor (URL) -> Bool = { NSWorkspace.shared.open($0) }
    ) {
        self.scanner = scanner
        self.deleter = deleter
        self.historyStore = historyStore
        self.snapshotStore = snapshotStore
        self.previewService = previewService
        self.permissionChecker = permissionChecker
        self.pathExists = pathExists
        self.nowProvider = nowProvider
        self.appVersionProvider = appVersionProvider
        self.openURLHandler = openURLHandler
        self.permissionStatus = permissionChecker.checkStatus()
        self.activationObserver.observeApplicationActivation(on: notificationCenter) { [weak self] in
            self?.refreshPermissionStatus()
        }
    }

    deinit {
        cancellationBag.cancelAll()
        activationObserver.invalidate()
    }

    @discardableResult
    public func refreshPermissionStatus() -> FullDiskAccessStatus {
        let updated = permissionChecker.checkStatus()
        updatePermissionState(updated)
        onPermissionStatusDidChange?(updated)
        return updated
    }

    public func applyPermissionStatus(_ updated: FullDiskAccessStatus) {
        updatePermissionState(updated)
    }

    @discardableResult
    public func openFullDiskAccessSettings() -> Bool {
        openURLHandler(permissionChecker.settingsURL)
    }

    public var isLimitedScanBannerVisible: Bool {
        guard let banner = statusBannerMessage else { return false }
        return banner.hasPrefix("Limited scan mode:") && !permissionStatus.isGranted
    }

    public func handleWelcomeDismissed(completed: Bool, permissionStatus status: FullDiskAccessStatus? = nil) {
        let resolved: FullDiskAccessStatus
        if let status {
            updatePermissionState(status)
            resolved = status
        } else {
            resolved = refreshPermissionStatus()
        }
        guard !resolved.isGranted else { return }
        if !completed {
            statusBannerMessage = "Limited scan mode: Full Disk Access is not granted, so protected folders (Mail, Safari, Messages) will be skipped safely."
        }
    }

    private func updatePermissionState(_ updated: FullDiskAccessStatus) {
        permissionStatus = updated
        if updated.isGranted,
           let banner = statusBannerMessage,
           banner.hasPrefix("Limited scan mode:") {
            statusBannerMessage = nil
        }
    }

    public func loadInitialHistory() async {
        historyEntries = await historyStore.loadEntries()
        await refreshVolumeStorage()
    }

    public func loadInitialSnapshot() async {
        guard let snapshotStore,
              !isScanning,
              itemsByCategory.isEmpty,
              duplicateGroups.isEmpty,
              progress.phase == .idle else {
            return
        }

        let initialGeneration = activeScanID
        let checker = pathExists
        let restored = await Task.detached(priority: .utility) {
            guard let snapshot = await snapshotStore.load() else {
                return Optional<RestoredScanSnapshot>.none
            }
            return ScanSnapshotRestorer.restore(from: snapshot, pathExists: checker)
        }.value

        guard !Task.isCancelled,
              !isScanning,
              activeScanID == initialGeneration,
              itemsByCategory.isEmpty,
              duplicateGroups.isEmpty,
              progress.phase == .idle,
              let restored else {
            return
        }

        itemsByCategory = restored.itemsByCategory
        duplicateGroups = restored.duplicateGroups
        selection = MultiSelectState()
        pendingDeletionItems = []
        previewPayload = nil
        isLoadingPreview = false
        progress = restored.progress
        unavailableSnapshotRoots = restored.unavailableRoots
        unavailableSnapshotItems = restored.unavailableItems
        loadedSnapshotFinishedAt = restored.finishedAt
        loadedSnapshotAge = max(0, nowProvider().timeIntervalSince(restored.finishedAt))
        isSnapshotBannerDismissed = false
        lastCompletedSnapshotConfiguration = restored.configuration
        lastCompletedStartedAt = restored.startedAt
        lastCompletedFinishedAt = restored.finishedAt
        lastCompletedProgress = restored.progress

        if selectedSidebarDestination == .category(.duplicates),
           items(for: .duplicates).isEmpty,
           let firstNonEmpty = ScanCategory.allCases.first(where: { !items(for: $0).isEmpty }) {
            selectedSidebarDestination = .category(firstNonEmpty)
        }
    }

    public var loadedSnapshotStaleness: SnapshotStaleness? {
        guard let age = loadedSnapshotAge else { return nil }
        return SnapshotStaleness.classify(age: age)
    }

    public var isSnapshotBannerVisible: Bool {
        loadedSnapshotFinishedAt != nil
            && loadedSnapshotStaleness != nil
            && !isSnapshotBannerDismissed
            && !isScanning
    }

    public var snapshotBannerPresentation: SnapshotBannerPresentation? {
        guard isSnapshotBannerVisible,
              let finishedAt = loadedSnapshotFinishedAt,
              let staleness = loadedSnapshotStaleness else {
            return nil
        }

        let shortTime = Calendar.current.isDateInToday(finishedAt)
            ? finishedAt.formatted(date: .omitted, time: .shortened)
            : finishedAt.formatted(date: .abbreviated, time: .shortened)
        let fullDateTime = finishedAt.formatted(date: .abbreviated, time: .shortened)
        let unavailableNote: String? = unavailableSnapshotRoots.isEmpty
            ? nil
            : {
                let count = unavailableSnapshotRoots.count
                let folderWord = count == 1 ? "folder" : "folders"
                return "Excluded \(count) unavailable scan \(folderWord) that no longer exist on disk."
            }()

        switch staleness {
        case .fresh:
            return SnapshotBannerPresentation(
                staleness: .fresh,
                primaryText: "Last scanned \(shortTime)",
                secondaryText: unavailableNote
            )
        case .subtle:
            return SnapshotBannerPresentation(
                staleness: .subtle,
                primaryText: "Last scanned \(shortTime) — Results may be outdated.",
                secondaryText: unavailableNote
            )
        case .stale:
            let detail = ["Last scanned \(fullDateTime)", unavailableNote]
                .compactMap { $0 }
                .joined(separator: " · ")
            return SnapshotBannerPresentation(
                staleness: .stale,
                primaryText: "Results are from a previous session. Re-verify before deleting.",
                secondaryText: detail
            )
        }
    }

    public func dismissSnapshotBanner() {
        isSnapshotBannerDismissed = true
    }

    public func refreshVolumeStorage() async {
        let expectedRoot = configuration.roots.first ?? FileManager.default.homeDirectoryForCurrentUser
        let snapshot = await scanner.volumeStorageSnapshot(for: expectedRoot)
        let currentRoot = configuration.roots.first ?? FileManager.default.homeDirectoryForCurrentUser
        guard expectedRoot == currentRoot else { return }
        volumeStorage = snapshot
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
        let scanID = UUID()
        activeScanID = scanID
        let scanConfig = configuration
        activeScanConfiguration = scanConfig
        cancellationBag.cancel("stream")
        cancellationBag.cancel("preview")

        itemsByCategory = [:]
        duplicateGroups = []
        selection = MultiSelectState()
        previewPayload = nil
        isLoadingPreview = false
        savedCheckpoint = nil
        loadedSnapshotFinishedAt = nil
        loadedSnapshotAge = nil
        isSnapshotBannerDismissed = false
        unavailableSnapshotRoots = []
        unavailableSnapshotItems = []
        lastCompletedSnapshotConfiguration = nil
        lastCompletedStartedAt = nil
        lastCompletedFinishedAt = nil
        lastCompletedProgress = nil
        isScanning = true
        isPaused = false
        progress = ScanProgress(phase: .enumerating, currentPath: "Preparing scan…")

        let stream = await scanner.makeProgressStream()
        guard activeScanID == scanID else { return }

        let streamTask = Task { @MainActor [weak self] in
            for await batch in stream {
                guard !Task.isCancelled, let self, self.activeScanID == scanID else { break }
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
        cancellationBag.replace("stream", with: streamTask)

        let outcome = await scanner.runFullScan(configuration: scanConfig)
        await applyCompletedOutcome(outcome, configuration: scanConfig, for: scanID)
    }

    public func pauseScan() async {
        guard isScanning, !isPaused else { return }
        let scanID = activeScanID
        let checkpoint = await scanner.pause()
        guard isScanning, activeScanID == scanID else { return }
        savedCheckpoint = checkpoint
        isPaused = true
        progress.phase = .paused
    }

    public func resumeScan() async {
        guard let checkpoint = savedCheckpoint else { return }
        let scanID = activeScanID
        activeScanConfiguration = checkpoint.configuration
        isPaused = false
        isScanning = true
        let outcome = await scanner.resume(from: checkpoint)
        await applyCompletedOutcome(outcome, configuration: checkpoint.configuration, for: scanID)
    }

    public func cancelScan() async {
        let scanID = UUID()
        activeScanID = scanID
        activeScanConfiguration = nil
        cancellationBag.cancel("stream")
        let outcome = await scanner.cancel()
        guard activeScanID == scanID else { return }
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

    public var canToggleHighlightedChecks: Bool {
        visibleItems.contains { selection.highlightedIDs.contains($0.id) && !$0.isRecommendedKeep }
    }

    public func toggleHighlightedChecks() {
        selection.toggleCheckedForHighlighted(items: visibleItems)
    }

    public func revealFocusedInFinder() {
        guard let url = focusedItem?.url else { return }
        revealInFinder(url: url)
    }

    public func copyFocusedPath() {
        guard let url = focusedItem?.url else { return }
        copyPath(url: url)
    }

    public func revealInFinder(url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    public func copyPath(url: URL) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(url.path, forType: .string)
    }

    public func requestTrashSelectionOrFocused() {
        if !checkedItemsInAllCategories.isEmpty {
            requestBatchTrash()
        } else if let item = focusedItem, !item.isRecommendedKeep {
            requestSingleTrash(item: item)
        }
    }

    public func refreshPreviewForFocus() {
        guard let item = focusedItem else {
            cancellationBag.cancel("preview")
            previewPayload = nil
            isLoadingPreview = false
            return
        }
        isLoadingPreview = true
        let service = previewService
        let task = Task { @MainActor [weak self] in
            let payload = await service.loadPreview(for: item)
            guard !Task.isCancelled, let self, self.focusedItem?.id == item.id else { return }
            self.previewPayload = payload
            self.isLoadingPreview = false
        }
        cancellationBag.replace("preview", with: task)
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
                if !removedURLs.isEmpty {
                    await persistUpdatedSnapshotAfterCleanup()
                }
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

    private func applyCompletedOutcome(
        _ outcome: ScanOutcome,
        configuration runConfiguration: ScanConfiguration,
        for scanID: UUID
    ) async {
        guard activeScanID == scanID else { return }
        if outcome.progress.phase == .paused {
            progress = outcome.progress
            return
        }
        cancellationBag.cancel("stream")
        isScanning = false
        isPaused = false
        savedCheckpoint = nil
        activeScanConfiguration = nil
        progress = outcome.progress
        if !outcome.wasCancelled {
            for category in ScanCategory.allCases {
                if runConfiguration.categories.contains(category) {
                    itemsByCategory[category] = outcome.items(in: category)
                }
            }
            duplicateGroups = outcome.duplicateGroups
            if outcome.progress.phase == .completed {
                let startedAt = outcome.progress.startedAt
                let finishedAt = nowProvider()
                lastCompletedSnapshotConfiguration = runConfiguration
                lastCompletedStartedAt = startedAt
                lastCompletedFinishedAt = finishedAt
                lastCompletedProgress = outcome.progress
                await persistCurrentSnapshot(
                    configuration: runConfiguration,
                    startedAt: startedAt,
                    finishedAt: finishedAt,
                    progress: outcome.progress
                )
            }
        }
        if let first = visibleItems.first, selection.focusedID == nil {
            selection.handleClick(id: first.id, modifiers: [], orderedIDs: visibleItems.map(\.id))
            refreshPreviewForFocus()
        }
        if !outcome.wasCancelled,
           outcome.progress.skippedProtectedDirectories > 0,
           !refreshPermissionStatus().isGranted,
           statusBannerMessage == nil {
            let folderWord = outcome.progress.skippedProtectedDirectories == 1 ? "folder" : "folders"
            statusBannerMessage = "Limited scan mode: Skipped \(outcome.progress.skippedProtectedDirectories) protected \(folderWord) without Full Disk Access."
        }
        await refreshVolumeStorage()
    }

    private func persistUpdatedSnapshotAfterCleanup() async {
        guard let config = lastCompletedSnapshotConfiguration,
              let startedAt = lastCompletedStartedAt,
              let finishedAt = lastCompletedFinishedAt,
              let completedProgress = lastCompletedProgress,
              completedProgress.phase == .completed else {
            return
        }
        await persistCurrentSnapshot(
            configuration: config,
            startedAt: startedAt,
            finishedAt: finishedAt,
            progress: completedProgress
        )
    }

    private func persistCurrentSnapshot(
        configuration snapshotConfiguration: ScanConfiguration,
        startedAt: Date,
        finishedAt: Date,
        progress snapshotProgress: ScanProgress
    ) async {
        guard let snapshotStore, snapshotProgress.phase == .completed else { return }

        let categorySnapshots: [CategorySnapshot] = ScanCategory.allCases.compactMap { category in
            let current = itemsByCategory[category] ?? []
            guard snapshotConfiguration.categories.contains(category) || !current.isEmpty else {
                return nil
            }
            return CategorySnapshot(category: category, items: current)
        }

        let snapshot = ScanSnapshot(
            startedAt: startedAt,
            finishedAt: finishedAt,
            duration: max(0, finishedAt.timeIntervalSince(startedAt)),
            appVersion: appVersionProvider(),
            configuration: snapshotConfiguration,
            progress: snapshotProgress,
            categories: categorySnapshots,
            duplicateGroups: duplicateGroups,
            totalReclaimableBytes: currentTotalReclaimableBytes()
        )

        try? await snapshotStore.save(snapshot)
    }

    private func currentTotalReclaimableBytes() -> UInt64 {
        var seenURLs = Set<URL>()
        var total: UInt64 = 0
        for category in ScanCategory.allCases {
            for item in items(for: category) where !item.isRecommendedKeep {
                if seenURLs.insert(item.url).inserted {
                    total &+= item.reclaimableDiskBytes
                }
            }
        }
        return total
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
