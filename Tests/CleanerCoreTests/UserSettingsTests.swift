import Testing
import Foundation
@testable import CleanerCore

@Suite("UserSettings Model")
struct UserSettingsTests {
    @Test("Round-trip encode and decode preserves all settings deterministically and omits dry-run keys")
    func roundTripPreservesFieldsAndExcludesDryRun() throws {
        let original = UserSettings(
            scanRoots: [
                URL(fileURLWithPath: "/Users/alice/Downloads"),
                URL(fileURLWithPath: "/Users/alice/Dossier_café_🧹")
            ],
            excludedFolders: [".git", "/Users/alice/Secret_日本語"],
            largeFileThresholdBytes: 512 * 1_048_576,
            minDuplicateBytes: 4 * 1_048_576,
            oldFileThresholdDays: 90,
            minimumActiveCacheBytes: 64 * 1_048_576,
            ageBasis: .lastModifiedOnly,
            selectedCategories: [.deadFiles, .largeFiles], // deliberately unordered
            skipHiddenFiles: false,
            allowAppBundles: true,
            lastSelectedCategory: .oldFiles,
            sortOrder: .nameAscending,
            isInspectorVisible: false
        )

        #expect(original.selectedCategories == [.largeFiles, .deadFiles])

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(original)
        let jsonString = try #require(String(data: data, encoding: .utf8))
        #expect(!jsonString.contains("isDryRun"))
        #expect(!jsonString.contains("dryRun"))

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(UserSettings.self, from: data)
        #expect(decoded == original)
    }

    @Test("Schema version mismatch throws typed unsupportedSchemaVersion error")
    func schemaVersionMismatchThrowsTypedError() throws {
        let futureJSON = Data(#"{"schemaVersion": 999}"#.utf8)
        let decoder = JSONDecoder()

        do {
            _ = try decoder.decode(UserSettings.self, from: futureJSON)
            Issue.record("Expected unsupportedSchemaVersion error")
        } catch let error as UserSettingsError {
            #expect(error == .unsupportedSchemaVersion(found: 999, supported: UserSettings.currentSchemaVersion))
        }
    }

    @Test("applying(to:) updates ScanConfiguration fields while preserving internal overrides and falling back safely if empty")
    func applyingPreservesInternalOverridesAndHandlesEmptyFallbacks() {
        let downloadsOverride = URL(fileURLWithPath: "/tmp/test-downloads")
        let libraryOverride = URL(fileURLWithPath: "/tmp/test-library")
        let appSearchOverride = [URL(fileURLWithPath: "/tmp/test-apps")]
        let homeOverride = URL(fileURLWithPath: "/tmp/test-home")
        let existing = ScanConfiguration(
            roots: [URL(fileURLWithPath: "/tmp/initial-root")],
            downloadsOverride: downloadsOverride,
            libraryOverride: libraryOverride,
            appSearchRootsOverride: appSearchOverride,
            homeOverride: homeOverride
        )

        let settings = UserSettings(
            scanRoots: [],
            excludedFolders: [".build"],
            largeFileThresholdBytes: 200_000_000,
            minDuplicateBytes: 2_000_000,
            oldFileThresholdDays: 30,
            minimumActiveCacheBytes: 10_000_000,
            ageBasis: .lastModifiedOnly,
            selectedCategories: [],
            skipHiddenFiles: false,
            allowAppBundles: true
        )

        let applied = settings.applying(to: existing)
        #expect(applied.roots == [URL(fileURLWithPath: "/tmp/initial-root")])
        #expect(applied.categories == Set(ScanCategory.allCases))
        #expect(applied.downloadsOverride == downloadsOverride)
        #expect(applied.libraryOverride == libraryOverride)
        #expect(applied.appSearchRootsOverride == appSearchOverride)
        #expect(applied.homeOverride == homeOverride)
        #expect(applied.excludedFolders == [".build"])
        #expect(applied.largeFileThresholdBytes == 200_000_000)
        #expect(applied.minDuplicateBytes == 2_000_000)
        #expect(applied.oldFileThresholdDays == 30)
        #expect(applied.minimumActiveCacheBytes == 10_000_000)
        #expect(applied.ageBasis == .lastModifiedOnly)
        #expect(applied.skipHiddenFiles == false)
        #expect(applied.allowAppBundles == true)
    }
}

