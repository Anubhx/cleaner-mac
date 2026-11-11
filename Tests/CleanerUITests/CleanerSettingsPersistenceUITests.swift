import Testing
import Foundation
import AppKit
import SwiftUI
@testable import CleanerCore
@testable import CleanerPreview
@testable import CleanerUI

@Suite("CleanerUI Settings Persistence & Category Toggles")
struct CleanerSettingsPersistenceUITests {
    private func makeSandbox() throws -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("CleanerSettingsUITests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    @MainActor
    private func makeStore(
        settingsURL: URL,
        snapshotStore: (any ScanSnapshotStoring)? = nil
    ) -> CleanerWorkspaceStore {
        let settingsStore = FileBackedTestSettingsStore(fileURL: settingsURL)
        return CleanerWorkspaceStore(
            scanner: NoOpScanner(),
            deleter: NoOpDeleter(),
            historyStore: EmptyHistory(),
            snapshotStore: snapshotStore,
            settingsStore: settingsStore,
            previewService: PreviewService(),
            permissionChecker: StaticGrantedChecker(),
            notificationCenter: NotificationCenter(),
            pathExists: { _ in true }
        )
    }

    @Test("Full workspace settings round-trip restores all configuration and UI preferences on relaunch")
    @MainActor
    func fullSettingsRoundTripAcrossRelaunch() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let settingsURL = sandbox.appendingPathComponent("CleanerMac/settings.json")
        let customRootA = sandbox.appendingPathComponent("RootA", isDirectory: true)
        let customRootB = sandbox.appendingPathComponent("RootB", isDirectory: true)

        let firstSession = makeStore(settingsURL: settingsURL)
        firstSession.configuration.roots = [customRootA, customRootB]
        firstSession.configuration.excludedFolders = [".git", "/tmp/PrivateCache"]
        firstSession.configuration.largeFileThresholdBytes = 350 * 1_048_576
        firstSession.configuration.minDuplicateBytes = 4 * 1_048_576
        firstSession.configuration.oldFileThresholdDays = 45
        firstSession.configuration.minimumActiveCacheBytes = 80 * 1_048_576
        firstSession.configuration.ageBasis = .lastModifiedOnly
        firstSession.configuration.categories = [.largeFiles, .deadFiles]
        firstSession.configuration.skipHiddenFiles = false
        firstSession.configuration.allowAppBundles = true
        firstSession.selectedSidebarDestination = .category(.oldFiles)
        firstSession.sortOrder = .riskHighest
        firstSession.isInspectorVisible = false

        // Switch away to Settings before quitting -> lastSelectedCategory must remain .oldFiles
        firstSession.selectedSidebarDestination = .settings
        await firstSession.flushSettingsSave()

        // Simulate quit + fresh app launch reading from same settings.json
        let relaunched = makeStore(settingsURL: settingsURL)
        await relaunched.loadInitialSettings()

        #expect(relaunched.configuration.roots == [customRootA, customRootB])
        #expect(relaunched.configuration.excludedFolders == [".git", "/tmp/PrivateCache"])
        #expect(relaunched.configuration.largeFileThresholdBytes == 350 * 1_048_576)
        #expect(relaunched.configuration.minDuplicateBytes == 4 * 1_048_576)
        #expect(relaunched.configuration.oldFileThresholdDays == 45)
        #expect(relaunched.configuration.minimumActiveCacheBytes == 80 * 1_048_576)
        #expect(relaunched.configuration.ageBasis == .lastModifiedOnly)
        #expect(relaunched.configuration.categories == [.largeFiles, .deadFiles])
        #expect(relaunched.configuration.skipHiddenFiles == false)
        #expect(relaunched.configuration.allowAppBundles == true)
        #expect(relaunched.selectedSidebarDestination == .category(.oldFiles))
        #expect(relaunched.sortOrder == .riskHighest)
        #expect(relaunched.isInspectorVisible == false)
    }

    @Test("Dry-Run ALWAYS defaults to OFF on every relaunch regardless of prior session state")
    @MainActor
    func dryRunNeverPersistsAcrossRelaunch() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let settingsURL = sandbox.appendingPathComponent("CleanerMac/settings.json")

        let firstSession = makeStore(settingsURL: settingsURL)
        #expect(firstSession.isDryRunEnabled == false)
        firstSession.isDryRunEnabled = true
        firstSession.sortOrder = .dateOldest
        await firstSession.flushSettingsSave()

        // Confirm settings.json on disk contains zero dry-run flag
        let rawText = try String(contentsOf: settingsURL, encoding: .utf8)
        #expect(!rawText.contains("isDryRunEnabled"))
        #expect(!rawText.contains("dryRun"))

        // Even if someone manually injected "isDryRunEnabled": true into settings.json, relaunch stays OFF
        var json = try #require(try JSONSerialization.jsonObject(with: Data(rawText.utf8)) as? [String: Any])
        json["isDryRunEnabled"] = true
        let tamperedData = try JSONSerialization.data(withJSONObject: json)
        try tamperedData.write(to: settingsURL)

        let relaunched = makeStore(settingsURL: settingsURL)
        await relaunched.loadInitialSettings()

        #expect(relaunched.sortOrder == .dateOldest)
        #expect(relaunched.isDryRunEnabled == false)
    }

    @Test("Settings load runs cleanly before snapshot load and preserves persisted UI preferences")
    @MainActor
    func settingsLoadPrecedesSnapshotAndPreservesCategoryAndSortOrder() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let settingsURL = sandbox.appendingPathComponent("CleanerMac/settings.json")
        let settingsStore = FileBackedTestSettingsStore(fileURL: settingsURL)
        try await settingsStore.save(
            UserSettings(
                lastSelectedCategory: .oldFiles,
                sortOrder: .nameAscending,
                isInspectorVisible: false
            )
        )

        let startedAt = Date(timeIntervalSince1970: 1_731_300_000)
        let largeItem = ScannedItem(
            url: URL(fileURLWithPath: "/Users/alice/Downloads/big.iso"),
            name: "big.iso",
            logicalSize: 200_000_000,
            allocatedSize: 200_000_000,
            isDirectory: false,
            category: .largeFiles
        )
        let snapshot = ScanSnapshot(
            startedAt: startedAt,
            finishedAt: startedAt.addingTimeInterval(5),
            duration: 5,
            appVersion: "1.0.0",
            configuration: ScanConfiguration(roots: [URL(fileURLWithPath: "/Users/alice")]),
            progress: ScanProgress(phase: .completed, scannedFiles: 1, bytesEvaluated: largeItem.logicalSize, startedAt: startedAt),
            categories: [
                CategorySnapshot(category: .largeFiles, items: [largeItem]),
                CategorySnapshot(category: .oldFiles, items: [])
            ],
            duplicateGroups: [],
            totalReclaimableBytes: largeItem.reclaimableDiskBytes
        )

        let store = makeStore(settingsURL: settingsURL, snapshotStore: InMemorySnapshotStore(snapshot: snapshot))
        await store.loadInitialSettings()
        await store.loadInitialSnapshot()

        // Persisted category (.oldFiles), sort order, and inspector visibility must stay intact after snapshot restore
        #expect(store.selectedSidebarDestination == .category(.oldFiles))
        #expect(store.sortOrder == .nameAscending)
        #expect(store.isInspectorVisible == false)
        #expect(store.items(for: .largeFiles) == [largeItem])
    }

    @Test("ScanSettingsView exposes scan category toggles that persist cleanly while keeping at least one enabled")
    @MainActor
    func scanSettingsViewExposesCategoryTogglesAndFits580Width() async throws {
        enableSwiftUIAccessibilityTree()
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let settingsURL = sandbox.appendingPathComponent("CleanerMac/settings.json")
        let store = makeStore(settingsURL: settingsURL)

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
        try? await Task.sleep(for: .milliseconds(250))
        window.contentView?.layoutSubtreeIfNeeded()
        defer { window.close() }

        let fittedAt580 = hostingController.sizeThatFits(in: CGSize(width: 580, height: 520))
        #expect(fittedAt580.width <= 580.5)
        if let scrollView = findScrollView(in: window.contentView),
           let documentView = scrollView.documentView {
            #expect(documentView.frame.width <= 580.5)
        }

        // Also verify full vertical content renders Scan Categories & all 4 toggle switches without 580pt clipping
        window.setContentSize(NSSize(width: 580, height: 1100))
        window.contentView?.layoutSubtreeIfNeeded()
        try? await Task.sleep(for: .milliseconds(250))
        window.contentView?.layoutSubtreeIfNeeded()
        #expect(containsText("Scan Categories", in: window.contentView))
        for category in ScanCategory.allCases {
            #expect(containsText(category.displayName, in: window.contentView))
        }

        // Verify interactive toggle controls exist in accessibility tree for each category
        let identifiers = collectAccessibilityIdentifiers(in: window.contentView)
        for category in ScanCategory.allCases {
            #expect(identifiers.contains("settingsCategoryToggle_\(category.rawValue)"))
        }

        // Toggle via actual SwiftUI Switch accessibility action + verify >=1 guard
        if let duplicatesSwitch = findSwitch(withIdentifier: "settingsCategoryToggle_duplicates", in: window.contentView) {
            #expect(duplicatesSwitch.accessibilityPerformPress?() == true)
            try? await Task.sleep(for: .milliseconds(100))
            #expect(!store.configuration.categories.contains(.duplicates))
            #expect(duplicatesSwitch.accessibilityPerformPress?() == true)
            try? await Task.sleep(for: .milliseconds(100))
            #expect(store.configuration.categories.contains(.duplicates))
        } else {
            Issue.record("Expected Switch accessibility node for settingsCategoryToggle_duplicates")
        }

        // Disable 3 categories, verify the final 1 cannot be disabled
        store.setCategory(.duplicates, enabled: false)
        store.setCategory(.oldFiles, enabled: false)
        store.setCategory(.deadFiles, enabled: false)
        #expect(store.configuration.categories == [.largeFiles])

        store.setCategory(.largeFiles, enabled: false)
        #expect(store.configuration.categories == [.largeFiles])

        await Task.yield()
        try? await Task.sleep(for: .milliseconds(100))
        if let largeFilesSwitch = findSwitch(withIdentifier: "settingsCategoryToggle_largeFiles", in: window.contentView) {
            let isEnabled = (largeFilesSwitch as? NSObject)?
                .perform(NSSelectorFromString("isAccessibilityEnabled"))?
                .takeUnretainedValue() as? NSNumber
            if let isEnabled {
                #expect(isEnabled.boolValue == false)
            }
        }

        store.setCategory(.duplicates, enabled: true)
        #expect(store.configuration.categories == [.largeFiles, .duplicates])

        await store.flushSettingsSave()
        let relaunched = makeStore(settingsURL: settingsURL)
        await relaunched.loadInitialSettings()
        #expect(relaunched.configuration.categories == [.largeFiles, .duplicates])
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

            if let tf = node as? NSTextField, tf.stringValue.contains(target) {
                return true
            }
            if let title = node.accessibilityTitle?(), title.contains(target) {
                return true
            }
            if let label = node.accessibilityLabel?(), label.contains(target) {
                return true
            }
            if let value = accessibilityStringValue(of: node), value.contains(target) {
                return true
            }
            if let children = node.accessibilityChildren?() {
                for child in children where inspect(child as AnyObject) {
                    return true
                }
            }
            if let view = node as? NSView {
                for sub in view.subviews where inspect(sub) {
                    return true
                }
            }
            return false
        }

        return inspect(rootView)
    }

    @MainActor
    private func collectAccessibilityIdentifiers(in rootView: NSView?) -> Set<String> {
        guard let rootView else { return [] }
        var visited = Set<ObjectIdentifier>()
        var identifiers = Set<String>()

        func inspect(_ node: AnyObject) {
            let oid = ObjectIdentifier(node)
            guard visited.insert(oid).inserted else { return }

            if let id = node.accessibilityIdentifier?(), !id.isEmpty {
                identifiers.insert(id)
            }
            if let children = node.accessibilityChildren?() {
                for child in children {
                    inspect(child as AnyObject)
                }
            }
            if let view = node as? NSView {
                if let viewID = view.identifier?.rawValue, !viewID.isEmpty {
                    identifiers.insert(viewID)
                }
                for sub in view.subviews {
                    inspect(sub)
                }
            }
        }

        inspect(rootView)
        return identifiers
    }

    @MainActor
    private func findSwitch(withIdentifier targetID: String, in rootView: NSView?) -> AnyObject? {
        guard let rootView else { return nil }
        var visited = Set<ObjectIdentifier>()

        func inspect(_ node: AnyObject) -> AnyObject? {
            let oid = ObjectIdentifier(node)
            guard visited.insert(oid).inserted else { return nil }

            if node.accessibilityIdentifier?() == targetID,
               node.accessibilityRole?() == .checkBox {
                return node
            }
            if let children = node.accessibilityChildren?() {
                for child in children {
                    if let found = inspect(child as AnyObject) {
                        return found
                    }
                }
            }
            if let view = node as? NSView {
                for sub in view.subviews {
                    if let found = inspect(sub) {
                        return found
                    }
                }
            }
            return nil
        }

        return inspect(rootView)
    }
}

private actor FileBackedTestSettingsStore: UserSettingsStoring {
    let fileURL: URL

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    func load() -> UserSettings? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(UserSettings.self, from: data)
    }

    func save(_ settings: UserSettings) throws {
        let dir = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(settings)
        try data.write(to: fileURL, options: .atomic)
    }
}

private actor InMemorySnapshotStore: ScanSnapshotStoring {
    let snapshot: ScanSnapshot?
    init(snapshot: ScanSnapshot?) { self.snapshot = snapshot }
    func load() -> ScanSnapshot? { snapshot }
    func save(_ snapshot: ScanSnapshot) throws {}
}

private actor NoOpScanner: ScanningServicing {
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

private actor NoOpDeleter: DeletionServicing {
    func execute(items: [ScannedItem], mode: DeletionMode, dryRun: Bool, excludedFolders: [String], allowAppBundles: Bool) async throws -> DeletionExecutionReport {
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
