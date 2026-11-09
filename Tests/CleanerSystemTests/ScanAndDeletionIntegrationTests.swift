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
        var bufferA = Data(repeating: 0xAA, count: size)
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

        let pausedCoordinator = ScanCoordinator(safetyGuard: SafetyGuard(currentUserHome: sandbox))
        try await pausedCoordinator.start(configuration: config)
        try await Task.sleep(for: .milliseconds(5))
        let checkpoint = await pausedCoordinator.pause()
        let resumedOutcome = await pausedCoordinator.resume(from: checkpoint)
        let resumedPaths = Set(resumedOutcome.items(in: .largeFiles).map(\.url.path))

        #expect(resumedPaths == baselinePaths)
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
}

