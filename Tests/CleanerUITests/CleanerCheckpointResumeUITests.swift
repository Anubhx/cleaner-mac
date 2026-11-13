import Testing
import Foundation
import AppKit
import SwiftUI
@testable import CleanerCore
@testable import CleanerPreview
@testable import CleanerUI

@Suite("CleanerUI Checkpoint Resume Prompt & Lifecycle Triggers")
struct CleanerCheckpointResumeUITests {
    private func makeSandbox() throws -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("CleanerCheckpointUITests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    private func makeCheckpoint(root: URL, scannedFiles: Int = 42, pendingCount: Int = 3) -> ScanCheckpoint {
        let pending = (0..<pendingCount).map {
            root.appendingPathComponent("pending-\($0)", isDirectory: true)
        }
        return ScanCheckpoint(
            configuration: ScanConfiguration(roots: [root]),
            pendingDirectories: pending,
            candidateFiles: [],
            deadItems: [],
            visitedDirectoryPaths: [root.path],
            scannedFiles: scannedFiles,
            bytesEvaluated: 12_345_678,
            skippedProtectedDirectories: 1,
            startedAt: Date(timeIntervalSince1970: 1_731_300_000)
        )
    }

    @Test("On next launch, recent valid checkpoint surfaces non-auto-resuming Resume/Start Fresh banner in CleanerRootView")
    @MainActor
    func surfacesInterruptedBannerWithTwoClearButtonsWithoutAutoResume() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let now = Date(timeIntervalSince1970: 1_731_350_000)
        let savedAt = now.addingTimeInterval(-600) // 10 minutes ago
        let cp = makeCheckpoint(root: sandbox)
        let fakeCheckpointStore = FakeCheckpointStore(initialResult: .loaded(
            checkpoint: cp,
            savedAt: savedAt,
            compressedFileBytes: 1_200,
            uncompressedBytes: 10_000
        ))
        let fakeScanner = SpyResumableScanner()

        let store = CleanerWorkspaceStore(
            scanner: fakeScanner,
            deleter: NoOpDeleter(),
            historyStore: EmptyHistory(),
            checkpointStore: fakeCheckpointStore,
            previewService: PreviewService(),
            permissionChecker: StaticGrantedChecker(),
            notificationCenter: NotificationCenter(),
            nowProvider: { now }
        )

        await store.loadInitialCheckpoint()

        // Must NOT auto-resume
        #expect(store.isScanning == false)
        #expect(await fakeScanner.resumedCheckpoints.isEmpty)

        let prompt = try #require(store.interruptedCheckpointPresentation)
        #expect(prompt.primaryText == "A scan was interrupted 10 minutes ago. Resume or start fresh?")
        #expect(prompt.secondaryText?.contains("42 files evaluated") == true)
        #expect(prompt.secondaryText?.contains("3 folders remaining") == true)

        // Host CleanerRootView and confirm banner + both buttons appear
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1060, height: 680),
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

        #expect(containsText("Resume or start fresh?", in: window.contentView))
        #expect(containsText("42 files evaluated", in: window.contentView))
        #expect(findButton(identifier: "checkpointResumeButton", fallbackText: "Resume", in: window) != nil)
        #expect(findButton(identifier: "checkpointStartFreshButton", fallbackText: "Start Fresh", in: window) != nil)

        // Clicking Resume attaches a fresh progress stream, resumes exact checkpoint, and clears checkpoint on completion
        await store.resumeInterruptedScan()
        let resumed = await fakeScanner.resumedCheckpoints
        #expect(resumed == [cp])
        #expect(await fakeScanner.makeProgressStreamCallCount == 1)
        #expect(store.interruptedCheckpointPresentation == nil)
        #expect(await fakeCheckpointStore.clearCount == 1)
    }

    @Test("Dismissing interrupted checkpoint banner discards checkpoint without starting a scan")
    @MainActor
    func discardBannerClearsCheckpointWithoutScanning() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let now = Date(timeIntervalSince1970: 1_731_350_000)
        let cp = makeCheckpoint(root: sandbox)
        let fakeCheckpointStore = FakeCheckpointStore(initialResult: .loaded(
            checkpoint: cp,
            savedAt: now.addingTimeInterval(-300),
            compressedFileBytes: 900,
            uncompressedBytes: 7_500
        ))
        let fakeScanner = SpyResumableScanner()

        let store = CleanerWorkspaceStore(
            scanner: fakeScanner,
            deleter: NoOpDeleter(),
            historyStore: EmptyHistory(),
            checkpointStore: fakeCheckpointStore,
            previewService: PreviewService(),
            permissionChecker: StaticGrantedChecker(),
            notificationCenter: NotificationCenter(),
            nowProvider: { now }
        )

        await store.loadInitialCheckpoint()
        #expect(store.interruptedCheckpointPresentation != nil)

        await store.discardInterruptedCheckpoint()
        #expect(store.interruptedCheckpointPresentation == nil)
        #expect(await fakeCheckpointStore.clearCount == 1)
        #expect(await fakeScanner.fullScanStartCount == 0)
        #expect(await fakeScanner.resumedCheckpoints.isEmpty)
    }

    @Test("Start Fresh discards checkpoint.json and begins a fresh scan")
    @MainActor
    func startFreshClearsCheckpointAndStartsFreshScan() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let now = Date(timeIntervalSince1970: 1_731_350_000)
        let cp = makeCheckpoint(root: sandbox)
        let fakeCheckpointStore = FakeCheckpointStore(initialResult: .loaded(
            checkpoint: cp,
            savedAt: now.addingTimeInterval(-120),
            compressedFileBytes: 1_000,
            uncompressedBytes: 8_000
        ))
        let fakeScanner = SpyResumableScanner()

        let store = CleanerWorkspaceStore(
            scanner: fakeScanner,
            deleter: NoOpDeleter(),
            historyStore: EmptyHistory(),
            checkpointStore: fakeCheckpointStore,
            previewService: PreviewService(),
            permissionChecker: StaticGrantedChecker(),
            notificationCenter: NotificationCenter(),
            nowProvider: { now }
        )

        await store.loadInitialCheckpoint()
        #expect(store.interruptedCheckpointPresentation != nil)

        await store.startFreshFromInterruptedCheckpoint()
        #expect(store.interruptedCheckpointPresentation == nil)
        #expect(await fakeCheckpointStore.clearCount >= 1)
        #expect(await fakeScanner.fullScanStartCount == 1)
        #expect(await fakeScanner.resumedCheckpoints.isEmpty)
    }

    @Test("Schema mismatch refuses auto-resume and shows clear warning banner; expired checkpoint stays silent")
    @MainActor
    func schemaMismatchWarnsAndExpiredStaysSilent() async throws {
        let mismatchStore = FakeCheckpointStore(initialResult: .schemaMismatch(found: 999, supported: 1))
        let workspaceMismatch = CleanerWorkspaceStore(
            scanner: SpyResumableScanner(),
            deleter: NoOpDeleter(),
            historyStore: EmptyHistory(),
            checkpointStore: mismatchStore,
            previewService: PreviewService(),
            permissionChecker: StaticGrantedChecker(),
            notificationCenter: NotificationCenter()
        )
        await workspaceMismatch.loadInitialCheckpoint()
        #expect(workspaceMismatch.interruptedCheckpointPresentation == nil)
        let warning = try #require(workspaceMismatch.statusBannerMessage)
        #expect(warning.lowercased().contains("previous incomplete scan couldn't be loaded"))

        let expiredStore = FakeCheckpointStore(initialResult: .expired)
        let workspaceExpired = CleanerWorkspaceStore(
            scanner: SpyResumableScanner(),
            deleter: NoOpDeleter(),
            historyStore: EmptyHistory(),
            checkpointStore: expiredStore,
            previewService: PreviewService(),
            permissionChecker: StaticGrantedChecker(),
            notificationCenter: NotificationCenter()
        )
        await workspaceExpired.loadInitialCheckpoint()
        #expect(workspaceExpired.interruptedCheckpointPresentation == nil)
        #expect(workspaceExpired.statusBannerMessage == nil)
    }

    @Test("Manual pause and NSApplication.willTerminateNotification persist checkpoint synchronously")
    @MainActor
    func manualPauseAndWillTerminatePersistCheckpoint() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let center = NotificationCenter()
        let cp = makeCheckpoint(root: sandbox, scannedFiles: 99, pendingCount: 7)
        let fakeScanner = SpyResumableScanner(pauseResult: cp, syncTerminationCheckpoint: cp)
        let fakeCheckpointStore = FakeCheckpointStore(initialResult: .none)

        let store = CleanerWorkspaceStore(
            scanner: fakeScanner,
            deleter: NoOpDeleter(),
            historyStore: EmptyHistory(),
            checkpointStore: fakeCheckpointStore,
            previewService: PreviewService(),
            permissionChecker: StaticGrantedChecker(),
            notificationCenter: center
        )

        // 1. Active scan terminated via willTerminateNotification -> synchronous save immediately!
        store.isScanning = true
        center.post(name: NSApplication.willTerminateNotification, object: nil)
        let syncSaved = await fakeCheckpointStore.lastSyncSavedCheckpoint
        #expect(syncSaved == cp)

        // 2. Manual pause -> async save via checkpointStore.save
        try await Task.sleep(for: .milliseconds(20))
        await store.pauseScan()
        #expect(store.isPaused == true)
        let pausedSaved = await fakeCheckpointStore.lastAsyncSavedCheckpoint
        #expect(pausedSaved == cp)
    }

    @MainActor
    private func accessibilityStringValue(of node: AnyObject) -> String? {
        let sel = NSSelectorFromString("accessibilityValue")
        guard (node as? NSObject)?.responds(to: sel) == true else { return nil }
        return node.perform(sel)?.takeUnretainedValue() as? String
    }

    @MainActor
    private func containsText(_ target: String, in rootView: NSView?) -> Bool {
        guard let rootView else { return false }
        var visited = Set<ObjectIdentifier>()

        func inspect(_ node: AnyObject) -> Bool {
            let oid = ObjectIdentifier(node)
            guard visited.insert(oid).inserted else { return false }
            if let tf = node as? NSTextField, tf.stringValue.contains(target) { return true }
            if let title = node.accessibilityTitle?(), title.contains(target) { return true }
            if let label = node.accessibilityLabel?(), label.contains(target) { return true }
            if let value = accessibilityStringValue(of: node), value.contains(target) { return true }
            if let children = node.accessibilityChildren?() {
                for child in children where inspect(child as AnyObject) { return true }
            }
            if let view = node as? NSView {
                for sub in view.subviews where inspect(sub) { return true }
            }
            return false
        }
        return inspect(rootView)
    }

    @MainActor
    private func findButton(identifier: String, fallbackText: String, in window: NSWindow) -> AnyObject? {
        guard let rootView = window.contentView else { return nil }
        var visited = Set<ObjectIdentifier>()

        func inspect(_ node: AnyObject) -> AnyObject? {
            let oid = ObjectIdentifier(node)
            guard visited.insert(oid).inserted else { return nil }
            if let btn = node as? NSButton,
               !(btn is NSPopUpButton),
               (btn.accessibilityIdentifier() == identifier || btn.title == fallbackText || btn.accessibilityLabel() == fallbackText) {
                return btn
            }
            if node.accessibilityRole?() == .button,
               (node.accessibilityIdentifier?() == identifier || node.accessibilityTitle?() == fallbackText || node.accessibilityLabel?() == fallbackText) {
                return node
            }
            if let children = node.accessibilityChildren?() {
                for child in children {
                    if let found = inspect(child as AnyObject) { return found }
                }
            }
            if let view = node as? NSView {
                for sub in view.subviews {
                    if let found = inspect(sub) { return found }
                }
            }
            return nil
        }

        return inspect(rootView)
    }
}

private actor FakeCheckpointStore: ScanCheckpointStoring {
    let initialResult: ScanCheckpointLoadResult
    private(set) var lastAsyncSavedCheckpoint: ScanCheckpoint?
    private(set) var clearCount = 0
    nonisolated(unsafe) private var syncSavedBox: ScanCheckpoint?

    var lastSyncSavedCheckpoint: ScanCheckpoint? { syncSavedBox }

    init(initialResult: ScanCheckpointLoadResult) {
        self.initialResult = initialResult
    }

    func load() -> ScanCheckpointLoadResult { initialResult }

    func save(_ checkpoint: ScanCheckpoint) throws {
        lastAsyncSavedCheckpoint = checkpoint
    }

    nonisolated func saveSynchronously(_ checkpoint: ScanCheckpoint) throws {
        syncSavedBox = checkpoint
    }

    func clear() {
        clearCount += 1
        lastAsyncSavedCheckpoint = nil
        syncSavedBox = nil
    }
}

private actor SpyResumableScanner: ScanningServicing {
    let pauseResult: ScanCheckpoint
    nonisolated let syncTerminationCheckpoint: ScanCheckpoint?
    private(set) var resumedCheckpoints: [ScanCheckpoint] = []
    private(set) var fullScanStartCount = 0
    private(set) var makeProgressStreamCallCount = 0

    init(
        pauseResult: ScanCheckpoint = ScanCheckpoint(
            configuration: ScanConfiguration(),
            pendingDirectories: [],
            candidateFiles: [],
            deadItems: [],
            visitedDirectoryPaths: [],
            scannedFiles: 0,
            bytesEvaluated: 0,
            startedAt: Date()
        ),
        syncTerminationCheckpoint: ScanCheckpoint? = nil
    ) {
        self.pauseResult = pauseResult
        self.syncTerminationCheckpoint = syncTerminationCheckpoint
    }

    func makeProgressStream() -> AsyncStream<ScanBatch> {
        makeProgressStreamCallCount += 1
        let (stream, cont) = AsyncStream.makeStream(of: ScanBatch.self)
        cont.finish()
        return stream
    }

    func runFullScan(configuration: ScanConfiguration) async -> ScanOutcome {
        fullScanStartCount += 1
        return ScanOutcome(progress: ScanProgress(phase: .completed, startedAt: Date()), wasCancelled: false)
    }

    func start(configuration: ScanConfiguration) async throws {}
    func pause() async -> ScanCheckpoint { pauseResult }

    func resume(from checkpoint: ScanCheckpoint) async -> ScanOutcome {
        resumedCheckpoints.append(checkpoint)
        return ScanOutcome(progress: ScanProgress(phase: .completed, startedAt: checkpoint.startedAt), wasCancelled: false)
    }

    func cancel() async -> ScanOutcome { ScanOutcome(wasCancelled: true) }

    nonisolated func captureCheckpointSynchronously() -> ScanCheckpoint? {
        syncTerminationCheckpoint
    }
}

private actor NoOpDeleter: DeletionServicing {
    func execute(items: [ScannedItem], mode: DeletionMode, dryRun: Bool, excludedFolders: [String], allowAppBundles: Bool, verifySnapshotItems: Bool) async throws -> DeletionExecutionReport {
        DeletionExecutionReport(isDryRun: dryRun, mode: mode, succeededItems: [], reclaimedBytes: 0)
    }
    func restore(entries: [TrashHistoryEntry]) async -> (restoredIDs: Set<UUID>, failures: [DeletionFailure]) { ([], []) }
}

private actor EmptyHistory: HistoryStoring {
    func loadEntries() async -> [TrashHistoryEntry] { [] }
    func append(_ newEntries: [TrashHistoryEntry]) async {}
    func remove(ids: Set<UUID>) async {}
}

private final class StaticGrantedChecker: FullDiskAccessChecking, @unchecked Sendable {
    var settingsURL: URL { SystemFullDiskAccessChecker.fullDiskAccessSettingsURL }
    func checkStatus() -> FullDiskAccessStatus { .granted }
}

