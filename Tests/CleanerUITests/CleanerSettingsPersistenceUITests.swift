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

    @Test("Clear Stored Scan Data asks confirmation, honors Cancel, and deletes only session files while keeping settings and history")
    @MainActor
    func clearStoredScanDataPreservesSettingsAndHistory() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let settingsURL = sandbox.appendingPathComponent("CleanerMac/settings.json")
        let snapshotURL = sandbox.appendingPathComponent("CleanerMac/session/last-scan.json")
        let checkpointURL = sandbox.appendingPathComponent("CleanerMac/session/checkpoint.json")

        let customRoot = sandbox.appendingPathComponent("CustomRoot", isDirectory: true)
        try FileManager.default.createDirectory(at: customRoot, withIntermediateDirectories: true)
        let scannedFile = customRoot.appendingPathComponent("big.bin")
        try Data(repeating: 1, count: 64).write(to: scannedFile)

        let settingsStore = FileBackedTestSettingsStore(fileURL: settingsURL)
        try await settingsStore.save(
            UserSettings(
                scanRoots: [customRoot],
                excludedFolders: [".git", "/tmp/KeepMe"],
                oldFileThresholdDays: 120,
                selectedCategories: [.largeFiles, .oldFiles],
                lastSelectedCategory: .oldFiles,
                sortOrder: .nameAscending,
                isInspectorVisible: false
            )
        )

        let snapshotItem = ScannedItem(
            url: scannedFile,
            name: "big.bin",
            logicalSize: 200_000_000,
            allocatedSize: 200_000_000,
            isDirectory: false,
            category: .largeFiles
        )
        let startedAt = Date(timeIntervalSince1970: 1_731_300_000)
        let snapshot = ScanSnapshot(
            startedAt: startedAt,
            finishedAt: startedAt.addingTimeInterval(4),
            duration: 4,
            appVersion: "2.0.0",
            configuration: ScanConfiguration(roots: [customRoot]),
            progress: ScanProgress(phase: .completed, scannedFiles: 1, bytesEvaluated: 200_000_000, startedAt: startedAt),
            categories: [CategorySnapshot(category: .largeFiles, items: [snapshotItem])],
            duplicateGroups: [],
            totalReclaimableBytes: snapshotItem.reclaimableDiskBytes
        )
        let snapshotStore = FileBackedTestSnapshotStore(fileURL: snapshotURL)
        try await snapshotStore.save(snapshot)

        let checkpoint = ScanCheckpoint(
            configuration: ScanConfiguration(roots: [customRoot]),
            pendingDirectories: [customRoot],
            candidateFiles: [snapshotItem],
            deadItems: [],
            visitedDirectoryPaths: [],
            scannedFiles: 1,
            bytesEvaluated: 200_000_000,
            startedAt: Date()
        )
        let checkpointStore = FileBackedTestCheckpointStore(fileURL: checkpointURL)
        try await checkpointStore.save(checkpoint)

        let historyEntry = TrashHistoryEntry(
            originalPath: "/Users/alice/Downloads/old.dmg",
            trashPath: "/Users/alice/.Trash/old.dmg",
            bytes: 12_345,
            trashInode: nil
        )
        let historyStore = SeededHistory(entries: [historyEntry])

        let store = CleanerWorkspaceStore(
            scanner: NoOpScanner(),
            deleter: NoOpDeleter(),
            historyStore: historyStore,
            snapshotStore: snapshotStore,
            settingsStore: settingsStore,
            checkpointStore: checkpointStore,
            previewService: PreviewService(),
            permissionChecker: StaticGrantedChecker(),
            notificationCenter: NotificationCenter(),
            pathExists: { url in FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) }
        )

        await store.loadInitialSettings()
        await store.loadInitialHistory()
        await store.loadInitialSnapshot()
        await store.loadInitialCheckpoint()

        #expect(store.items(for: .largeFiles) == [snapshotItem])
        #expect(store.interruptedCheckpointPresentation != nil)
        #expect(store.historyEntries == [historyEntry])

        // 1. Request confirmation, then cancel -> zero changes on disk or memory
        store.requestClearStoredScanData()
        #expect(store.showingClearStoredScanDataConfirmation == true)
        store.showingClearStoredScanDataConfirmation = false

        #expect(FileManager.default.fileExists(atPath: snapshotURL.path(percentEncoded: false)))
        #expect(FileManager.default.fileExists(atPath: checkpointURL.path(percentEncoded: false)))
        #expect(FileManager.default.fileExists(atPath: settingsURL.path(percentEncoded: false)))
        #expect(store.items(for: .largeFiles) == [snapshotItem])
        #expect(store.interruptedCheckpointPresentation != nil)

        // 2. Confirm Clear Stored Scan Data -> deletes session JSONs & clears scan state, preserves settings & history
        store.requestClearStoredScanData()
        await store.clearStoredScanData()

        #expect(store.showingClearStoredScanDataConfirmation == false)
        #expect(!FileManager.default.fileExists(atPath: snapshotURL.path(percentEncoded: false)))
        #expect(!FileManager.default.fileExists(atPath: checkpointURL.path(percentEncoded: false)))
        #expect(FileManager.default.fileExists(atPath: settingsURL.path(percentEncoded: false)))

        #expect(store.items(for: .largeFiles).isEmpty)
        #expect(store.duplicateGroups.isEmpty)
        #expect(store.loadedSnapshotFinishedAt == nil)
        #expect(store.loadedSnapshotAge == nil)
        #expect(store.interruptedCheckpointPresentation == nil)
        #expect(store.progress.phase == .idle)

        // Settings & Trash history MUST remain untouched
        #expect(store.configuration.roots == [customRoot])
        #expect(store.configuration.excludedFolders == [".git", "/tmp/KeepMe"])
        #expect(store.configuration.oldFileThresholdDays == 120)
        #expect(store.configuration.categories == [.largeFiles, .oldFiles])
        #expect(store.sortOrder == .nameAscending)
        #expect(store.isInspectorVisible == false)
        #expect(store.historyEntries == [historyEntry])
    }

    @Test("Reset Settings asks confirmation, deletes settings.json without re-creating it, and preserves scan data")
    @MainActor
    func resetSettingsRestoresDefaultsAndPreservesScanData() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let settingsURL = sandbox.appendingPathComponent("CleanerMac/settings.json")
        let snapshotURL = sandbox.appendingPathComponent("CleanerMac/session/last-scan.json")
        let checkpointURL = sandbox.appendingPathComponent("CleanerMac/session/checkpoint.json")

        let customRoot = sandbox.appendingPathComponent("CustomRoot", isDirectory: true)
        try FileManager.default.createDirectory(at: customRoot, withIntermediateDirectories: true)
        let scannedFile = customRoot.appendingPathComponent("clip.mov")
        try Data(repeating: 2, count: 64).write(to: scannedFile)

        let settingsStore = FileBackedTestSettingsStore(fileURL: settingsURL)
        let snapshotStore = FileBackedTestSnapshotStore(fileURL: snapshotURL)
        let checkpointStore = FileBackedTestCheckpointStore(fileURL: checkpointURL)

        let item = ScannedItem(
            url: scannedFile,
            name: "clip.mov",
            logicalSize: 150_000_000,
            allocatedSize: 150_000_000,
            isDirectory: false,
            category: .largeFiles
        )
        let startedAt = Date(timeIntervalSince1970: 1_731_300_000)
        try await snapshotStore.save(
            ScanSnapshot(
                startedAt: startedAt,
                finishedAt: startedAt.addingTimeInterval(2),
                duration: 2,
                appVersion: "2.0.0",
                configuration: ScanConfiguration(roots: [customRoot]),
                progress: ScanProgress(phase: .completed, scannedFiles: 1, bytesEvaluated: 150_000_000, startedAt: startedAt),
                categories: [CategorySnapshot(category: .largeFiles, items: [item])],
                duplicateGroups: [],
                totalReclaimableBytes: item.reclaimableDiskBytes
            )
        )
        try await checkpointStore.save(
            ScanCheckpoint(
                configuration: ScanConfiguration(roots: [customRoot]),
                pendingDirectories: [customRoot],
                candidateFiles: [],
                deadItems: [],
                visitedDirectoryPaths: [],
                scannedFiles: 1,
                bytesEvaluated: 150_000_000,
                startedAt: Date()
            )
        )

        let store = CleanerWorkspaceStore(
            scanner: NoOpScanner(),
            deleter: NoOpDeleter(),
            historyStore: EmptyHistory(),
            snapshotStore: snapshotStore,
            settingsStore: settingsStore,
            checkpointStore: checkpointStore,
            previewService: PreviewService(),
            permissionChecker: StaticGrantedChecker(),
            notificationCenter: NotificationCenter(),
            pathExists: { url in FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) }
        )

        store.configuration.roots = [customRoot]
        store.configuration.oldFileThresholdDays = 365
        store.configuration.categories = [.largeFiles]
        store.sortOrder = .riskHighest
        store.isInspectorVisible = false
        store.isDryRunEnabled = true
        store.selectedSidebarDestination = .settings
        await store.flushSettingsSave()
        await store.loadInitialSnapshot()

        #expect(FileManager.default.fileExists(atPath: settingsURL.path(percentEncoded: false)))

        store.requestResetSettings()
        #expect(store.showingResetSettingsConfirmation == true)
        await store.resetSettingsToDefaults()
        await store.flushSettingsSave()
        try? await Task.sleep(for: .milliseconds(50))

        #expect(store.showingResetSettingsConfirmation == false)
        #expect(!FileManager.default.fileExists(atPath: settingsURL.path(percentEncoded: false)))
        #expect(FileManager.default.fileExists(atPath: snapshotURL.path(percentEncoded: false)))
        #expect(FileManager.default.fileExists(atPath: checkpointURL.path(percentEncoded: false)))

        #expect(store.configuration == ScanConfiguration())
        #expect(store.sortOrder == .sizeDescending)
        #expect(store.isInspectorVisible == true)
        #expect(store.isDryRunEnabled == false)
        #expect(store.selectedSidebarDestination == .settings)
        #expect(store.items(for: .largeFiles) == [item])
    }

    @Test("ScanSettingsView Stored Data & Reset card and confirmation sheets use opaque surfaces and trigger cleanly")
    @MainActor
    func storedDataCardAndConfirmationSheetsRenderOpaquely() async throws {
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
            contentRect: NSRect(x: 0, y: 0, width: 580, height: 1350),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentViewController = hostingController
        window.setContentSize(NSSize(width: 580, height: 1350))
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

        #expect(!containsVisualEffectView(in: window.contentView))
        #expect(containsText("Stored Data & Reset", in: window.contentView))
        let identifiers = collectAccessibilityIdentifiers(in: window.contentView)
        #expect(identifiers.contains("settingsStoredDataCard"))

        let clearButton = try #require(
            findButton(
                in: window,
                matchingIdentifier: "settingsClearStoredScanDataButton",
                fallbackText: "Clear Stored Scan Data…"
            )
        )
        #expect(clearButton.frameInWindow.minX >= 0 && clearButton.frameInWindow.maxX <= 580.5)
        #expect(clearButton.press() == true)
        try? await Task.sleep(for: .milliseconds(100))
        #expect(store.showingClearStoredScanDataConfirmation == true)

        // Reset sheet flag and press Reset Settings button
        store.showingClearStoredScanDataConfirmation = false
        let resetButton = try #require(
            findButton(
                in: window,
                matchingIdentifier: "settingsResetDefaultsButton",
                fallbackText: "Reset Settings to Defaults…"
            )
        )
        #expect(resetButton.frameInWindow.minX >= 0 && resetButton.frameInWindow.maxX <= 580.5)
        #expect(resetButton.press() == true)
        try? await Task.sleep(for: .milliseconds(100))
        #expect(store.showingResetSettingsConfirmation == true)

        // Verify both confirmation sheets render without NSVisualEffectView and wire confirm callbacks
        var confirmedClear = false
        let clearSheetHost = NSHostingController(
            rootView: ClearStoredScanDataConfirmationSheet(
                onConfirm: { confirmedClear = true },
                onCancel: {}
            )
        )
        let clearWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 220), styleMask: [.titled], backing: .buffered, defer: false)
        clearWindow.isReleasedWhenClosed = false
        clearWindow.contentViewController = clearSheetHost
        clearWindow.makeKeyAndOrderFront(nil)
        clearWindow.contentView?.layoutSubtreeIfNeeded()
        try? await Task.sleep(for: .milliseconds(150))
        defer { clearWindow.close() }
        #expect(!containsVisualEffectView(in: clearWindow.contentView))
        let confirmClearButton = try #require(
            findButton(
                in: clearWindow,
                matchingIdentifier: "confirmClearStoredScanDataButton",
                fallbackText: "Clear Stored Scan Data"
            )
        )
        #expect(confirmClearButton.press() == true)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(confirmedClear == true)

        var confirmedReset = false
        let resetSheetHost = NSHostingController(
            rootView: ResetSettingsConfirmationSheet(
                onConfirm: { confirmedReset = true },
                onCancel: {}
            )
        )
        let resetWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 220), styleMask: [.titled], backing: .buffered, defer: false)
        resetWindow.isReleasedWhenClosed = false
        resetWindow.contentViewController = resetSheetHost
        resetWindow.makeKeyAndOrderFront(nil)
        resetWindow.contentView?.layoutSubtreeIfNeeded()
        try? await Task.sleep(for: .milliseconds(150))
        defer { resetWindow.close() }
        #expect(!containsVisualEffectView(in: resetWindow.contentView))
        let confirmResetButton = try #require(
            findButton(
                in: resetWindow,
                matchingIdentifier: "confirmResetSettingsButton",
                fallbackText: "Reset Settings"
            )
        )
        #expect(confirmResetButton.press() == true)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(confirmedReset == true)
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

    private struct ButtonHandle {
        let frameInWindow: NSRect
        let press: @MainActor () -> Bool
    }

    @MainActor
    private func findButton(
        in window: NSWindow,
        matchingIdentifier identifier: String,
        fallbackText: String
    ) -> ButtonHandle? {
        guard let rootView = window.contentView else { return nil }
        var visited = Set<ObjectIdentifier>()

        func inspect(_ node: AnyObject) -> ButtonHandle? {
            let oid = ObjectIdentifier(node)
            guard visited.insert(oid).inserted else { return nil }

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
                return ButtonHandle(
                    frameInWindow: window.convertFromScreen(screenFrame),
                    press: { node.accessibilityPerformPress?() ?? false }
                )
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

    @MainActor
    private func containsVisualEffectView(in rootView: NSView?) -> Bool {
        guard let rootView else { return false }
        if rootView is NSVisualEffectView { return true }
        return rootView.subviews.contains { containsVisualEffectView(in: $0) }
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

    func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}

private actor FileBackedTestSnapshotStore: ScanSnapshotStoring {
    let fileURL: URL

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    func load() -> ScanSnapshot? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(ScanSnapshot.self, from: data)
    }

    func save(_ snapshot: ScanSnapshot) throws {
        let dir = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(snapshot)
        try data.write(to: fileURL, options: .atomic)
    }

    func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}

private actor FileBackedTestCheckpointStore: ScanCheckpointStoring {
    let fileURL: URL

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    func load() -> ScanCheckpointLoadResult {
        guard let data = try? Data(contentsOf: fileURL) else { return .none }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let checkpoint = try? decoder.decode(ScanCheckpoint.self, from: data) else {
            return .corrupted
        }
        return .loaded(checkpoint: checkpoint, savedAt: Date(), compressedFileBytes: data.count, uncompressedBytes: data.count)
    }

    func save(_ checkpoint: ScanCheckpoint) throws {
        try saveSynchronously(checkpoint)
    }

    nonisolated func saveSynchronously(_ checkpoint: ScanCheckpoint) throws {
        let dir = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(checkpoint)
        try data.write(to: fileURL, options: .atomic)
    }

    func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}

private actor InMemorySnapshotStore: ScanSnapshotStoring {
    var snapshot: ScanSnapshot?
    init(snapshot: ScanSnapshot?) { self.snapshot = snapshot }
    func load() -> ScanSnapshot? { snapshot }
    func save(_ snapshot: ScanSnapshot) throws { self.snapshot = snapshot }
    func clear() { snapshot = nil }
}

private actor SeededHistory: HistoryStoring {
    var entries: [TrashHistoryEntry]
    init(entries: [TrashHistoryEntry]) { self.entries = entries }
    func loadEntries() async -> [TrashHistoryEntry] { entries }
    func append(_ newEntries: [TrashHistoryEntry]) async { entries.append(contentsOf: newEntries) }
    func remove(ids: Set<UUID>) async { entries.removeAll { ids.contains($0.id) } }
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
