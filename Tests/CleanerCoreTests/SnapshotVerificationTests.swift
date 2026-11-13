import Testing
import Foundation
@testable import CleanerCore

@Suite("Snapshot Verification Policy & DeletionPlanner Stale Guard")
struct SnapshotVerificationTests {
    private let guardPolicy = SafetyGuard(currentUserHome: URL(fileURLWithPath: "/Users/alice"))

    private func makeSnapshotItem(
        path: String = "/Users/alice/Downloads/archive.dmg",
        size: UInt64 = 4096,
        modifiedDate: Date = Date(timeIntervalSince1970: 1_700_000_000),
        device: UInt64 = 16_777_234,
        inode: UInt64 = 100_500,
        isDirectory: Bool = false
    ) -> ScannedItem {
        ScannedItem(
            url: URL(fileURLWithPath: path),
            name: URL(fileURLWithPath: path).lastPathComponent,
            logicalSize: size,
            allocatedSize: size,
            isDirectory: isDirectory,
            modifiedDate: modifiedDate,
            category: .largeFiles,
            inode: InodeIdentity(device: device, inode: inode)
        )
    }

    @Test("Unchanged item matches device, inode, size, mtime (including ISO-8601 whole-second truncation), and non-symlink type")
    func unchangedPassesEvenWithISOSubsecondDelta() throws {
        let recordedDate = Date(timeIntervalSince1970: 1_700_000_000) // ISO-8601 encoded/decoded
        let item = makeSnapshotItem(modifiedDate: recordedDate)
        let live = LiveFileStat(
            exists: true,
            isSymlink: false,
            isDirectory: false,
            inode: InodeIdentity(device: 16_777_234, inode: 100_500),
            logicalSize: 4096,
            modifiedDate: Date(timeIntervalSince1970: 1_700_000_000.842)
        )

        #expect(SnapshotVerificationPolicy.verify(item: item, against: live) == .unchanged)
        #expect(SnapshotVerificationPolicy.blockedReason(for: .unchanged) == nil)

        let plan = try DeletionPlanner.plan(
            items: [item],
            mode: .moveToTrash,
            dryRun: false,
            safetyGuard: guardPolicy,
            requireSnapshotVerification: true,
            liveStatProvider: { _ in live }
        )
        #expect(plan.entries.count == 1)
        #expect(plan.blocked.isEmpty)
    }

    @Test("Missing item returns .missing and blocks deletion with explicit missing reason")
    func missingBlocksWithMessage() throws {
        let item = makeSnapshotItem()
        #expect(SnapshotVerificationPolicy.verify(item: item, against: .missing) == .missing)

        let plan = try DeletionPlanner.plan(
            items: [item],
            mode: .moveToTrash,
            dryRun: false,
            safetyGuard: guardPolicy,
            requireSnapshotVerification: true,
            liveStatProvider: { _ in .missing }
        )
        #expect(plan.entries.isEmpty)
        #expect(plan.blocked.count == 1)
        let blocked = try #require(plan.blocked.first)
        #expect(blocked.verificationStatus == .missing)
        #expect(blocked.reason.localizedCaseInsensitiveContains("missing"))
    }

    @Test("Changed inode, size, mtime, or symlink transition blocks item with stale snapshot message")
    func changedMetadataAndSymlinkBlockWithSpecificMessage() throws {
        let item = makeSnapshotItem()
        let baseLive = LiveFileStat(
            exists: true,
            isSymlink: false,
            isDirectory: false,
            inode: item.inode,
            logicalSize: item.logicalSize,
            modifiedDate: item.modifiedDate
        )

        let replacedInode = LiveFileStat(
            exists: true,
            isSymlink: false,
            isDirectory: false,
            inode: InodeIdentity(device: 16_777_234, inode: 999_999),
            logicalSize: item.logicalSize,
            modifiedDate: item.modifiedDate
        )
        #expect(SnapshotVerificationPolicy.verify(item: item, against: replacedInode) == .replaced)

        let diffDevice = LiveFileStat(
            exists: true,
            isSymlink: false,
            isDirectory: false,
            inode: InodeIdentity(device: 99, inode: 100_500),
            logicalSize: item.logicalSize,
            modifiedDate: item.modifiedDate
        )
        #expect(SnapshotVerificationPolicy.verify(item: item, against: diffDevice) == .replaced)

        let symlinkNow = LiveFileStat(
            exists: true,
            isSymlink: true,
            isDirectory: false,
            inode: item.inode,
            logicalSize: item.logicalSize,
            modifiedDate: item.modifiedDate
        )
        #expect(SnapshotVerificationPolicy.verify(item: item, against: symlinkNow) == .replaced)

        let sizeChanged = LiveFileStat(
            exists: true,
            isSymlink: false,
            isDirectory: false,
            inode: item.inode,
            logicalSize: 8192,
            modifiedDate: item.modifiedDate
        )
        #expect(SnapshotVerificationPolicy.verify(item: item, against: sizeChanged) == .modified)

        let mtimeChanged = LiveFileStat(
            exists: true,
            isSymlink: false,
            isDirectory: false,
            inode: item.inode,
            logicalSize: item.logicalSize,
            modifiedDate: item.modifiedDate?.addingTimeInterval(60)
        )
        #expect(SnapshotVerificationPolicy.verify(item: item, against: mtimeChanged) == .modified)

        _ = baseLive

        for (index, staleStat) in [replacedInode, diffDevice, symlinkNow, sizeChanged, mtimeChanged].enumerated() {
            let plan = try DeletionPlanner.plan(
                items: [item],
                mode: .moveToTrash,
                dryRun: false,
                safetyGuard: guardPolicy,
                requireSnapshotVerification: true,
                liveStatProvider: { _ in staleStat }
            )
            #expect(plan.entries.isEmpty, "Case \(index) should not enter execution plan")
            #expect(plan.blocked.count == 1, "Case \(index) should be blocked")
            #expect(
                plan.blocked.first?.reason == "This file changed since the scan. Rescan before removing it.",
                "Case \(index) blocked reason mismatch"
            )
        }
    }

    @Test("Five-item batch with one stale entry plans 4 valid items and blocks only the stale item")
    func fiveItemBatchBlocksOnlyStaleItem() throws {
        let items = (0..<5).map { idx in
            makeSnapshotItem(
                path: "/Users/alice/Downloads/file_\(idx).bin",
                size: 1000 + UInt64(idx),
                inode: UInt64(10 + idx)
            )
        }
        let staleURL = items[2].url

        let plan = try DeletionPlanner.plan(
            items: items,
            mode: .moveToTrash,
            dryRun: false,
            safetyGuard: guardPolicy,
            requireSnapshotVerification: true,
            liveStatProvider: { url in
                guard let match = items.first(where: { $0.url == url }) else {
                    return .missing
                }
                if url == staleURL {
                    return LiveFileStat(
                        exists: true,
                        isSymlink: false,
                        isDirectory: false,
                        inode: InodeIdentity(device: 16_777_234, inode: 777_777),
                        logicalSize: match.logicalSize,
                        modifiedDate: match.modifiedDate
                    )
                }
                return LiveFileStat(
                    exists: true,
                    isSymlink: false,
                    isDirectory: false,
                    inode: match.inode,
                    logicalSize: match.logicalSize,
                    modifiedDate: match.modifiedDate
                )
            }
        )

        #expect(plan.entries.count == 4)
        #expect(plan.blocked.count == 1)
        let blocked = try #require(plan.blocked.first)
        #expect(blocked.url == staleURL)
        #expect(blocked.reason == "This file changed since the scan. Rescan before removing it.")
    }

    @Test("Directory items ignore recursive-vs-lstat size difference, fail closed when inode is missing, and block dir mtime/type changes")
    func directoryItemsAndMissingInodeFailClosed() {
        let dirItem = makeSnapshotItem(
            path: "/Users/alice/Library/Caches/com.example.stale",
            size: 50_000_000, // recursive directory size from scan
            device: 16_777_234,
            inode: 202_020,
            isDirectory: true
        )

        let unchangedDir = LiveFileStat(
            exists: true,
            isSymlink: false,
            isDirectory: true,
            inode: dirItem.inode,
            logicalSize: 64, // lstat st_size of APFS directory metadata
            modifiedDate: dirItem.modifiedDate
        )
        #expect(SnapshotVerificationPolicy.verify(item: dirItem, against: unchangedDir) == .unchanged)

        let mutatedDir = LiveFileStat(
            exists: true,
            isSymlink: false,
            isDirectory: true,
            inode: dirItem.inode,
            logicalSize: 64,
            modifiedDate: dirItem.modifiedDate?.addingTimeInterval(5)
        )
        #expect(SnapshotVerificationPolicy.verify(item: dirItem, against: mutatedDir) == .modified)

        let dirNowRegularFile = LiveFileStat(
            exists: true,
            isSymlink: false,
            isDirectory: false,
            inode: dirItem.inode,
            logicalSize: 64,
            modifiedDate: dirItem.modifiedDate
        )
        #expect(SnapshotVerificationPolicy.verify(item: dirItem, against: dirNowRegularFile) == .replaced)

        let legacyItemMissingInode = ScannedItem(
            url: URL(fileURLWithPath: "/Users/alice/Downloads/legacy.bin"),
            name: "legacy.bin",
            logicalSize: 4096,
            allocatedSize: 4096,
            isDirectory: false,
            modifiedDate: Date(timeIntervalSince1970: 1_700_000_000),
            category: .largeFiles,
            inode: nil
        )
        #expect(SnapshotVerificationPolicy.verify(
            item: legacyItemMissingInode,
            against: LiveFileStat(
                exists: true,
                isSymlink: false,
                isDirectory: false,
                inode: InodeIdentity(device: 1, inode: 1),
                logicalSize: 4096,
                modifiedDate: legacyItemMissingInode.modifiedDate
            )
        ) == .replaced)
    }
}
