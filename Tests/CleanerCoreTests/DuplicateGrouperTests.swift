import Testing
import Foundation
@testable import CleanerCore

@Suite("DuplicateGrouper & HardLinkTracker")
struct DuplicateGrouperTests {
    @Test("Groups identical digests, keeps oldest canonical original, marks extras removable")
    func groupsDuplicatesAndSelectsCanonicalOriginal() {
        let older = Date(timeIntervalSince1970: 1_600_000_000)
        let newer = Date(timeIntervalSince1970: 1_700_000_000)

        let itemA = ScannedItem(
            url: URL(fileURLWithPath: "/Users/alice/Documents/photo.raw"),
            name: "photo.raw",
            logicalSize: 5_000_000,
            allocatedSize: 5_000_000,
            isDirectory: false,
            modifiedDate: newer,
            createdDate: older,
            accessedDate: newer,
            category: .duplicates,
            inode: InodeIdentity(device: 1, inode: 101),
            linkCount: 1
        )
        let itemB = ScannedItem(
            url: URL(fileURLWithPath: "/Users/alice/Downloads/photo (1).raw"),
            name: "photo (1).raw",
            logicalSize: 5_000_000,
            allocatedSize: 5_000_000,
            isDirectory: false,
            modifiedDate: newer,
            createdDate: newer,
            accessedDate: newer,
            category: .duplicates,
            inode: InodeIdentity(device: 1, inode: 102),
            linkCount: 1
        )

        let groups = DuplicateGrouper.buildGroups(from: [
            "sha256-abc": [itemB, itemA]
        ])

        #expect(groups.count == 1)
        #expect(groups[0].original.url == itemA.url)
        #expect(groups[0].duplicates.map(\.url) == [itemB.url])
        #expect(groups[0].reclaimableBytes == 5_000_000)
    }

    @Test("Deduplicates hard-linked files sharing device and inode")
    func deduplicatesHardLinks() {
        let sharedInode = InodeIdentity(device: 1, inode: 999)
        let link1 = ScannedItem(
            url: URL(fileURLWithPath: "/Users/alice/Documents/a.bin"),
            name: "a.bin",
            logicalSize: 10_000,
            allocatedSize: 10_000,
            isDirectory: false,
            category: .duplicates,
            inode: sharedInode,
            linkCount: 2
        )
        let link2 = ScannedItem(
            url: URL(fileURLWithPath: "/Users/alice/Documents/b.bin"),
            name: "b.bin",
            logicalSize: 10_000,
            allocatedSize: 10_000,
            isDirectory: false,
            category: .duplicates,
            inode: sharedInode,
            linkCount: 2
        )

        let groups = DuplicateGrouper.buildGroups(from: [
            "sha256-xyz": [link1, link2]
        ])

        #expect(groups.isEmpty)
    }

    @Test("Counts selected bytes once even when file appears across categories")
    func deduplicatesSelectedSizeAcrossCategories() {
        let sharedURL = URL(fileURLWithPath: "/Users/alice/Downloads/archive.iso")
        let largeItem = ScannedItem(
            url: sharedURL,
            name: "archive.iso",
            logicalSize: 2_000_000_000,
            allocatedSize: 2_000_000_000,
            isDirectory: false,
            category: .largeFiles
        )
        let oldItem = ScannedItem(
            url: sharedURL,
            name: "archive.iso",
            logicalSize: 2_000_000_000,
            allocatedSize: 2_000_000_000,
            isDirectory: false,
            category: .oldFiles
        )

        let total = SelectionMetrics.uniqueSelectedBytes(
            items: [largeItem, oldItem],
            selectedIDs: [largeItem.id, oldItem.id]
        )
        #expect(total == 2_000_000_000)
    }
}

