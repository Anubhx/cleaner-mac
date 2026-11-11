import Testing
import Foundation
import os
import AppKit
import SwiftUI
@testable import CleanerCore
@testable import CleanerPreview
@testable import CleanerUI

@Suite("CleanerUI Snapshot Persistence & Staleness Banners")
struct CleanerSnapshotPersistenceUITests {
    private func makeItem(
        path: String,
        category: ScanCategory = .largeFiles,
        size: UInt64 = 10_485_760,
        createdDate: Date = Date(timeIntervalSince1970: 1_700_000_000),
        inode: UInt64 = 1,
        isRecommendedKeep: Bool = false
    ) -> ScannedItem {
        ScannedItem(
            id: UUID(),
            url: URL(fileURLWithPath: path),
            name: URL(fileURLWithPath: path).lastPathComponent,
            logicalSize: size,
            allocatedSize: size,
            isDirectory: false,
            modifiedDate: createdDate,
            createdDate: createdDate,
            accessedDate: createdDate,
            category: category,
            deadKind: nil,
            risk: RiskAssessment(level: .low, reason: "Fixture item"),
            inode: InodeIdentity(device: 1, inode: inode),
            linkCount: 1,
            isCloudDataless: false,
            contentTypeIdentifier: "public.data",
            isRecommendedKeep: isRecommendedKeep
        )
    }

    @Test("Restores snapshot categories and duplicate groups, clears all checks, recomputes Keep Original, and excludes missing roots")
    @MainActor
    func loadsSnapshotSafelyRecomputingKeepAndClearingChecks() async throws {
        let validRoot = URL(fileURLWithPath: "/Users/alice")
        let missingRoot = URL(fileURLWithPath: "/Volumes/DetachedDrive")

        let docsOrig = makeItem(
            path: "/Users/alice/Documents/video.mov",
            category: .duplicates,
            inode: 10,
            isRecommendedKeep: false
        )
        let downloadsDup = makeItem(
            path: "/Users/alice/Downloads/video.mov",
            category: .duplicates,
            inode: 11,
            isRecommendedKeep: true
        )
        let bigFile = makeItem(
            path: "/Users/alice/Downloads/big.iso",
            category: .largeFiles,
            size: 524_288_000,
            inode: 12
        )
        let unavailableFile = makeItem(
            path: "/Volumes/DetachedDrive/backup.dmg",
            category: .largeFiles,
            size: 1_073_741_824,
            inode: 13
        )

        let startedAt = Date(timeIntervalSince1970: 1_731_300_000)
        let finishedAt = startedAt.addingTimeInterval(20)
        let now = finishedAt.addingTimeInterval(2 * 3_600) // 2 hours old -> .subtle

        let staleSnapshot = ScanSnapshot(
            startedAt: startedAt,
            finishedAt: finishedAt,
            duration: 20,
            appVersion: "1.0.0",
            configuration: ScanConfiguration(roots: [validRoot, missingRoot]),
            progress: ScanProgress(
                phase: .completed,
                currentPath: "",
                scannedFiles: 120,
                bytesEvaluated: 2_000_000_000,
                pendingDirectoriesCount: 0,
                skippedProtectedDirectories: 0,
                startedAt: startedAt
            ),
            categories: [
                CategorySnapshot(category: .duplicates, items: [downloadsDup, docsOrig]),
                CategorySnapshot(category: .largeFiles, items: [bigFile, unavailableFile])
            ],
            duplicateGroups: [
                DuplicateGroup(id: "sha256:vid", original: downloadsDup, duplicates: [docsOrig])
            ],
            totalReclaimableBytes: 1_608_515_584
        )

        let fakeSnapshotStore = FakeSnapshotService(initial: staleSnapshot)
        let existingPaths: Set<String> = [
            validRoot.standardizedFileURL.path,
            docsOrig.url.standardizedFileURL.path,
            downloadsDup.url.standardizedFileURL.path,
            bigFile.url.standardizedFileURL.path
        ]

        let store = CleanerWorkspaceStore(
            scanner: IdleFakeScanner(),
            deleter: NoOpDeletionService(),
            historyStore: EmptyHistoryService(),
            snapshotStore: fakeSnapshotStore,
            previewService: PreviewService(),
            permissionChecker: GrantedPermissionChecker(),
            notificationCenter: NotificationCenter(),
            pathExists: { url in existingPaths.contains(url.standardizedFileURL.path) },
            nowProvider: { now }
        )

        // Seed stale selection before restore to confirm restore explicitly clears ALL checks/highlights
        store.selection.toggleCheck(id: bigFile.id)
        store.selection.toggleCheck(id: downloadsDup.id)

        await store.loadInitialSnapshot()

        #expect(store.selection.checkedIDs.isEmpty)
        #expect(store.selection.highlightedIDs.isEmpty)
        #expect(store.selection.focusedID == nil)
        #expect(store.loadedSnapshotFinishedAt == finishedAt)
        #expect(store.loadedSnapshotAge == TimeInterval(2 * 3_600))
        #expect(store.loadedSnapshotStaleness == .subtle)

        #expect(store.unavailableSnapshotRoots == [missingRoot])
        #expect(store.unavailableSnapshotItems.map(\.url) == [unavailableFile.url])
        #expect(store.items(for: .largeFiles).map(\.url) == [bigFile.url])

        // Keep Original must be freshly recomputed (Documents wins over Downloads)
        let group = try #require(store.duplicateGroups.first)
        #expect(group.original.url == docsOrig.url)
        #expect(group.original.isRecommendedKeep == true)
        #expect(group.duplicates.map(\.url) == [downloadsDup.url])
        #expect(group.duplicates.allSatisfy { !$0.isRecommendedKeep })
        #expect(store.items(for: .duplicates).map(\.isRecommendedKeep) == [true, false])
    }

    @Test("Saves snapshot after completed scan, preserves snapshot on cancel, and updates snapshot after non-dry-run deletion")
    @MainActor
    func savesCompletedScanSkipsCancelAndSyncsCleanup() async throws {
        let root = URL(fileURLWithPath: "/Users/alice")
        let itemA = makeItem(path: "/Users/alice/Downloads/a.iso", category: .largeFiles, size: 100_000_000, inode: 1)
        let itemB = makeItem(path: "/Users/alice/Downloads/b.iso", category: .largeFiles, size: 200_000_000, inode: 2)

        let startedAt = Date(timeIntervalSince1970: 1_731_300_000)
        let finishedAt = startedAt.addingTimeInterval(15)
        let completedOutcome = ScanOutcome(
            itemsByCategory: [.largeFiles: [itemA, itemB]],
            duplicateGroups: [],
            progress: ScanProgress(
                phase: .completed,
                currentPath: "",
                scannedFiles: 50,
                bytesEvaluated: 300_000_000,
                pendingDirectoriesCount: 0,
                skippedProtectedDirectories: 0,
                startedAt: startedAt
            ),
            wasCancelled: false
        )
        let cancelledOutcome = ScanOutcome(
            itemsByCategory: [:],
            duplicateGroups: [],
            progress: ScanProgress(phase: .cancelled, startedAt: startedAt.addingTimeInterval(60)),
            wasCancelled: true
        )

        let scanner = SwitchableOutcomeScanner(outcomes: [completedOutcome, cancelledOutcome])
        let snapshotStore = FakeSnapshotService()
        let store = CleanerWorkspaceStore(
            scanner: scanner,
            deleter: NoOpDeletionService(),
            historyStore: EmptyHistoryService(),
            snapshotStore: snapshotStore,
            previewService: PreviewService(),
            permissionChecker: GrantedPermissionChecker(),
            notificationCenter: NotificationCenter(),
            nowProvider: { finishedAt },
            appVersionProvider: { "1.2.3" }
        )
        store.configuration = ScanConfiguration(roots: [root], categories: [.largeFiles])

        await store.startScan()
        let firstSaved = try #require(await snapshotStore.lastSaved)
        #expect(firstSaved.appVersion == "1.2.3")
        #expect(firstSaved.finishedAt == finishedAt)
        #expect(firstSaved.categories.first(where: { $0.category == .largeFiles })?.items.count == 2)
        #expect(await snapshotStore.saveCount == 1)

        // Move one item to Trash -> saved snapshot updates without overwriting original scan finishedAt
        store.selectedSidebarDestination = .category(.largeFiles)
        store.toggleCheck(for: itemA)
        await store.executeSelectedCleanup(mode: .moveToTrash)
        #expect(await snapshotStore.saveCount == 2)
        let syncedAfterDelete = try #require(await snapshotStore.lastSaved)
        #expect(syncedAfterDelete.finishedAt == finishedAt)
        #expect(syncedAfterDelete.categories.first(where: { $0.category == .largeFiles })?.items.map(\.url) == [itemB.url])

        // Cancelled subsequent scan must NOT overwrite snapshot on disk
        await store.startScan()
        #expect(await snapshotStore.saveCount == 2)
    }

    @Test("Hosted CleanerRootView renders distinct under-1h, 1-24h subtle, and over-24h prominent snapshot staleness banners")
    @MainActor
    func rendersThreeSnapshotStalenessBannersClearly() async {
        enableSwiftUIAccessibilityTree()
        InstrumentSerifFontRegistrar.registerBundledFonts()

        func hostBannerCheck(ageSeconds: TimeInterval, expectedTexts: [String], forbiddenTexts: [String]) async -> String {
            let root = URL(fileURLWithPath: "/Users/alice")
            let item = makeItem(path: "/Users/alice/Downloads/sample.zip", category: .largeFiles, size: 80_000_000)
            let now = Date(timeIntervalSince1970: 1_731_350_000)
            let finishedAt = now.addingTimeInterval(-ageSeconds)
            let snapshot = ScanSnapshot(
                startedAt: finishedAt.addingTimeInterval(-10),
                finishedAt: finishedAt,
                duration: 10,
                appVersion: "1.0.0",
                configuration: ScanConfiguration(roots: [root]),
                progress: ScanProgress(phase: .completed, scannedFiles: 1, bytesEvaluated: item.logicalSize, startedAt: finishedAt.addingTimeInterval(-10)),
                categories: [CategorySnapshot(category: .largeFiles, items: [item])],
                duplicateGroups: [],
                totalReclaimableBytes: item.reclaimableDiskBytes
            )
            let store = CleanerWorkspaceStore(
                scanner: IdleFakeScanner(),
                deleter: NoOpDeletionService(),
                historyStore: EmptyHistoryService(),
                snapshotStore: FakeSnapshotService(initial: snapshot),
                previewService: PreviewService(),
                permissionChecker: GrantedPermissionChecker(),
                notificationCenter: NotificationCenter(),
                pathExists: { _ in true },
                nowProvider: { now }
            )
            await store.loadInitialSnapshot()

            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1040, height: 680),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.isReleasedWhenClosed = false
            window.contentViewController = NSHostingController(rootView: CleanerRootView(store: store))
            window.makeKeyAndOrderFront(nil)
            window.contentView?.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(250))
            window.contentView?.layoutSubtreeIfNeeded()
            defer { window.close() }

            let tree = dumpAccessibilityTree(in: window.contentView)
            for needle in expectedTexts {
                #expect(containsText(needle, in: window.contentView), "Missing '\(needle)' in hosted banner. Tree:\n\(tree)")
            }
            for forbidden in forbiddenTexts {
                #expect(!containsText(forbidden, in: window.contentView), "Unexpected '\(forbidden)' in banner. Tree:\n\(tree)")
            }
            return tree
        }

        _ = await hostBannerCheck(
            ageSeconds: 900,
            expectedTexts: ["Last scanned"],
            forbiddenTexts: ["may be outdated", "Re-verify before deleting"]
        )
        _ = await hostBannerCheck(
            ageSeconds: 4 * 3_600,
            expectedTexts: ["Last scanned", "may be outdated"],
            forbiddenTexts: ["Re-verify before deleting"]
        )
        _ = await hostBannerCheck(
            ageSeconds: 30 * 3_600,
            expectedTexts: ["Results are from a previous session. Re-verify before deleting.", "Last scanned"],
            forbiddenTexts: []
        )
    }

    @Test("Slow snapshot load does not overwrite active scan and coexists cleanly with FDA banner")
    @MainActor
    func slowSnapshotLoadRespectsActiveScanAndCoexistsWithFDABanner() async {
        let root = URL(fileURLWithPath: "/Users/alice")
        let staleItem = makeItem(path: "/Users/alice/Downloads/stale.zip", category: .largeFiles, size: 10_000_000)
        let freshItem = makeItem(path: "/Users/alice/Downloads/fresh.zip", category: .largeFiles, size: 20_000_000)

        let now = Date(timeIntervalSince1970: 1_731_350_000)
        let finishedAt = now.addingTimeInterval(-30 * 3_600)
        let snapshot = ScanSnapshot(
            startedAt: finishedAt.addingTimeInterval(-5),
            finishedAt: finishedAt,
            duration: 5,
            appVersion: "1.0.0",
            configuration: ScanConfiguration(roots: [root]),
            progress: ScanProgress(phase: .completed, scannedFiles: 1, bytesEvaluated: staleItem.logicalSize, startedAt: finishedAt.addingTimeInterval(-5)),
            categories: [CategorySnapshot(category: .largeFiles, items: [staleItem])],
            duplicateGroups: [],
            totalReclaimableBytes: staleItem.reclaimableDiskBytes
        )

        let slowStore = SlowSnapshotService(snapshot: snapshot)
        let freshOutcome = ScanOutcome(
            itemsByCategory: [.largeFiles: [freshItem]],
            progress: ScanProgress(phase: .completed, scannedFiles: 1, bytesEvaluated: freshItem.logicalSize, startedAt: now),
            wasCancelled: false
        )
        let fdaChecker = NotGrantedPermissionChecker()
        let store = CleanerWorkspaceStore(
            scanner: SwitchableOutcomeScanner(outcomes: [freshOutcome]),
            deleter: NoOpDeletionService(),
            historyStore: EmptyHistoryService(),
            snapshotStore: slowStore,
            previewService: PreviewService(),
            permissionChecker: fdaChecker,
            notificationCenter: NotificationCenter(),
            pathExists: { _ in true },
            nowProvider: { now }
        )

        // Start async snapshot load, then immediately start a live scan before snapshot finishes loading
        let loadTask = Task { @MainActor in
            await store.loadInitialSnapshot()
        }
        await slowStore.waitUntilLoadStarted()
        await store.startScan()
        await slowStore.resumeLoad()
        await loadTask.value

        #expect(store.items(for: .largeFiles).map(\.url) == [freshItem.url])
        #expect(store.loadedSnapshotFinishedAt == nil)

        // Now verify FDA limited-scan banner and snapshot banner coexist cleanly on a fresh store
        let restoreStore = CleanerWorkspaceStore(
            scanner: IdleFakeScanner(),
            deleter: NoOpDeletionService(),
            historyStore: EmptyHistoryService(),
            snapshotStore: FakeSnapshotService(initial: snapshot),
            previewService: PreviewService(),
            permissionChecker: fdaChecker,
            notificationCenter: NotificationCenter(),
            pathExists: { _ in true },
            nowProvider: { now }
        )
        restoreStore.handleWelcomeDismissed(completed: false)
        await restoreStore.loadInitialSnapshot()

        #expect(restoreStore.isLimitedScanBannerVisible == true)
        #expect(restoreStore.snapshotBannerPresentation?.staleness == .stale)
        restoreStore.dismissSnapshotBanner()
        #expect(restoreStore.snapshotBannerPresentation == nil)
        #expect(restoreStore.isLimitedScanBannerVisible == true)
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
    private func containsText(_ needle: String, in rootView: NSView?) -> Bool {
        guard let rootView else { return false }
        var visited = Set<ObjectIdentifier>()
        let sel = NSSelectorFromString("accessibilityValue")

        func inspect(_ node: AnyObject) -> Bool {
            let oid = ObjectIdentifier(node)
            guard visited.insert(oid).inserted else { return false }

            if let field = node as? NSTextField, field.stringValue.contains(needle) {
                return true
            }
            if (node as? NSObject)?.responds(to: sel) == true,
               let val = node.perform(sel)?.takeUnretainedValue() as? String,
               val.contains(needle) {
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
        let sel = NSSelectorFromString("accessibilityValue")

        func walk(_ node: AnyObject, depth: Int) {
            let oid = ObjectIdentifier(node)
            guard visited.insert(oid).inserted, lines.count < 160 else { return }
            let indent = String(repeating: "  ", count: depth)
            let cls = NSStringFromClass(type(of: node))
            var desc = "\(indent)\(cls)"
            if let id = node.accessibilityIdentifier?(), !id.isEmpty { desc += " id=\(id)" }
            if let label = node.accessibilityLabel?(), !label.isEmpty { desc += " label='\(label)'" }
            if (node as? NSObject)?.responds(to: sel) == true,
               let val = node.perform(sel)?.takeUnretainedValue() as? String,
               !val.isEmpty {
                desc += " val='\(val)'"
            }
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

private actor FakeSnapshotService: ScanSnapshotStoring {
    private var stored: ScanSnapshot?
    private(set) var saveCount = 0

    var lastSaved: ScanSnapshot? { stored }

    init(initial: ScanSnapshot? = nil) {
        self.stored = initial
    }

    func load() -> ScanSnapshot? {
        stored
    }

    func save(_ snapshot: ScanSnapshot) throws {
        guard snapshot.progress.phase == .completed else { return }
        stored = snapshot
        saveCount += 1
    }
}

private actor IdleFakeScanner: ScanningServicing {
    func makeProgressStream() -> AsyncStream<ScanBatch> {
        let (stream, cont) = AsyncStream.makeStream(of: ScanBatch.self)
        cont.finish()
        return stream
    }

    func runFullScan(configuration: ScanConfiguration) async -> ScanOutcome {
        ScanOutcome()
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
    func resume(from checkpoint: ScanCheckpoint) async -> ScanOutcome { ScanOutcome() }
    func cancel() async -> ScanOutcome { ScanOutcome(wasCancelled: true) }
}

private actor SwitchableOutcomeScanner: ScanningServicing {
    private var outcomes: [ScanOutcome]

    init(outcomes: [ScanOutcome]) {
        self.outcomes = outcomes
    }

    func makeProgressStream() -> AsyncStream<ScanBatch> {
        let (stream, cont) = AsyncStream.makeStream(of: ScanBatch.self)
        cont.finish()
        return stream
    }

    func runFullScan(configuration: ScanConfiguration) async -> ScanOutcome {
        outcomes.isEmpty ? ScanOutcome() : outcomes.removeFirst()
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
    func resume(from checkpoint: ScanCheckpoint) async -> ScanOutcome { ScanOutcome() }
    func cancel() async -> ScanOutcome { ScanOutcome(wasCancelled: true) }
}

private actor NoOpDeletionService: DeletionServicing {
    func execute(
        items: [ScannedItem],
        mode: DeletionMode,
        dryRun: Bool,
        excludedFolders: [String],
        allowAppBundles: Bool,
        verifySnapshotItems: Bool
    ) async throws -> DeletionExecutionReport {
        DeletionExecutionReport(isDryRun: dryRun, mode: mode, succeededItems: items, reclaimedBytes: 0)
    }

    func restore(entries: [TrashHistoryEntry]) async -> (restoredIDs: Set<UUID>, failures: [DeletionFailure]) {
        ([], [])
    }
}

private actor EmptyHistoryService: HistoryStoring {
    func loadEntries() async -> [TrashHistoryEntry] { [] }
    func append(_ newEntries: [TrashHistoryEntry]) async {}
    func remove(ids: Set<UUID>) async {}
}

private final class GrantedPermissionChecker: FullDiskAccessChecking, @unchecked Sendable {
    var settingsURL: URL { SystemFullDiskAccessChecker.fullDiskAccessSettingsURL }
    func checkStatus() -> FullDiskAccessStatus { .granted }
}

private final class NotGrantedPermissionChecker: FullDiskAccessChecking, @unchecked Sendable {
    var settingsURL: URL { SystemFullDiskAccessChecker.fullDiskAccessSettingsURL }
    func checkStatus() -> FullDiskAccessStatus { .notGranted }
}

private actor SlowSnapshotService: ScanSnapshotStoring {
    private let snapshot: ScanSnapshot?
    private var started = false
    private var gate: CheckedContinuation<Void, Never>?

    init(snapshot: ScanSnapshot?) {
        self.snapshot = snapshot
    }

    func load() async -> ScanSnapshot? {
        started = true
        await withCheckedContinuation { cont in
            gate = cont
        }
        return snapshot
    }

    func waitUntilLoadStarted() async {
        while !started {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    func resumeLoad() {
        gate?.resume()
        gate = nil
    }

    func save(_ snapshot: ScanSnapshot) throws {}
}
