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
}

