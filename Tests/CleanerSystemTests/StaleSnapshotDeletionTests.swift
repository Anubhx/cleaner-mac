import Testing
import Foundation
@testable import CleanerCore
@testable import CleanerSystem

@Suite("DeletionExecutor Stale Snapshot Guard & Real-Disk Verification")
struct StaleSnapshotDeletionTests {
    private func makeSandbox() throws -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("StaleSnapshotTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    private func createSampleFile(at url: URL, contents: Data, modifiedDate: Date) throws -> ScannedItem {
        try contents.write(to: url)
        try FileManager.default.setAttributes([.modificationDate: modifiedDate], ofItemAtPath: url.path)
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .fileAllocatedSizeKey, .contentModificationDateKey])
        let logical = UInt64(values.fileSize ?? contents.count)
        let allocated = UInt64(values.fileAllocatedSize ?? contents.count)
        let inode = FilesystemProbes.inodeIdentity(for: url)
        return ScannedItem(
            url: url,
            name: url.lastPathComponent,
            logicalSize: logical,
            allocatedSize: allocated,
            isDirectory: false,
            modifiedDate: values.contentModificationDate ?? modifiedDate,
            category: .largeFiles,
            inode: inode
        )
    }

    private func makeExecutor(sandbox: URL, trashDir: URL) -> DeletionExecutor {
        DeletionExecutor(
            safetyGuard: SafetyGuard(currentUserHome: sandbox),
            trashDriver: DirectoryTrashDriver(trashDirectory: trashDir)
        )
    }

    @Test("1. Unchanged file from persisted ISO-8601 snapshot passes check and deletes normally")
    func unchangedSnapshotItemDeletesNormally() async throws {
        let sandbox = try makeSandbox()
        let trashDir = sandbox.appendingPathComponent(".Trash", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }
        try FileManager.default.createDirectory(at: trashDir, withIntermediateDirectories: true)

        let target = sandbox.appendingPathComponent("old-installer.dmg")
        try Data(repeating: 0x11, count: 16_384).write(to: target)

        // Run a real ScanCoordinator scan, persist via ScanSnapshotStore (.iso8601), reload from disk
        let config = ScanConfiguration(
            roots: [sandbox],
            categories: [.largeFiles],
            largeFileThresholdBytes: 4_096
        )
        let coordinator = ScanCoordinator(safetyGuard: SafetyGuard(currentUserHome: sandbox))
        let outcome = await coordinator.runFullScan(configuration: config)
        let scannedItem = try #require(outcome.items(in: .largeFiles).first(where: { $0.url == target.standardizedFileURL }))
        #expect(scannedItem.inode != nil)

        let snapshotURL = sandbox.appendingPathComponent("session/last-scan.json")
        let snapshotStore = ScanSnapshotStore(fileURL: snapshotURL)
        let snapshot = ScanSnapshot(
            startedAt: Date().addingTimeInterval(-10),
            finishedAt: Date(),
            duration: 10,
            appVersion: "1.0.0",
            configuration: config,
            progress: outcome.progress,
            categories: [CategorySnapshot(category: .largeFiles, items: [scannedItem])],
            duplicateGroups: [],
            totalReclaimableBytes: scannedItem.reclaimableDiskBytes
        )
        try await snapshotStore.save(snapshot)

        let reloadedSnapshot = try #require(await snapshotStore.load())
        let persistedItem = try #require(reloadedSnapshot.categories.first?.items.first)

        let executor = makeExecutor(sandbox: sandbox, trashDir: trashDir)
        let report = try await executor.execute(
            items: [persistedItem],
            mode: .moveToTrash,
            dryRun: false,
            verifySnapshotItems: true
        )

        #expect(report.succeededItems.map(\.url) == [target.standardizedFileURL])
        #expect(report.blockedItems.isEmpty)
        #expect(report.failures.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: target.path))
    }

    @Test("2. File deleted externally since scan is marked missing, does not crash, and is not silently skipped")
    func externallyDeletedFileIsMarkedMissingWithMessage() async throws {
        let sandbox = try makeSandbox()
        let trashDir = sandbox.appendingPathComponent(".Trash", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }
        try FileManager.default.createDirectory(at: trashDir, withIntermediateDirectories: true)

        let target = sandbox.appendingPathComponent("already-gone.log")
        let mtime = Date(timeIntervalSince1970: 1_700_000_000)
        let item = try createSampleFile(at: target, contents: Data(repeating: 0xAA, count: 8192), modifiedDate: mtime)

        try FileManager.default.removeItem(at: target)

        let executor = makeExecutor(sandbox: sandbox, trashDir: trashDir)
        let report = try await executor.execute(
            items: [item],
            mode: .moveToTrash,
            dryRun: false,
            verifySnapshotItems: true
        )

        #expect(report.succeededCount == 0)
        #expect(report.blockedItems.count == 1)
        let blocked = try #require(report.blockedItems.first)
        #expect(blocked.url == item.url)
        #expect(blocked.verificationStatus == .missing)
        #expect(!blocked.reason.isEmpty)
        #expect(blocked.reason.localizedCaseInsensitiveContains("missing"))
    }

    @Test("3. File replaced at same path (different inode/size/mtime) is blocked with required message and NOT deleted")
    func replacedAndModifiedFileAtSamePathIsBlocked() async throws {
        let sandbox = try makeSandbox()
        let trashDir = sandbox.appendingPathComponent(".Trash", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }
        try FileManager.default.createDirectory(at: trashDir, withIntermediateDirectories: true)

        let target = sandbox.appendingPathComponent("important-asset.dat")
        let oldMtime = Date(timeIntervalSince1970: 1_700_000_000)
        let recordedItem = try createSampleFile(at: target, contents: Data(repeating: 0x01, count: 4096), modifiedDate: oldMtime)

        // Replace at the same path via remove + recreate with new content & newer mtime -> new inode + new size + new mtime
        try FileManager.default.removeItem(at: target)
        let replacementData = Data(repeating: 0xFE, count: 6000)
        try replacementData.write(to: target)
        try FileManager.default.setAttributes([.modificationDate: oldMtime.addingTimeInterval(300)], ofItemAtPath: target.path)

        let executor = makeExecutor(sandbox: sandbox, trashDir: trashDir)
        let report = try await executor.execute(
            items: [recordedItem],
            mode: .permanentDelete(confirmed: true),
            dryRun: false,
            verifySnapshotItems: true
        )

        #expect(report.succeededCount == 0)
        #expect(report.blockedItems.count == 1)
        let blocked = try #require(report.blockedItems.first)
        #expect(blocked.url == recordedItem.url)
        #expect(blocked.reason == "This file changed since the scan. Rescan before removing it.")
        #expect(FileManager.default.fileExists(atPath: target.path))
        #expect(try Data(contentsOf: target) == replacementData)
    }

    @Test("4. Path now a symlink where it was previously a regular file is blocked")
    func pathReplacedWithSymlinkIsBlocked() async throws {
        let sandbox = try makeSandbox()
        let trashDir = sandbox.appendingPathComponent(".Trash", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }
        try FileManager.default.createDirectory(at: trashDir, withIntermediateDirectories: true)

        let precious = sandbox.appendingPathComponent("precious-target.txt")
        try Data("do not touch".utf8).write(to: precious)

        let pathURL = sandbox.appendingPathComponent("cache-blob.bin")
        let recordedItem = try createSampleFile(
            at: pathURL,
            contents: Data(repeating: 0x33, count: 4096),
            modifiedDate: Date(timeIntervalSince1970: 1_700_000_000)
        )

        // Attacker swaps regular file for symlink inside sandbox
        try FileManager.default.removeItem(at: pathURL)
        try FileManager.default.createSymbolicLink(at: pathURL, withDestinationURL: precious)

        let executor = makeExecutor(sandbox: sandbox, trashDir: trashDir)
        let report = try await executor.execute(
            items: [recordedItem],
            mode: .moveToTrash,
            dryRun: false,
            verifySnapshotItems: true
        )

        #expect(report.succeededCount == 0)
        #expect(report.blockedItems.count == 1)
        let blocked = try #require(report.blockedItems.first)
        #expect(blocked.url == recordedItem.url)
        #expect(blocked.reason == "This file changed since the scan. Rescan before removing it.")
        #expect(FileManager.default.fileExists(atPath: precious.path))
    }

    @Test("5. Batch deletion with 5 items where 1 is stale deletes exactly 4 and blocks and reports only the 1 stale item")
    func fiveItemBatchDeletesFourAndBlocksOneStale() async throws {
        let sandbox = try makeSandbox()
        let trashDir = sandbox.appendingPathComponent(".Trash", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }
        try FileManager.default.createDirectory(at: trashDir, withIntermediateDirectories: true)

        let mtime = Date(timeIntervalSince1970: 1_700_000_000)
        var items: [ScannedItem] = []
        for idx in 0..<5 {
            let url = sandbox.appendingPathComponent("batch-\(idx).bin")
            let item = try createSampleFile(at: url, contents: Data(repeating: UInt8(idx + 1), count: 4096), modifiedDate: mtime)
            items.append(item)
        }

        // Modify item #3 in place (same inode or different inode, modified mtime + size)
        let staleURL = items[3].url
        let updatedData = Data("updated-after-scan-must-keep".utf8)
        try updatedData.write(to: staleURL)
        try FileManager.default.setAttributes([.modificationDate: mtime.addingTimeInterval(120)], ofItemAtPath: staleURL.path)

        let executor = makeExecutor(sandbox: sandbox, trashDir: trashDir)
        let report = try await executor.execute(
            items: items,
            mode: .moveToTrash,
            dryRun: false,
            verifySnapshotItems: true
        )

        #expect(report.succeededCount == 4)
        #expect(report.blockedItems.count == 1)
        #expect(report.failures.isEmpty)
        let blocked = try #require(report.blockedItems.first)
        #expect(blocked.url == staleURL)
        #expect(blocked.reason == "This file changed since the scan. Rescan before removing it.")

        for idx in [0, 1, 2, 4] {
            #expect(!FileManager.default.fileExists(atPath: items[idx].url.path))
        }
        #expect(FileManager.default.fileExists(atPath: staleURL.path))
        #expect(try Data(contentsOf: staleURL) == updatedData)
    }

    @Test("Re-verify helper lstats every snapshot item and classifies unchanged, modified, missing, and replaced")
    func verifySnapshotItemsClassifiesAllFourStates() async throws {
        let sandbox = try makeSandbox()
        let trashDir = sandbox.appendingPathComponent(".Trash", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }
        try FileManager.default.createDirectory(at: trashDir, withIntermediateDirectories: true)

        let mtime = Date(timeIntervalSince1970: 1_700_000_000)
        let unchangedItem = try createSampleFile(at: sandbox.appendingPathComponent("u.dat"), contents: Data(repeating: 1, count: 100), modifiedDate: mtime)
        let modifiedItem = try createSampleFile(at: sandbox.appendingPathComponent("m.dat"), contents: Data(repeating: 2, count: 100), modifiedDate: mtime)
        let missingItem = try createSampleFile(at: sandbox.appendingPathComponent("x.dat"), contents: Data(repeating: 3, count: 100), modifiedDate: mtime)
        let replacedItem = try createSampleFile(at: sandbox.appendingPathComponent("r.dat"), contents: Data(repeating: 4, count: 100), modifiedDate: mtime)

        // Modify m.dat in place (same inode, different size/mtime)
        let handle = try FileHandle(forWritingTo: modifiedItem.url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data([9, 9, 9]))
        try handle.close()
        try FileManager.default.setAttributes([.modificationDate: mtime.addingTimeInterval(60)], ofItemAtPath: modifiedItem.url.path)

        // Delete x.dat externally
        try FileManager.default.removeItem(at: missingItem.url)

        // Replace r.dat at same path with new inode
        try FileManager.default.removeItem(at: replacedItem.url)
        try Data(repeating: 4, count: 100).write(to: replacedItem.url)
        try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: replacedItem.url.path)

        let executor = makeExecutor(sandbox: sandbox, trashDir: trashDir)
        let statuses = await executor.verifySnapshotItems([unchangedItem, modifiedItem, missingItem, replacedItem])

        #expect(statuses[unchangedItem.id] == .unchanged)
        #expect(statuses[modifiedItem.id] == .modified)
        #expect(statuses[missingItem.id] == .missing)
        #expect(statuses[replacedItem.id] == .replaced)
    }
}
