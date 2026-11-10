import Testing
import Foundation
@testable import CleanerCore
@testable import CleanerSystem

@Suite("Scanner & Deletion Integration Tests")
struct ScanAndDeletionIntegrationTests {
    private func makeSandbox() throws -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("CleanerMacTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    @Test("Staged duplicate detection distinguishes files differing only in middle bytes")
    func duplicateScannerDistinguishesMiddleByteDifference() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let size = 64 * 1024
        let bufferA = Data(repeating: 0xAA, count: size)
        var bufferB = bufferA
        bufferB[size / 2] = 0xBB

        let file1 = sandbox.appendingPathComponent("first.dat")
        let file2 = sandbox.appendingPathComponent("copy_of_first.dat")
        let file3 = sandbox.appendingPathComponent("sneaky_diff.dat")
        try bufferA.write(to: file1)
        try bufferA.write(to: file2)
        try bufferB.write(to: file3)

        let config = ScanConfiguration(
            roots: [sandbox],
            categories: [.duplicates],
            minDuplicateBytes: 1024
        )
        let coordinator = ScanCoordinator(safetyGuard: SafetyGuard(currentUserHome: sandbox))
        let outcome = await coordinator.runFullScan(configuration: config)

        #expect(outcome.duplicateGroups.count == 1)
        let groupURLs = Set([outcome.duplicateGroups[0].original.url] + outcome.duplicateGroups[0].duplicates.map(\.url))
        #expect(groupURLs == Set([file1.standardizedFileURL, file2.standardizedFileURL]))
        #expect(!groupURLs.contains(file3.standardizedFileURL))
    }

    @Test("Scans large, old, broken download, and empty folder categories accurately")
    func scansLargeOldAndDeadFiles() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let downloads = sandbox.appendingPathComponent("Downloads", isDirectory: true)
        let emptyDir = sandbox.appendingPathComponent("EmptyFolder", isDirectory: true)
        let appBundle = sandbox.appendingPathComponent("KeepMe.app/Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: emptyDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: appBundle, withIntermediateDirectories: true)

        let bigFile = downloads.appendingPathComponent("big.bin")
        try Data(repeating: 0x11, count: 16 * 1024).write(to: bigFile)

        let oldFile = downloads.appendingPathComponent("ancient.txt")
        try Data("hello".utf8).write(to: oldFile)
        let veryOldDate = Date().addingTimeInterval(-200 * 24 * 3600)
        try FileManager.default.setAttributes([.modificationDate: veryOldDate], ofItemAtPath: oldFile.path)

        let stalledDownload = downloads.appendingPathComponent("installer.pkg.crdownload")
        try Data("partial".utf8).write(to: stalledDownload)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-48 * 3600)], ofItemAtPath: stalledDownload.path)

        let activeDownload = downloads.appendingPathComponent("active.zip.part")
        try Data("partial".utf8).write(to: activeDownload)

        let config = ScanConfiguration(
            roots: [sandbox],
            downloadsOverride: downloads,
            categories: [.largeFiles, .oldFiles, .deadFiles],
            largeFileThresholdBytes: 10 * 1024,
            oldFileThresholdDays: 90
        )
        let coordinator = ScanCoordinator(safetyGuard: SafetyGuard(currentUserHome: sandbox))
        let outcome = await coordinator.runFullScan(configuration: config)

        let largeURLs = Set(outcome.items(in: .largeFiles).map(\.url))
        let oldURLs = Set(outcome.items(in: .oldFiles).map(\.url))
        let deadURLs = Set(outcome.items(in: .deadFiles).map(\.url))

        #expect(largeURLs.contains(bigFile.standardizedFileURL))
        #expect(oldURLs.contains(oldFile.standardizedFileURL))
        #expect(deadURLs.contains(stalledDownload.standardizedFileURL))
        #expect(!deadURLs.contains(activeDownload.standardizedFileURL))
        #expect(deadURLs.contains(emptyDir.standardizedFileURL))
        #expect(!deadURLs.contains(appBundle.standardizedFileURL))
    }

    @Test("Pause and resume preserve frontier parity with uninterrupted scan")
    func pauseAndResumeProducesIdenticalFileSet() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }

        for dirIndex in 0..<12 {
            let folder = sandbox.appendingPathComponent("folder-\(dirIndex)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for fileIndex in 0..<5 {
                let file = folder.appendingPathComponent("item-\(fileIndex).dat")
                try Data(repeating: UInt8(dirIndex + 1), count: 8192).write(to: file)
            }
        }

        let config = ScanConfiguration(
            roots: [sandbox],
            categories: [.largeFiles],
            largeFileThresholdBytes: 4096
        )
        let coordinator = ScanCoordinator(safetyGuard: SafetyGuard(currentUserHome: sandbox))
        let baseline = await coordinator.runFullScan(configuration: config)
        let baselinePaths = Set(baseline.items(in: .largeFiles).map(\.url.path))
        #expect(baselinePaths.count == 60)

        let pausedCoordinator = ScanCoordinator(
            safetyGuard: SafetyGuard(currentUserHome: sandbox),
            perDirectoryDelay: .milliseconds(3)
        )
        try await pausedCoordinator.start(configuration: config)
        try await Task.sleep(for: .milliseconds(10))
        let checkpoint = await pausedCoordinator.pause()
        #expect(!checkpoint.pendingDirectories.isEmpty)
        let resumedOutcome = await pausedCoordinator.resume(from: checkpoint)
        let resumedPaths = Set(resumedOutcome.items(in: .largeFiles).map(\.url.path))

        #expect(resumedPaths == baselinePaths)
    }

    @Test("Cancel terminates active background scan promptly")
    func cancelTerminatesPromptly() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }

        for i in 0..<25 {
            let dir = sandbox.appendingPathComponent("dir-\(i)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data(repeating: 0x01, count: 1024).write(to: dir.appendingPathComponent("f.dat"))
        }

        let config = ScanConfiguration(roots: [sandbox], categories: [.largeFiles], largeFileThresholdBytes: 512)
        let coordinator = ScanCoordinator(
            safetyGuard: SafetyGuard(currentUserHome: sandbox),
            perDirectoryDelay: .milliseconds(10)
        )

        let stream = await coordinator.makeProgressStream()
        let streamTask = Task<ScanPhase, Never> {
            var phase: ScanPhase = .idle
            for await batch in stream {
                phase = batch.progress.phase
            }
            return phase
        }

        try await coordinator.start(configuration: config)
        try await Task.sleep(for: .milliseconds(25))
        let cancelOutcome = await coordinator.cancel()
        let lastPhase = await streamTask.value

        #expect(cancelOutcome.wasCancelled == true)
        #expect(lastPhase == .cancelled)
    }

    @Test("Orphaned app scanner identifies removed app caches and support while sparing installed apps")
    func orphanedAppDataScannerRespectsInstalledApps() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let appsRoot = sandbox.appendingPathComponent("Applications", isDirectory: true)
        let installedContents = appsRoot.appendingPathComponent("KeepApp.app/Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: installedContents, withIntermediateDirectories: true)
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict><key>CFBundleIdentifier</key><string>com.example.KeepApp</string></dict></plist>
        """
        try Data(plist.utf8).write(to: installedContents.appendingPathComponent("Info.plist"))

        let lib = sandbox.appendingPathComponent("Library", isDirectory: true)
        let keptCache = lib.appendingPathComponent("Caches/com.example.KeepApp", isDirectory: true)
        let orphanCache = lib.appendingPathComponent("Caches/com.example.RemovedApp", isDirectory: true)
        let orphanSupport = lib.appendingPathComponent("Application Support/com.example.RemovedApp", isDirectory: true)
        try FileManager.default.createDirectory(at: keptCache, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: orphanCache, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: orphanSupport, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 4096).write(to: keptCache.appendingPathComponent("cache.db"))
        try Data(repeating: 2, count: 4096).write(to: orphanCache.appendingPathComponent("cache.db"))
        try Data(repeating: 3, count: 4096).write(to: orphanSupport.appendingPathComponent("prefs.json"))

        let config = ScanConfiguration(
            roots: [sandbox],
            downloadsOverride: sandbox.appendingPathComponent("Downloads"),
            libraryOverride: lib,
            appSearchRootsOverride: [appsRoot],
            categories: [.deadFiles]
        )
        let coordinator = ScanCoordinator(safetyGuard: SafetyGuard(currentUserHome: sandbox))
        let outcome = await coordinator.runFullScan(configuration: config)
        let dead = outcome.items(in: .deadFiles)

        #expect(dead.contains(where: { $0.url == orphanCache.standardizedFileURL && $0.risk.level == .low }))
        #expect(dead.contains(where: { $0.url == orphanSupport.standardizedFileURL && $0.risk.level == .moderate }))
        #expect(!dead.contains(where: { $0.url == keptCache.standardizedFileURL }))
    }

    @Test("Hard-linked identical paths are not falsely flagged as duplicates")
    func hardLinkedFilesAreDeduplicatedDuringScan() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let original = sandbox.appendingPathComponent("original.bin")
        let hardLink = sandbox.appendingPathComponent("hardlink.bin")
        try Data(repeating: 0x5A, count: 8192).write(to: original)
        try FileManager.default.linkItem(at: original, to: hardLink)

        let config = ScanConfiguration(
            roots: [sandbox],
            categories: [.duplicates],
            minDuplicateBytes: 1024
        )
        let coordinator = ScanCoordinator(safetyGuard: SafetyGuard(currentUserHome: sandbox))
        let outcome = await coordinator.runFullScan(configuration: config)

        #expect(outcome.duplicateGroups.isEmpty)
    }

    @Test("Trash move records history receipt and safely restores file to original path")
    func trashAndRestoreRoundTrip() async throws {
        let sandbox = try makeSandbox()
        let fakeTrash = sandbox.appendingPathComponent(".TestTrash", isDirectory: true)
        let historyFile = sandbox.appendingPathComponent("history.json")
        defer { try? FileManager.default.removeItem(at: sandbox) }
        try FileManager.default.createDirectory(at: fakeTrash, withIntermediateDirectories: true)

        let file = sandbox.appendingPathComponent("note.md")
        try Data("important".utf8).write(to: file)

        let item = ScannedItem(url: file, name: "note.md", logicalSize: 9, allocatedSize: 4096, isDirectory: false, category: .oldFiles)
        let executor = DeletionExecutor(
            safetyGuard: SafetyGuard(currentUserHome: sandbox),
            trashDriver: DirectoryTrashDriver(trashDirectory: fakeTrash)
        )
        let store = CleanHistoryStore(fileURL: historyFile)

        let report = try await executor.execute(items: [item], mode: .moveToTrash, dryRun: false)
        await store.append(report.trashHistoryEntries)
        #expect(!FileManager.default.fileExists(atPath: file.path))

        let saved = await store.loadEntries()
        #expect(saved.count == 1)

        let restoreResult = await executor.restore(entries: saved)
        #expect(restoreResult.restoredIDs == Set(saved.map(\.id)))
        #expect(restoreResult.failures.isEmpty)
        #expect(FileManager.default.fileExists(atPath: file.path))

        await store.remove(ids: restoreResult.restoredIDs)
        #expect((await store.loadEntries()).isEmpty)
    }

    @Test("Deletion blocks TOCTOU symlink pointing into protected /System directory")
    func deletionBlocksSymlinkEscapeAtExecutionTime() async throws {
        let sandbox = try makeSandbox()
        let fakeTrash = sandbox.appendingPathComponent(".TestTrash", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }
        try FileManager.default.createDirectory(at: fakeTrash, withIntermediateDirectories: true)

        let trapLink = sandbox.appendingPathComponent("innocent.txt")
        try FileManager.default.createSymbolicLink(
            atPath: trapLink.path,
            withDestinationPath: "/System/Library/CoreServices/Finder.app"
        )

        let item = ScannedItem(url: trapLink, name: "innocent.txt", logicalSize: 100, allocatedSize: 100, isDirectory: false, category: .deadFiles)
        let executor = DeletionExecutor(
            safetyGuard: SafetyGuard(currentUserHome: sandbox),
            trashDriver: DirectoryTrashDriver(trashDirectory: fakeTrash)
        )

        let report = try await executor.execute(items: [item], mode: .moveToTrash, dryRun: false)
        #expect(report.succeededCount == 0)
        #expect(report.failures.count == 1)
    }

    @Test("Dry-run preserves files while Trash sink moves and Permanent Delete erases")
    func dryRunTrashAndPermanentDeleteBehavior() async throws {
        let sandbox = try makeSandbox()
        let fakeTrash = sandbox.appendingPathComponent(".TestTrash", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }
        try FileManager.default.createDirectory(at: fakeTrash, withIntermediateDirectories: true)

        let fileA = sandbox.appendingPathComponent("a.log")
        let fileB = sandbox.appendingPathComponent("b.log")
        try Data("alpha".utf8).write(to: fileA)
        try Data("beta".utf8).write(to: fileB)

        let itemA = ScannedItem(url: fileA, name: "a.log", logicalSize: 5, allocatedSize: 4096, isDirectory: false, category: .deadFiles)
        let itemB = ScannedItem(url: fileB, name: "b.log", logicalSize: 4, allocatedSize: 4096, isDirectory: false, category: .deadFiles)

        let safety = SafetyGuard(currentUserHome: sandbox)
        let executor = DeletionExecutor(
            safetyGuard: safety,
            trashDriver: DirectoryTrashDriver(trashDirectory: fakeTrash)
        )

        let dryReport = try await executor.execute(
            items: [itemA, itemB],
            mode: .moveToTrash,
            dryRun: true
        )
        #expect(dryReport.isDryRun == true)
        #expect(dryReport.succeededCount == 2)
        #expect(FileManager.default.fileExists(atPath: fileA.path))
        #expect(FileManager.default.fileExists(atPath: fileB.path))

        let trashReport = try await executor.execute(
            items: [itemA],
            mode: .moveToTrash,
            dryRun: false
        )
        #expect(trashReport.succeededCount == 1)
        #expect(!FileManager.default.fileExists(atPath: fileA.path))
        #expect(FileManager.default.fileExists(atPath: fakeTrash.appendingPathComponent("a.log").path))

        let deleteReport = try await executor.execute(
            items: [itemB],
            mode: .permanentDelete(confirmed: true),
            dryRun: false
        )
        #expect(deleteReport.succeededCount == 1)
        #expect(!FileManager.default.fileExists(atPath: fileB.path))
    }

    @Test("Refuses deletion of files carrying user immutable flag")
    func blocksImmutableLockedFilesDuringDeletion() async throws {
        let sandbox = try makeSandbox()
        let fakeTrash = sandbox.appendingPathComponent(".TestTrash", isDirectory: true)
        try FileManager.default.createDirectory(at: fakeTrash, withIntermediateDirectories: true)

        let locked = sandbox.appendingPathComponent("locked.txt")
        try Data("immutable".utf8).write(to: locked)
        #expect(chflags(locked.path, UInt32(UF_IMMUTABLE)) == 0)
        defer {
            _ = chflags(locked.path, 0)
            try? FileManager.default.removeItem(at: sandbox)
        }

        let item = ScannedItem(url: locked, name: "locked.txt", logicalSize: 9, allocatedSize: 4096, isDirectory: false, category: .oldFiles)
        let executor = DeletionExecutor(
            safetyGuard: SafetyGuard(currentUserHome: sandbox),
            trashDriver: DirectoryTrashDriver(trashDirectory: fakeTrash)
        )
        let report = try await executor.execute(items: [item], mode: .moveToTrash, dryRun: false)
        #expect(report.succeededCount == 0)
        #expect(report.failures.count == 1)
        #expect(FileManager.default.fileExists(atPath: locked.path))
    }

    @Test("Scans stale third-party caches while sparing fresh caches, Apple caches, and Library internals")
    func scansStaleCachesAndIsolatesUserLibraryWalk() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let appsRoot = sandbox.appendingPathComponent("Applications", isDirectory: true)
        let installedContents = appsRoot.appendingPathComponent("KeepApp.app/Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: installedContents, withIntermediateDirectories: true)
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict><key>CFBundleIdentifier</key><string>com.example.KeepApp</string></dict></plist>
        """
        try Data(plist.utf8).write(to: installedContents.appendingPathComponent("Info.plist"))

        let lib = sandbox.appendingPathComponent("Library", isDirectory: true)
        let staleCacheDir = lib.appendingPathComponent("Caches/com.example.KeepApp", isDirectory: true)
        let freshCacheDir = lib.appendingPathComponent("Caches/com.example.FreshApp", isDirectory: true)
        let appleCacheDir = lib.appendingPathComponent("Caches/com.apple.Safari", isDirectory: true)
        let prefsDir = lib.appendingPathComponent("Preferences", isDirectory: true)
        let docsDir = sandbox.appendingPathComponent("Documents", isDirectory: true)

        try FileManager.default.createDirectory(at: staleCacheDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: freshCacheDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: appleCacheDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: prefsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: docsDir, withIntermediateDirectories: true)

        let staleDate = Date().addingTimeInterval(-45 * 24 * 3600)
        let staleFile = staleCacheDir.appendingPathComponent("old.cache")
        try Data(repeating: 0x22, count: 16_384).write(to: staleFile)
        try FileManager.default.setAttributes([.modificationDate: staleDate], ofItemAtPath: staleFile.path)
        try FileManager.default.setAttributes([.modificationDate: staleDate], ofItemAtPath: staleCacheDir.path)

        let freshFile = freshCacheDir.appendingPathComponent("hot.cache")
        try Data(repeating: 0x33, count: 16_384).write(to: freshFile)

        let appleFile = appleCacheDir.appendingPathComponent("apple.cache")
        try Data(repeating: 0x44, count: 16_384).write(to: appleFile)
        try FileManager.default.setAttributes([.modificationDate: staleDate], ofItemAtPath: appleFile.path)
        try FileManager.default.setAttributes([.modificationDate: staleDate], ofItemAtPath: appleCacheDir.path)

        let prefPlist = prefsDir.appendingPathComponent("com.example.KeepApp.plist")
        try Data(repeating: 0x55, count: 16_384).write(to: prefPlist)
        try FileManager.default.setAttributes([.modificationDate: staleDate], ofItemAtPath: prefPlist.path)

        let docOld = docsDir.appendingPathComponent("archive.tar")
        try Data(repeating: 0x66, count: 16_384).write(to: docOld)
        try FileManager.default.setAttributes([.modificationDate: staleDate], ofItemAtPath: docOld.path)

        // Add KeepApp fresh ID too so FreshApp isn't flagged as orphan
        let freshContents = appsRoot.appendingPathComponent("FreshApp.app/Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: freshContents, withIntermediateDirectories: true)
        let freshPlist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict><key>CFBundleIdentifier</key><string>com.example.FreshApp</string></dict></plist>
        """
        try Data(freshPlist.utf8).write(to: freshContents.appendingPathComponent("Info.plist"))

        let config = ScanConfiguration(
            roots: [sandbox],
            downloadsOverride: sandbox.appendingPathComponent("Downloads"),
            libraryOverride: lib,
            appSearchRootsOverride: [appsRoot],
            categories: [.largeFiles, .oldFiles, .deadFiles],
            largeFileThresholdBytes: 8_192,
            oldFileThresholdDays: 30
        )
        let coordinator = ScanCoordinator(safetyGuard: SafetyGuard(currentUserHome: sandbox))
        let outcome = await coordinator.runFullScan(configuration: config)

        let dead = outcome.items(in: .deadFiles)
        let hasStale = dead.contains {
            $0.url == staleCacheDir.standardizedFileURL && $0.deadKind == .staleCache && $0.risk.level == .low
        }
        let hasFresh = dead.contains { $0.url == freshCacheDir.standardizedFileURL }
        let hasApple = dead.contains { $0.url == appleCacheDir.standardizedFileURL }
        #expect(hasStale)
        #expect(!hasFresh)
        #expect(!hasApple)

        // Library internals should not pollute Large/Old user files when scanning $HOME
        let largeURLs = Set(outcome.items(in: .largeFiles).map(\.url))
        let oldURLs = Set(outcome.items(in: .oldFiles).map(\.url))
        #expect(largeURLs.contains(docOld.standardizedFileURL))
        #expect(!largeURLs.contains(prefPlist.standardizedFileURL))
        #expect(oldURLs.contains(docOld.standardizedFileURL))
        #expect(!oldURLs.contains(prefPlist.standardizedFileURL))
    }

    @Test("Discovers heavy active caches, developer caches, container media, and total scanned bytes")
    func scansActiveCachesDeveloperCachesAndLargeContainerBlobs() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let appsRoot = sandbox.appendingPathComponent("Applications", isDirectory: true)
        let installedContents = appsRoot.appendingPathComponent("KeepApp.app/Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: installedContents, withIntermediateDirectories: true)
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict><key>CFBundleIdentifier</key><string>com.example.KeepApp</string></dict></plist>
        """
        try Data(plist.utf8).write(to: installedContents.appendingPathComponent("Info.plist"))

        let lib = sandbox.appendingPathComponent("Library", isDirectory: true)
        let heavyActiveCache = lib.appendingPathComponent("Caches/com.example.KeepApp", isDirectory: true)
        let appleCache = lib.appendingPathComponent("Caches/com.apple.SystemCache", isDirectory: true)
        let npmCache = sandbox.appendingPathComponent(".npm/_cacache", isDirectory: true)
        let derivedData = lib.appendingPathComponent("Developer/Xcode/DerivedData/SampleApp", isDirectory: true)
        let containerDocs = lib.appendingPathComponent("Containers/com.example.Vlog/Data/Documents", isDirectory: true)
        let containerPrefs = lib.appendingPathComponent("Containers/com.example.Vlog/Data/Library/Preferences", isDirectory: true)
        let appSupport = lib.appendingPathComponent("Application Support/com.example.KeepApp", isDirectory: true)

        for dir in [heavyActiveCache, appleCache, npmCache, derivedData, containerDocs, containerPrefs, appSupport] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        let payload = Data(repeating: 0x7A, count: 24_576)
        try payload.write(to: heavyActiveCache.appendingPathComponent("cache.bin"))
        try payload.write(to: appleCache.appendingPathComponent("sys.bin"))
        try payload.write(to: npmCache.appendingPathComponent("pkg.tgz"))
        try payload.write(to: derivedData.appendingPathComponent("Derived.o"))

        let bigVideo = containerDocs.appendingPathComponent("render.mov")
        let duplicateVideo = sandbox.appendingPathComponent("render-dup.mov")
        let bigModel = appSupport.appendingPathComponent("weights.bin")
        let prefBlob = containerPrefs.appendingPathComponent("prefs.plist")
        let staleDate = Date().addingTimeInterval(-60 * 24 * 3600)

        for u in [bigVideo, duplicateVideo, bigModel, prefBlob] {
            try payload.write(to: u)
            try FileManager.default.setAttributes([.modificationDate: staleDate], ofItemAtPath: u.path)
        }

        let config = ScanConfiguration(
            roots: [sandbox],
            downloadsOverride: sandbox.appendingPathComponent("Downloads"),
            libraryOverride: lib,
            appSearchRootsOverride: [appsRoot],
            homeOverride: sandbox,
            categories: Set(ScanCategory.allCases),
            minDuplicateBytes: 4_096,
            largeFileThresholdBytes: 16_384,
            oldFileThresholdDays: 30,
            minimumActiveCacheBytes: 16_384
        )
        let coordinator = ScanCoordinator(safetyGuard: SafetyGuard(currentUserHome: sandbox))
        let outcome = await coordinator.runFullScan(configuration: config)

        let dead = outcome.items(in: .deadFiles)
        let foundHeavyCache = dead.contains { $0.url == heavyActiveCache.standardizedFileURL && $0.deadKind == .staleCache }
        let foundAppleCache = dead.contains { $0.url == appleCache.standardizedFileURL }
        let foundNpm = dead.contains { $0.url == npmCache.standardizedFileURL && $0.deadKind == .developerCache }
        let foundDerived = dead.contains { $0.url == derivedData.deletingLastPathComponent().standardizedFileURL && $0.deadKind == .developerCache }
        #expect(foundHeavyCache)
        #expect(!foundAppleCache)
        #expect(foundNpm)
        #expect(foundDerived)

        let largeURLs = Set(outcome.items(in: .largeFiles).map(\.url))
        let oldURLs = Set(outcome.items(in: .oldFiles).map(\.url))
        #expect(largeURLs.contains(bigVideo.standardizedFileURL))
        #expect(largeURLs.contains(bigModel.standardizedFileURL))
        #expect(!largeURLs.contains(prefBlob.standardizedFileURL))

        // Container / Application Support files are surfaced under Large Files with context, not polluted into Old/Duplicates
        #expect(!oldURLs.contains(bigVideo.standardizedFileURL))
        #expect(outcome.duplicateGroups.isEmpty)
        #expect(outcome.progress.bytesEvaluated >= 70_000)

        let volume = FilesystemProbes.volumeStorageSnapshot(for: sandbox)
        #expect(volume != nil)
        #expect((volume?.totalBytes ?? 0) > 0)
    }

    @Test("Measures sparse files by allocated disk blocks and avoids double-counting walked orphan folders")
    func sparseFileAndNonDoubleCountedProgressTest() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let appsRoot = sandbox.appendingPathComponent("Applications", isDirectory: true)
        try FileManager.default.createDirectory(at: appsRoot, withIntermediateDirectories: true)
        let dummyApp = appsRoot.appendingPathComponent("Dummy.app/Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: dummyApp, withIntermediateDirectories: true)
        let dummyPlist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict><key>CFBundleIdentifier</key><string>com.example.Dummy</string></dict></plist>
        """
        try Data(dummyPlist.utf8).write(to: dummyApp.appendingPathComponent("Info.plist"))

        let containerData = sandbox.appendingPathComponent("Library/Containers/com.docker.docker/Data", isDirectory: true)
        let orphanAppSupport = sandbox.appendingPathComponent("Library/Application Support/com.example.RemovedApp", isDirectory: true)
        let libCaches = sandbox.appendingPathComponent("Library/Caches/com.example.HeavyCache", isDirectory: true)
        for dir in [containerData, orphanAppSupport, libCaches] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        // Create a 40 MB sparse file whose real APFS allocated block usage is tiny (4 KiB)
        let sparseURL = containerData.appendingPathComponent("Docker.raw")
        FileManager.default.createFile(atPath: sparseURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: sparseURL)
        try handle.truncate(atOffset: 40_000_000)
        try handle.write(contentsOf: Data(repeating: 0x11, count: 4096))
        try handle.close()

        // Create 20 KB inside Application Support orphan (walked) and 20 KB inside Caches (skipped by walker)
        let orphanPayload = Data(repeating: 0x22, count: 20_000)
        try orphanPayload.write(to: orphanAppSupport.appendingPathComponent("orphan.db"))
        let cachePayload = Data(repeating: 0x33, count: 20_000)
        try cachePayload.write(to: libCaches.appendingPathComponent("cache.bin"))

        let config = ScanConfiguration(
            roots: [sandbox],
            downloadsOverride: sandbox.appendingPathComponent("Downloads"),
            libraryOverride: sandbox.appendingPathComponent("Library"),
            appSearchRootsOverride: [appsRoot],
            homeOverride: sandbox,
            categories: [.largeFiles, .deadFiles],
            largeFileThresholdBytes: 1_000_000,
            minimumActiveCacheBytes: 16_384
        )
        let coordinator = ScanCoordinator(safetyGuard: SafetyGuard(currentUserHome: sandbox))
        let outcome = await coordinator.runFullScan(configuration: config)

        let largeURLs = Set(outcome.items(in: .largeFiles).map(\.url))
        #expect(!largeURLs.contains(sparseURL.standardizedFileURL))
        // Walked (~44 KB incl sparse allocated + orphan + dummy Info.plist) + skipped cache (20 KB) must stay well under 200 KB (never 40 MB)
        // OrphanAppSupport (~20 KB) must NOT be double-counted on top of walked bytes
        #expect(outcome.progress.bytesEvaluated < 200_000)
        #expect(outcome.progress.bytesEvaluated < 60_000)
    }

    @Test("Descends into macOS UF_HIDDEN Library directory and discovers .npm/_npx cache")
    func descendsIntoHiddenMacOSLibraryAndNpxCache() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let lib = sandbox.appendingPathComponent("Library", isDirectory: true)
        let containerDocs = lib.appendingPathComponent("Containers/com.example.Vlog/Data/Documents", isDirectory: true)
        let npxCache = sandbox.appendingPathComponent(".npm/_npx/cachedpkg", isDirectory: true)
        try FileManager.default.createDirectory(at: containerDocs, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: npxCache, withIntermediateDirectories: true)

        // Mark Library hidden just like macOS sets UF_HIDDEN on ~/Library
        try (lib as NSURL).setResourceValue(true, forKey: URLResourceKey.isHiddenKey)

        let payload = Data(repeating: 0x4E, count: 24_576)
        let clipURL = containerDocs.appendingPathComponent("draft.mov")
        try payload.write(to: clipURL)
        try payload.write(to: npxCache.appendingPathComponent("bundle.js"))

        let config = ScanConfiguration(
            roots: [sandbox],
            downloadsOverride: sandbox.appendingPathComponent("Downloads"),
            libraryOverride: lib,
            appSearchRootsOverride: [sandbox.appendingPathComponent("Applications")],
            homeOverride: sandbox,
            categories: [.largeFiles, .deadFiles],
            largeFileThresholdBytes: 16_384,
            minimumActiveCacheBytes: 16_384,
            skipHiddenFiles: true
        )
        let coordinator = ScanCoordinator(safetyGuard: SafetyGuard(currentUserHome: sandbox))
        let outcome = await coordinator.runFullScan(configuration: config)

        let largeURLs = Set(outcome.items(in: .largeFiles).map(\.url))
        #expect(largeURLs.contains(clipURL.standardizedFileURL))

        let deadURLs = Set(outcome.items(in: .deadFiles).map(\.url))
        #expect(deadURLs.contains(npxCache.deletingLastPathComponent().standardizedFileURL))
    }

    @Test("Overlapping restart isolates new progress stream from previous cancelled scan")
    func overlappingScanRestartIsolatesProgressStream() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }

        for i in 0..<20 {
            let dir = sandbox.appendingPathComponent("dir-\(i)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data(repeating: 0x1A, count: 4096).write(to: dir.appendingPathComponent("payload.bin"))
        }

        let config = ScanConfiguration(
            roots: [sandbox],
            downloadsOverride: sandbox.appendingPathComponent("Downloads"),
            libraryOverride: sandbox.appendingPathComponent("Library"),
            appSearchRootsOverride: [sandbox.appendingPathComponent("Applications")],
            homeOverride: sandbox,
            categories: [.largeFiles],
            largeFileThresholdBytes: 1024
        )
        let coordinator = ScanCoordinator(
            safetyGuard: SafetyGuard(currentUserHome: sandbox),
            perDirectoryDelay: .milliseconds(5)
        )

        try await coordinator.start(configuration: config)
        try await Task.sleep(for: .milliseconds(12))

        let stream2 = await coordinator.makeProgressStream()
        let stream2PhasesTask = Task<[ScanPhase], Never> {
            var phases: [ScanPhase] = []
            for await batch in stream2 {
                phases.append(batch.progress.phase)
            }
            return phases
        }

        let outcome2 = await coordinator.runFullScan(configuration: config)
        let phases2 = await stream2PhasesTask.value

        #expect(outcome2.wasCancelled == false)
        #expect(outcome2.items(in: .largeFiles).count == 20)
        #expect(!phases2.contains(.cancelled))
        #expect(phases2.last == .completed)
    }

    @Test("Cancelling a paused scan finishes its progress stream with cancelled status")
    func cancelWhilePausedFinishesProgressStream() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }

        for i in 0..<25 {
            let dir = sandbox.appendingPathComponent("folder-\(i)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data(repeating: 0x02, count: 2048).write(to: dir.appendingPathComponent("item.dat"))
        }

        let config = ScanConfiguration(roots: [sandbox], categories: [.largeFiles], largeFileThresholdBytes: 512)
        let coordinator = ScanCoordinator(
            safetyGuard: SafetyGuard(currentUserHome: sandbox),
            perDirectoryDelay: .milliseconds(15)
        )

        let stream = await coordinator.makeProgressStream()
        let (enteredSignalStream, enteredContinuation) = AsyncStream.makeStream(of: Void.self)
        let streamTask = Task<[ScanPhase], Never> {
            var phases: [ScanPhase] = []
            var signaled = false
            for await batch in stream {
                phases.append(batch.progress.phase)
                if !signaled && batch.progress.phase == .enumerating {
                    signaled = true
                    enteredContinuation.yield(())
                    enteredContinuation.finish()
                }
            }
            enteredContinuation.finish()
            return phases
        }

        try await coordinator.start(configuration: config)
        for await _ in enteredSignalStream { break }
        let checkpoint = await coordinator.pause()
        #expect(!checkpoint.pendingDirectories.isEmpty)

        let outcome = await coordinator.cancel()
        let phases = await streamTask.value
        #expect(outcome.wasCancelled == true)
        #expect(phases.contains(.paused))
        #expect(phases.last == .cancelled)
    }
}

