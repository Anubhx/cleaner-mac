import Testing
import Foundation
@testable import CleanerCore

@Suite("ScanSnapshot Persistence Models")
struct ScanSnapshotTests {
    private func makeConfiguration(
        roots: [URL] = [URL(fileURLWithPath: "/Users/alice/Downloads")],
        excludedFolders: [String] = [".git", "node_modules"]
    ) -> ScanConfiguration {
        ScanConfiguration(
            roots: roots,
            downloadsOverride: URL(fileURLWithPath: "/Users/alice/Downloads"),
            libraryOverride: URL(fileURLWithPath: "/Users/alice/Library"),
            categories: [.duplicates, .largeFiles, .oldFiles, .deadFiles],
            minDuplicateBytes: 1_048_576,
            largeFileThresholdBytes: 52_428_800,
            oldFileThresholdDays: 90,
            minimumActiveCacheBytes: 10_485_760,
            ageBasis: .lastAccessedOrModified,
            excludedFolders: excludedFolders,
            allowAppBundles: false,
            skipHiddenFiles: true
        )
    }

    private func makeSampleItem(
        path: String,
        name: String,
        category: ScanCategory,
        deadKind: DeadFileKind? = nil,
        size: UInt64 = 12_582_912,
        isRecommendedKeep: Bool = false
    ) -> ScannedItem {
        ScannedItem(
            id: UUID(),
            url: URL(fileURLWithPath: path),
            name: name,
            logicalSize: size,
            allocatedSize: size,
            isDirectory: false,
            modifiedDate: Date(timeIntervalSince1970: 1_700_000_000),
            createdDate: Date(timeIntervalSince1970: 1_690_000_000),
            accessedDate: Date(timeIntervalSince1970: 1_700_000_100),
            category: category,
            deadKind: deadKind,
            risk: RiskAssessment(level: .low, reason: "Fixture item"),
            inode: InodeIdentity(device: 16_777_234, inode: 9_876_543),
            linkCount: 1,
            isCloudDataless: false,
            contentTypeIdentifier: "public.data",
            isRecommendedKeep: isRecommendedKeep
        )
    }

    @Test("Round-trip encodes and decodes complete snapshot preserving deterministic category order and excludes transient UI state")
    func roundTripNormalSnapshot() throws {
        let startedAt = Date(timeIntervalSince1970: 1_731_300_000)
        let finishedAt = Date(timeIntervalSince1970: 1_731_300_018)
        let snapshotID = UUID()

        let originalDup = makeSampleItem(
            path: "/Users/alice/Downloads/archive.zip",
            name: "archive.zip",
            category: .duplicates,
            size: 20_971_520,
            isRecommendedKeep: true
        )
        let extraDup = makeSampleItem(
            path: "/Users/alice/Documents/archive-copy.zip",
            name: "archive-copy.zip",
            category: .duplicates,
            size: 20_971_520,
            isRecommendedKeep: false
        )
        let largeItem = makeSampleItem(
            path: "/Users/alice/Downloads/ubuntu.iso",
            name: "ubuntu.iso",
            category: .largeFiles,
            size: 1_073_741_824
        )
        let staleCache = makeSampleItem(
            path: "/Users/alice/Library/Caches/com.example.tool/cache.bin",
            name: "cache.bin",
            category: .deadFiles,
            deadKind: .staleCache,
            size: 62_914_560
        )

        let duplicateGroup = DuplicateGroup(
            id: "sha256:deadbeef",
            original: originalDup,
            duplicates: [extraDup]
        )

        // Reverse order deliberately checks that CategorySnapshot array order is preserved on disk
        let orderedCategories = [
            CategorySnapshot(category: .deadFiles, items: [staleCache]),
            CategorySnapshot(category: .largeFiles, items: [largeItem]),
            CategorySnapshot(category: .duplicates, items: [originalDup, extraDup])
        ]

        let snapshot = ScanSnapshot(
            id: snapshotID,
            startedAt: startedAt,
            finishedAt: finishedAt,
            duration: 18.25,
            appVersion: "1.0.0",
            configuration: makeConfiguration(),
            progress: ScanProgress(
                phase: .completed,
                currentPath: "/Users/alice/Library/Caches",
                scannedFiles: 4_812,
                bytesEvaluated: 9_663_676_416,
                pendingDirectoriesCount: 0,
                skippedProtectedDirectories: 3,
                startedAt: startedAt
            ),
            categories: orderedCategories,
            duplicateGroups: [duplicateGroup],
            totalReclaimableBytes: 20_971_520 + 1_073_741_824 + 62_914_560
        )

        #expect(snapshot.schemaVersion == 1)
        #expect(ScanSnapshot.currentSchemaVersion == 1)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(snapshot)
        let decoded = try JSONDecoder().decode(ScanSnapshot.self, from: data)

        #expect(decoded == snapshot)
        #expect(decoded.categories.map(\.category) == [.deadFiles, .largeFiles, .duplicates])
        #expect(decoded.duplicateGroups == [duplicateGroup])
        #expect(decoded.progress.skippedProtectedDirectories == 3)

        // Confirm no UI-only / transient keys leak into serialized JSON
        let jsonText = try #require(String(data: data, encoding: .utf8))
        for forbiddenKey in [
            "previewPayload",
            "volumeStorage",
            "VolumeStorageSnapshot",
            "checkedIDs",
            "highlightedIDs",
            "isDryRunEnabled"
        ] {
            #expect(!jsonText.contains(forbiddenKey))
        }
    }

    @Test("Preserves Unicode paths, filenames, and excluded folders across Codable round-trip")
    func roundTripUnicodePathsAndFilenames() throws {
        let unicodeRoot = URL(fileURLWithPath: "/Users/anubhav/Desktop/Projets d’été · 日本語 📁")
        let unicodeItemPath = "/Users/anubhav/Downloads/Données_café/スクリーンショット 2026-11-11 🧹.png"
        let unicodeFileName = "スクリーンショット 2026-11-11 🧹.png"
        let unicodeDupPath = "/Users/anubhav/Documents/copie — café☕️/スクリーンショット 2026-11-11 🧹.png"

        let item1 = makeSampleItem(
            path: unicodeItemPath,
            name: unicodeFileName,
            category: .duplicates,
            isRecommendedKeep: true
        )
        let item2 = makeSampleItem(
            path: unicodeDupPath,
            name: unicodeFileName,
            category: .duplicates,
            isRecommendedKeep: false
        )

        let startedAt = Date(timeIntervalSince1970: 1_731_310_000)
        let finishedAt = Date(timeIntervalSince1970: 1_731_310_005)
        let snapshot = ScanSnapshot(
            startedAt: startedAt,
            finishedAt: finishedAt,
            duration: 5.5,
            appVersion: "1.0.0",
            configuration: makeConfiguration(
                roots: [unicodeRoot],
                excludedFolders: ["Архив", "私的フォルダ 🚀"]
            ),
            progress: ScanProgress(
                phase: .completed,
                currentPath: unicodeItemPath,
                scannedFiles: 42,
                bytesEvaluated: 25_165_824,
                pendingDirectoriesCount: 0,
                skippedProtectedDirectories: 0,
                startedAt: startedAt
            ),
            categories: [
                CategorySnapshot(category: .duplicates, items: [item1, item2])
            ],
            duplicateGroups: [
                DuplicateGroup(id: "digest-unicode-🔑", original: item1, duplicates: [item2])
            ],
            totalReclaimableBytes: 12_582_912
        )

        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(ScanSnapshot.self, from: data)

        #expect(decoded == snapshot)
        #expect(decoded.configuration.roots.first?.path == unicodeRoot.standardizedFileURL.path)
        #expect(decoded.configuration.excludedFolders == ["Архив", "私的フォルダ 🚀"])
        #expect(decoded.progress.currentPath == unicodeItemPath)
        #expect(decoded.categories.first?.items.first?.name == unicodeFileName)
        #expect(decoded.categories.first?.items.first?.url.path == URL(fileURLWithPath: unicodeItemPath).standardizedFileURL.path)
        #expect(decoded.duplicateGroups.first?.id == "digest-unicode-🔑")
    }

    @Test("Round-trip encodes and decodes snapshot with empty categories and duplicate groups")
    func roundTripEmptyCategories() throws {
        let startedAt = Date(timeIntervalSince1970: 1_731_320_000)
        let finishedAt = Date(timeIntervalSince1970: 1_731_320_001)

        let snapshot = ScanSnapshot(
            startedAt: startedAt,
            finishedAt: finishedAt,
            duration: 1.0,
            appVersion: "1.0.0",
            configuration: makeConfiguration(),
            progress: ScanProgress(
                phase: .completed,
                currentPath: "",
                scannedFiles: 0,
                bytesEvaluated: 0,
                pendingDirectoriesCount: 0,
                skippedProtectedDirectories: 0,
                startedAt: startedAt
            ),
            categories: [],
            duplicateGroups: [],
            totalReclaimableBytes: 0
        )

        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(ScanSnapshot.self, from: data)

        #expect(decoded == snapshot)
        #expect(decoded.categories.isEmpty)
        #expect(decoded.duplicateGroups.isEmpty)
        #expect(decoded.totalReclaimableBytes == 0)
    }

    @Test("Detects unsupported future schemaVersion 999 cleanly without crashing")
    func detectsUnsupportedSchemaVersionMismatch() throws {
        // Construct a valid JSON snapshot first, then mutate schemaVersion to 999
        let startedAt = Date(timeIntervalSince1970: 1_731_330_000)
        let finishedAt = Date(timeIntervalSince1970: 1_731_330_002)
        let baseline = ScanSnapshot(
            startedAt: startedAt,
            finishedAt: finishedAt,
            duration: 2.0,
            appVersion: "1.0.0",
            configuration: makeConfiguration(),
            progress: ScanProgress(phase: .completed, startedAt: startedAt),
            categories: [],
            duplicateGroups: [],
            totalReclaimableBytes: 0
        )

        let encoded = try JSONEncoder().encode(baseline)
        let rawObject = try JSONSerialization.jsonObject(with: encoded)
        var jsonObject = try #require(rawObject as? [String: Any])
        jsonObject["schemaVersion"] = 999
        let mismatchedData = try JSONSerialization.data(withJSONObject: jsonObject)

        #expect(throws: ScanSnapshotError.unsupportedSchemaVersion(found: 999, supported: 1)) {
            try JSONDecoder().decode(ScanSnapshot.self, from: mismatchedData)
        }

        // Also confirm a future schema payload whose keys differ still reports schemaVersion mismatch first
        let futureMinimalJSON = Data(#"{"schemaVersion": 999, "futureField": true}"#.utf8)
        #expect(throws: ScanSnapshotError.unsupportedSchemaVersion(found: 999, supported: 1)) {
            try JSONDecoder().decode(ScanSnapshot.self, from: futureMinimalJSON)
        }
    }
}
