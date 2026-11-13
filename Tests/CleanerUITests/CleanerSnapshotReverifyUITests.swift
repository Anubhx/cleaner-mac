import Testing
import Foundation
import AppKit
import SwiftUI
@testable import CleanerCore
@testable import CleanerPreview
@testable import CleanerUI

@Suite("CleanerUI Stale Snapshot Deletion Wiring & Standalone Re-verify Action")
struct CleanerSnapshotReverifyUITests {
    private func makeItem(
        path: String,
        category: ScanCategory = .largeFiles,
        size: UInt64 = 10_485_760,
        modifiedDate: Date = Date(timeIntervalSince1970: 1_700_000_000),
        inode: UInt64
    ) -> ScannedItem {
        ScannedItem(
            id: UUID(),
            url: URL(fileURLWithPath: path),
            name: URL(fileURLWithPath: path).lastPathComponent,
            logicalSize: size,
            allocatedSize: size,
            isDirectory: false,
            modifiedDate: modifiedDate,
            createdDate: modifiedDate,
            accessedDate: modifiedDate,
            category: category,
            inode: InodeIdentity(device: 1, inode: inode),
            linkCount: 1,
            isRecommendedKeep: false
        )
    }

    @Test("Deleting loaded snapshot items enables staleSnapshot verification and preserves blocked items in list")
    @MainActor
    func deletionUsesSnapshotVerificationAndRetainsBlockedItems() async throws {
        let root = URL(fileURLWithPath: "/Users/alice")
        let validItem = makeItem(path: "/Users/alice/Downloads/valid.dmg", inode: 10)
        let staleItem = makeItem(path: "/Users/alice/Downloads/stale.dmg", inode: 11)

        let now = Date(timeIntervalSince1970: 1_731_350_000)
        let finishedAt = now.addingTimeInterval(-7200)
        let snapshot = ScanSnapshot(
            startedAt: finishedAt.addingTimeInterval(-10),
            finishedAt: finishedAt,
            duration: 10,
            appVersion: "1.0.0",
            configuration: ScanConfiguration(roots: [root], categories: [.largeFiles]),
            progress: ScanProgress(phase: .completed, scannedFiles: 2, bytesEvaluated: 20_971_520, startedAt: finishedAt.addingTimeInterval(-10)),
            categories: [CategorySnapshot(category: .largeFiles, items: [validItem, staleItem])],
            duplicateGroups: [],
            totalReclaimableBytes: 20_971_520
        )

        let deleter = SpySnapshotDeleter(blockedURL: staleItem.url, blockedStatus: .replaced)
        let store = CleanerWorkspaceStore(
            scanner: IdleScanner(),
            deleter: deleter,
            historyStore: NoOpHistory(),
            snapshotStore: StubSnapshotStore(snapshot: snapshot),
            previewService: PreviewService(),
            permissionChecker: GrantedChecker(),
            notificationCenter: NotificationCenter(),
            pathExists: { _ in true },
            nowProvider: { now }
        )

        await store.loadInitialSnapshot()
        #expect(store.isResultsFromPersistedSnapshot == true)

        store.toggleCheck(for: validItem)
        store.toggleCheck(for: staleItem)
        await store.executeSelectedCleanup(mode: .moveToTrash)

        let calls = await deleter.verifyFlags
        #expect(calls == [true])

        // Valid item deleted; stale blocked item stays in list with clear verification status
        #expect(store.items(for: .largeFiles).map(\.url) == [staleItem.url])
        #expect(store.verificationStatus(for: staleItem) == .replaced)
    }

    @Test("Standalone Re-verify button walks every snapshot item and surfaces unchanged/modified/missing/replaced without dropping items")
    @MainActor
    func reverifyButtonWalksAllItemsSurfacesBadgesWithoutDropping() async throws {
        enableSwiftUIAccessibilityTree()
        InstrumentSerifFontRegistrar.registerBundledFonts()

        let root = URL(fileURLWithPath: "/Users/alice")
        let unchanged = makeItem(path: "/Users/alice/Downloads/unchanged.dmg", inode: 1)
        let modified = makeItem(path: "/Users/alice/Downloads/modified.dmg", inode: 2)
        let missing = makeItem(path: "/Users/alice/Downloads/missing.dmg", inode: 3)
        let replaced = makeItem(path: "/Users/alice/Downloads/replaced.dmg", inode: 4)

        let now = Date(timeIntervalSince1970: 1_731_350_000)
        let finishedAt = now.addingTimeInterval(-100_000) // >24h stale
        let snapshot = ScanSnapshot(
            startedAt: finishedAt.addingTimeInterval(-10),
            finishedAt: finishedAt,
            duration: 10,
            appVersion: "1.0.0",
            configuration: ScanConfiguration(roots: [root], categories: [.largeFiles]),
            progress: ScanProgress(phase: .completed, scannedFiles: 4, bytesEvaluated: 40_000_000, startedAt: finishedAt.addingTimeInterval(-10)),
            categories: [CategorySnapshot(category: .largeFiles, items: [unchanged, modified, missing, replaced])],
            duplicateGroups: [],
            totalReclaimableBytes: 40_000_000
        )

        let deleter = SpySnapshotDeleter(
            verificationMap: [
                unchanged.id: .unchanged,
                modified.id: .modified,
                missing.id: .missing,
                replaced.id: .replaced,
            ]
        )
        let store = CleanerWorkspaceStore(
            scanner: IdleScanner(),
            deleter: deleter,
            historyStore: NoOpHistory(),
            snapshotStore: StubSnapshotStore(snapshot: snapshot),
            previewService: PreviewService(),
            permissionChecker: GrantedChecker(),
            notificationCenter: NotificationCenter(),
            pathExists: { _ in true },
            nowProvider: { now }
        )

        await store.loadInitialSnapshot()
        store.selectedSidebarDestination = .category(.largeFiles)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1120, height: 720),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: CleanerRootView(store: store))
        window.makeKeyAndOrderFront(nil)
        pumpWindowLayout(window)
        defer { window.close() }

        let initialTree = dumpAccessibilityTree(in: window.contentView)
        // Standalone Re-verify button must exist in ResultsListView toolbar/actionBar
        #expect(findButton(identifier: "reverifySnapshotButton", fallbackText: "Re-verify", in: window) != nil, "Missing reverifySnapshotButton. Tree:\n\(initialTree)")

        await store.reverifyLoadedSnapshot()
        pumpWindowLayout(window)

        let verifiedTree = dumpAccessibilityTree(in: window.contentView)
        // All 4 items MUST remain in the list (none silently dropped, including missing!)
        #expect(store.items(for: .largeFiles).count == 4)
        #expect(store.verificationStatus(for: unchanged) == .unchanged)
        #expect(store.verificationStatus(for: modified) == .modified)
        #expect(store.verificationStatus(for: missing) == .missing)
        #expect(store.verificationStatus(for: replaced) == .replaced)

        // All 4 status markers must surface in the hosted UI
        #expect(containsText("Unchanged", in: window.contentView), "Missing Unchanged badge. Tree:\n\(verifiedTree)")
        #expect(containsText("Modified", in: window.contentView), "Missing Modified badge. Tree:\n\(verifiedTree)")
        #expect(containsText("Missing", in: window.contentView), "Missing Missing badge. Tree:\n\(verifiedTree)")
        #expect(containsText("Replaced", in: window.contentView), "Missing Replaced badge. Tree:\n\(verifiedTree)")
    }

    @Test("Fresh same-session scan resets snapshot provenance and disables persisted-snapshot verification flag")
    @MainActor
    func freshSameSessionScanClearsPersistedSnapshotFlag() async {
        let root = URL(fileURLWithPath: "/Users/alice")
        let oldSnapshotItem = makeItem(path: "/Users/alice/Downloads/from-last-launch.dmg", inode: 10)
        let freshScanItem = makeItem(path: "/Users/alice/Downloads/fresh-this-session.dmg", inode: 20)

        let now = Date(timeIntervalSince1970: 1_731_350_000)
        let finishedAt = now.addingTimeInterval(-3600)
        let snapshot = ScanSnapshot(
            startedAt: finishedAt.addingTimeInterval(-10),
            finishedAt: finishedAt,
            duration: 10,
            appVersion: "1.0.0",
            configuration: ScanConfiguration(roots: [root], categories: [.largeFiles]),
            progress: ScanProgress(phase: .completed, scannedFiles: 1, bytesEvaluated: oldSnapshotItem.logicalSize, startedAt: finishedAt.addingTimeInterval(-10)),
            categories: [CategorySnapshot(category: .largeFiles, items: [oldSnapshotItem])],
            duplicateGroups: [],
            totalReclaimableBytes: oldSnapshotItem.reclaimableDiskBytes
        )

        let freshOutcome = ScanOutcome(
            itemsByCategory: [.largeFiles: [freshScanItem]],
            progress: ScanProgress(phase: .completed, scannedFiles: 1, bytesEvaluated: freshScanItem.logicalSize, startedAt: now),
            wasCancelled: false
        )
        let deleter = SpySnapshotDeleter()
        let store = CleanerWorkspaceStore(
            scanner: FreshResultScanner(outcome: freshOutcome),
            deleter: deleter,
            historyStore: NoOpHistory(),
            snapshotStore: StubSnapshotStore(snapshot: snapshot),
            previewService: PreviewService(),
            permissionChecker: GrantedChecker(),
            notificationCenter: NotificationCenter(),
            pathExists: { _ in true },
            nowProvider: { now }
        )

        await store.loadInitialSnapshot()
        #expect(store.isResultsFromPersistedSnapshot == true)

        await store.startScan()
        #expect(store.isResultsFromPersistedSnapshot == false)

        store.toggleCheck(for: freshScanItem)
        await store.executeSelectedCleanup(mode: .moveToTrash)
        #expect(await deleter.verifyFlags == [false])
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
    private func pumpWindowLayout(_ window: NSWindow) {
        window.contentView?.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.25))
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
    }

    @MainActor
    private func dumpAccessibilityTree(in rootView: NSView?) -> String {
        guard let rootView else { return "<nil>" }
        var lines: [String] = []
        var visited = Set<ObjectIdentifier>()

        func walk(_ node: AnyObject, depth: Int) {
            let oid = ObjectIdentifier(node)
            guard visited.insert(oid).inserted, lines.count < 200 else { return }
            let indent = String(repeating: "  ", count: depth)
            let cls = NSStringFromClass(type(of: node))
            var desc = "\(indent)\(cls)"
            if let id = node.accessibilityIdentifier?(), !id.isEmpty { desc += " id=\(id)" }
            if let label = node.accessibilityLabel?(), !label.isEmpty { desc += " label='\(label)'" }
            if let tf = node as? NSTextField, !tf.stringValue.isEmpty { desc += " text='\(tf.stringValue)'" }
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

    @MainActor
    private func accessibilityStringValue(of node: AnyObject) -> String? {
        let sel = NSSelectorFromString("accessibilityValue")
        guard (node as? NSObject)?.responds(to: sel) == true else { return nil }
        return node.perform(sel)?.takeUnretainedValue() as? String
    }

    @MainActor
    private func containsText(_ needle: String, in rootView: NSView?) -> Bool {
        guard let rootView else { return false }
        var visited = Set<ObjectIdentifier>()

        func inspect(_ node: AnyObject) -> Bool {
            let oid = ObjectIdentifier(node)
            guard visited.insert(oid).inserted else { return false }
            if let tf = node as? NSTextField, tf.stringValue.contains(needle) { return true }
            if let title = node.accessibilityTitle?(), title.contains(needle) { return true }
            if let label = node.accessibilityLabel?(), label.contains(needle) { return true }
            if let val = accessibilityStringValue(of: node), val.contains(needle) { return true }
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
            for child in node.accessibilityChildren?() ?? [] {
                if let found = inspect(child as AnyObject) { return found }
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

private actor SpySnapshotDeleter: DeletionServicing {
    private(set) var verifyFlags: [Bool] = []
    let blockedURL: URL?
    let blockedStatus: SnapshotVerificationStatus?
    let verificationMap: [UUID: SnapshotVerificationStatus]

    init(
        blockedURL: URL? = nil,
        blockedStatus: SnapshotVerificationStatus? = nil,
        verificationMap: [UUID: SnapshotVerificationStatus] = [:]
    ) {
        self.blockedURL = blockedURL
        self.blockedStatus = blockedStatus
        self.verificationMap = verificationMap
    }

    func execute(
        items: [ScannedItem],
        mode: DeletionMode,
        dryRun: Bool,
        excludedFolders: [String],
        allowAppBundles: Bool,
        verifySnapshotItems: Bool
    ) async throws -> DeletionExecutionReport {
        verifyFlags.append(verifySnapshotItems)
        var succeeded: [ScannedItem] = []
        var blocked: [BlockedDeletionItem] = []
        for item in items {
            if item.url == blockedURL {
                blocked.append(BlockedDeletionItem(
                    url: item.url,
                    reason: SnapshotVerificationPolicy.staleSnapshotBlockedReason,
                    verificationStatus: blockedStatus
                ))
            } else {
                succeeded.append(item)
            }
        }
        return DeletionExecutionReport(
            isDryRun: dryRun,
            mode: mode,
            succeededItems: succeeded,
            blockedItems: blocked,
            reclaimedBytes: succeeded.reduce(0) { $0 &+ $1.reclaimableDiskBytes }
        )
    }

    func verifySnapshotItems(_ items: [ScannedItem]) async -> [UUID: SnapshotVerificationStatus] {
        var result: [UUID: SnapshotVerificationStatus] = [:]
        for item in items {
            result[item.id] = verificationMap[item.id] ?? .unchanged
        }
        return result
    }

    func restore(entries: [TrashHistoryEntry]) async -> (restoredIDs: Set<UUID>, failures: [DeletionFailure]) {
        ([], [])
    }
}

private actor StubSnapshotStore: ScanSnapshotStoring {
    let snapshot: ScanSnapshot?
    init(snapshot: ScanSnapshot?) { self.snapshot = snapshot }
    func load() -> ScanSnapshot? { snapshot }
    func save(_ snapshot: ScanSnapshot) throws {}
    func clear() {}
}

private actor IdleScanner: ScanningServicing {
    func makeProgressStream() -> AsyncStream<ScanBatch> {
        let (stream, cont) = AsyncStream.makeStream(of: ScanBatch.self)
        cont.finish()
        return stream
    }
    func runFullScan(configuration: ScanConfiguration) async -> ScanOutcome { ScanOutcome() }
    func start(configuration: ScanConfiguration) async throws {}
    func pause() async -> ScanCheckpoint {
        ScanCheckpoint(configuration: ScanConfiguration(), pendingDirectories: [], candidateFiles: [], deadItems: [], visitedDirectoryPaths: [], scannedFiles: 0, bytesEvaluated: 0, startedAt: Date())
    }
    func resume(from checkpoint: ScanCheckpoint) async -> ScanOutcome { ScanOutcome() }
    func cancel() async -> ScanOutcome { ScanOutcome(wasCancelled: true) }
}

private actor NoOpHistory: HistoryStoring {
    func loadEntries() async -> [TrashHistoryEntry] { [] }
    func append(_ newEntries: [TrashHistoryEntry]) async {}
    func remove(ids: Set<UUID>) async {}
}

private final class GrantedChecker: FullDiskAccessChecking, @unchecked Sendable {
    var settingsURL: URL { SystemFullDiskAccessChecker.fullDiskAccessSettingsURL }
    func checkStatus() -> FullDiskAccessStatus { .granted }
}

private actor FreshResultScanner: ScanningServicing {
    let outcome: ScanOutcome
    init(outcome: ScanOutcome) { self.outcome = outcome }
    func makeProgressStream() -> AsyncStream<ScanBatch> {
        let (stream, cont) = AsyncStream.makeStream(of: ScanBatch.self)
        cont.finish()
        return stream
    }
    func runFullScan(configuration: ScanConfiguration) async -> ScanOutcome { outcome }
    func start(configuration: ScanConfiguration) async throws {}
    func pause() async -> ScanCheckpoint {
        ScanCheckpoint(configuration: ScanConfiguration(), pendingDirectories: [], candidateFiles: [], deadItems: [], visitedDirectoryPaths: [], scannedFiles: 0, bytesEvaluated: 0, startedAt: Date())
    }
    func resume(from checkpoint: ScanCheckpoint) async -> ScanOutcome { outcome }
    func cancel() async -> ScanOutcome { ScanOutcome(wasCancelled: true) }
}
