import Testing
import Foundation
@testable import CleanerCore

@Suite("ScanSnapshot Staleness & Restore Policy")
struct ScanSnapshotPolicyTests {
    private func makeItem(
        path: String,
        name: String? = nil,
        category: ScanCategory = .largeFiles,
        size: UInt64 = 10_485_760,
        createdDate: Date = Date(timeIntervalSince1970: 1_700_000_000),
        inode: InodeIdentity? = nil,
        isRecommendedKeep: Bool = false
    ) -> ScannedItem {
        let resolvedName = name ?? URL(fileURLWithPath: path).lastPathComponent
        return ScannedItem(
            id: UUID(),
            url: URL(fileURLWithPath: path),
            name: resolvedName,
            logicalSize: size,
            allocatedSize: size,
            isDirectory: false,
            modifiedDate: createdDate,
            createdDate: createdDate,
            accessedDate: createdDate,
            category: category,
            deadKind: nil,
            risk: RiskAssessment(level: .low, reason: "Fixture"),
            inode: inode ?? InodeIdentity(device: 1, inode: UInt64(abs(path.hashValue))),
            linkCount: 1,
            isCloudDataless: false,
            contentTypeIdentifier: "public.data",
            isRecommendedKeep: isRecommendedKeep
        )
    }

    @Test("Staleness thresholds classify under 1h as fresh, 1-24h as subtle, and over 24h as stale")
    func stalenessThresholds() {
        #expect(SnapshotStaleness.classify(age: -30) == .fresh)
        #expect(SnapshotStaleness.classify(age: 0) == .fresh)
        #expect(SnapshotStaleness.classify(age: 3_599) == .fresh)

        #expect(SnapshotStaleness.classify(age: 3_600) == .subtle)
        #expect(SnapshotStaleness.classify(age: 12 * 3_600) == .subtle)
        #expect(SnapshotStaleness.classify(age: 86_400) == .subtle)

        #expect(SnapshotStaleness.classify(age: 86_401) == .stale)
        #expect(SnapshotStaleness.classify(age: 48 * 3_600) == .stale)
    }

    @Test("Excludes items from non-existent scan roots and respects path boundary matching")
    func excludesMissingRootItemsWithBoundaryPrecision() {
        let existingRoot = URL(fileURLWithPath: "/tmp/Root2")
        let missingRoot = URL(fileURLWithPath: "/tmp/Root")
        let keepPath = "/tmp/Root2/keep.iso"
        let missingPath = "/tmp/Root/stale.iso"

        let keptItem = makeItem(path: keepPath, category: .largeFiles)
        let missingRootItem = makeItem(path: missingPath, category: .largeFiles)

        let startedAt = Date(timeIntervalSince1970: 1_731_300_000)
        let finishedAt = Date(timeIntervalSince1970: 1_731_300_010)
        let snapshot = ScanSnapshot(
            startedAt: startedAt,
            finishedAt: finishedAt,
            duration: 10,
            appVersion: "1.0.0",
            configuration: ScanConfiguration(roots: [existingRoot, missingRoot]),
            progress: ScanProgress(phase: .completed, startedAt: startedAt),
            categories: [
                CategorySnapshot(category: .largeFiles, items: [keptItem, missingRootItem])
            ],
            duplicateGroups: [],
            totalReclaimableBytes: keptItem.reclaimableDiskBytes + missingRootItem.reclaimableDiskBytes
        )

        let existingPaths: Set<String> = [existingRoot.standardizedFileURL.path, keepPath]
        let restored = ScanSnapshotRestorer.restore(from: snapshot) { url in
            existingPaths.contains(url.standardizedFileURL.path)
        }

        #expect(restored.unavailableRoots == [missingRoot])
        #expect(restored.unavailableItems == [missingRootItem])
        #expect(restored.itemsByCategory[.largeFiles] == [keptItem])
    }

    @Test("Longest-matching missing child root excludes child items even when parent root still exists")
    func excludesMissingNestedRootItemsWhenParentExists() {
        let parentRoot = URL(fileURLWithPath: "/tmp/Workspace")
        let deletedChildRoot = URL(fileURLWithPath: "/tmp/Workspace/ExternalMount")
        let parentFile = "/tmp/Workspace/local.bin"
        let childFile = "/tmp/Workspace/ExternalMount/mounted.bin"

        let parentItem = makeItem(path: parentFile, category: .largeFiles)
        let childItem = makeItem(path: childFile, category: .largeFiles)

        let startedAt = Date(timeIntervalSince1970: 1_731_300_000)
        let snapshot = ScanSnapshot(
            startedAt: startedAt,
            finishedAt: startedAt.addingTimeInterval(5),
            duration: 5,
            appVersion: "1.0.0",
            configuration: ScanConfiguration(roots: [parentRoot, deletedChildRoot]),
            progress: ScanProgress(phase: .completed, startedAt: startedAt),
            categories: [CategorySnapshot(category: .largeFiles, items: [parentItem, childItem])],
            duplicateGroups: [],
            totalReclaimableBytes: parentItem.reclaimableDiskBytes + childItem.reclaimableDiskBytes
        )

        let existingPaths: Set<String> = [parentRoot.standardizedFileURL.path, parentFile]
        let restored = ScanSnapshotRestorer.restore(from: snapshot) { url in
            existingPaths.contains(url.standardizedFileURL.path)
        }

        #expect(restored.unavailableRoots == [deletedChildRoot])
        #expect(restored.unavailableItems == [childItem])
        #expect(restored.itemsByCategory[.largeFiles] == [parentItem])
    }

    @Test("Recomputes Keep Original fresh via DuplicateGrouper and drops orphaned single-copy groups")
    func recomputesKeepOriginalAndDropsOrphanedDuplicateGroup() {
        let root = URL(fileURLWithPath: "/Users/alice")
        let docsCopy = makeItem(
            path: "/Users/alice/Documents/archive.zip",
            category: .duplicates,
            createdDate: Date(timeIntervalSince1970: 1_700_000_000),
            inode: InodeIdentity(device: 1, inode: 101),
            isRecommendedKeep: false
        )
        let downloadsCopy = makeItem(
            path: "/Users/alice/Downloads/archive-copy.zip",
            category: .duplicates,
            createdDate: Date(timeIntervalSince1970: 1_700_000_000),
            inode: InodeIdentity(device: 1, inode: 102),
            isRecommendedKeep: true
        )
        let missingRoot = URL(fileURLWithPath: "/Volumes/Unmounted")
        let orphanSurviving = makeItem(
            path: "/Users/alice/Documents/solo.dmg",
            category: .duplicates,
            inode: InodeIdentity(device: 1, inode: 201),
            isRecommendedKeep: false
        )
        let orphanMissing = makeItem(
            path: "/Volumes/Unmounted/solo.dmg",
            category: .duplicates,
            inode: InodeIdentity(device: 2, inode: 202),
            isRecommendedKeep: true
        )

        // Intentionally construct stale group directly with wrong Keep Original vs current DuplicateGrouper rules
        let stalePrimaryGroup = DuplicateGroup(
            id: "sha256:aaa",
            original: downloadsCopy,
            duplicates: [docsCopy]
        )
        let doomedGroup = DuplicateGroup(
            id: "sha256:bbb",
            original: orphanMissing,
            duplicates: [orphanSurviving]
        )

        let startedAt = Date(timeIntervalSince1970: 1_731_300_000)
        let snapshot = ScanSnapshot(
            startedAt: startedAt,
            finishedAt: startedAt.addingTimeInterval(3),
            duration: 3,
            appVersion: "1.0.0",
            configuration: ScanConfiguration(roots: [root, missingRoot]),
            progress: ScanProgress(phase: .completed, startedAt: startedAt),
            categories: [
                CategorySnapshot(category: .duplicates, items: [downloadsCopy, docsCopy, orphanMissing, orphanSurviving])
            ],
            duplicateGroups: [stalePrimaryGroup, doomedGroup],
            totalReclaimableBytes: docsCopy.reclaimableDiskBytes
        )

        let existingPaths: Set<String> = [
            root.standardizedFileURL.path,
            docsCopy.url.standardizedFileURL.path,
            downloadsCopy.url.standardizedFileURL.path,
            orphanSurviving.url.standardizedFileURL.path
        ]
        let restored = ScanSnapshotRestorer.restore(from: snapshot) { url in
            existingPaths.contains(url.standardizedFileURL.path)
        }

        // Group bbb only has 1 surviving copy after /Volumes/Unmounted is excluded, so it must dissolve
        #expect(restored.unavailableRoots == [missingRoot])
        #expect(restored.unavailableItems.map(\.url) == [orphanMissing.url])
        #expect(restored.duplicateGroups.count == 1)

        // Group aaa must now promote Documents over Downloads per DuplicateGrouper rules
        let group = restored.duplicateGroups[0]
        #expect(group.original.url == docsCopy.url)
        #expect(group.original.isRecommendedKeep == true)
        #expect(group.duplicates.map(\.url) == [downloadsCopy.url])
        #expect(group.duplicates.allSatisfy { !$0.isRecommendedKeep })
        #expect(restored.itemsByCategory[.duplicates]?.map(\.isRecommendedKeep) == [true, false])
    }
}
