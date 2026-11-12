import Testing
import Foundation
import Darwin
@testable import CleanerCore
@testable import CleanerSystem

@Suite("UserSettingsStore Persistence")
struct UserSettingsStoreTests {
    private func makeSandbox() throws -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("UserSettingsStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    private func makeSettingsFileURL(in sandbox: URL) -> URL {
        sandbox
            .appendingPathComponent("CleanerMac", isDirectory: true)
            .appendingPathComponent("settings.json", isDirectory: false)
    }

    private func posixMode(of url: URL) throws -> Int {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))
        let modeNumber = try #require(attrs[.posixPermissions] as? NSNumber)
        return modeNumber.intValue & 0o777
    }

    private func inodeNumber(of url: URL) throws -> UInt64 {
        var info = stat()
        let result = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return lstat(path, &info)
        }
        #expect(result == 0)
        return UInt64(info.st_ino)
    }

    @Test("Default file URL resolves to Library/Application Support/CleanerMac/settings.json")
    func defaultFileURLMatchesExpectedLayout() {
        let store = UserSettingsStore()
        let url = store.fileURL
        #expect(url == UserSettingsStore.defaultFileURL)
        #expect(url.pathComponents.suffix(4) == ["Library", "Application Support", "CleanerMac", "settings.json"])
    }

    @Test("Full settings round-trip persists all configuration and UI preferences without dry-run state")
    func fullSettingsRoundTrip() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let fileURL = makeSettingsFileURL(in: sandbox)
        let store = UserSettingsStore(fileURL: fileURL)

        let settings = UserSettings(
            scanRoots: [
                URL(fileURLWithPath: "/Users/alice/Downloads"),
                URL(fileURLWithPath: "/Users/alice/Projets_été_🧹")
            ],
            excludedFolders: [".git", "node_modules", "/Users/alice/Archive_日本語"],
            largeFileThresholdBytes: 250 * 1_048_576,
            minDuplicateBytes: 2_097_152,
            oldFileThresholdDays: 120,
            minimumActiveCacheBytes: 104_857_600,
            ageBasis: .lastModifiedOnly,
            selectedCategories: [.largeFiles, .deadFiles],
            skipHiddenFiles: false,
            allowAppBundles: true,
            lastSelectedCategory: .deadFiles,
            sortOrder: .nameAscending,
            isInspectorVisible: false
        )

        try await store.save(settings)

        let rawJSON = try String(contentsOf: fileURL, encoding: .utf8)
        #expect(!rawJSON.contains("isDryRun"))
        #expect(!rawJSON.contains("dryRun"))

        let loaded = await store.load()
        #expect(loaded == settings)
    }

    @Test("Corrupted JSON and schema mismatches rename settings.json cleanly and load returns nil")
    func corruptAndSchemaMismatchAreQuarantined() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let fileURL = makeSettingsFileURL(in: sandbox)
        let dir = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // 1. Corrupt syntax
        let corruptPayload = Data("not valid settings json {".utf8)
        try corruptPayload.write(to: fileURL)
        let store = UserSettingsStore(fileURL: fileURL)

        #expect(await store.load() == nil)
        #expect(!FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)))

        let afterCorrupt = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        #expect(afterCorrupt.count == 1)
        #expect(afterCorrupt[0].lastPathComponent.hasPrefix("settings.json.corrupt-"))
        #expect(try Data(contentsOf: afterCorrupt[0]) == corruptPayload)

        // 2. Schema version mismatch
        let futurePayload = Data(#"{"schemaVersion": 999}"#.utf8)
        try futurePayload.write(to: fileURL)
        #expect(await store.load() == nil)
        #expect(!FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)))

        let afterMismatch = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        #expect(afterMismatch.count == 2)
        #expect(afterMismatch.allSatisfy { $0.lastPathComponent.hasPrefix("settings.json.corrupt-") })
    }

    @Test("Enforces 0600 file and 0700 directory permissions using temp-file-then-rename")
    func enforces0600And0700AtomicPermissions() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let fileURL = makeSettingsFileURL(in: sandbox)
        let dir = fileURL.deletingLastPathComponent()
        let store = UserSettingsStore(fileURL: fileURL)

        try await store.save(UserSettings(sortOrder: .sizeDescending))
        #expect(try posixMode(of: dir) == 0o700)
        #expect(try posixMode(of: fileURL) == 0o600)
        let firstInode = try inodeNumber(of: fileURL)

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path(percentEncoded: false))
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: fileURL.path(percentEncoded: false))

        try await store.save(UserSettings(sortOrder: .riskHighest))
        #expect(try posixMode(of: dir) == 0o700)
        #expect(try posixMode(of: fileURL) == 0o600)
        #expect(try inodeNumber(of: fileURL) != firstInode)

        let entries = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        #expect(entries.map(\.lastPathComponent) == ["settings.json"])
    }

    @Test("Concurrent save calls preserve valid JSON without corruption via actor isolation")
    func concurrentSavesDoNotCorruptSettings() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let fileURL = makeSettingsFileURL(in: sandbox)
        let dir = fileURL.deletingLastPathComponent()
        let store = UserSettingsStore(fileURL: fileURL)

        let candidates = (0..<20).map { idx in
            UserSettings(
                oldFileThresholdDays: 30 + idx,
                lastSelectedCategory: ScanCategory.allCases[idx % ScanCategory.allCases.count],
                sortOrder: ResultSortOrder.allCases[idx % ResultSortOrder.allCases.count],
                isInspectorVisible: idx.isMultiple(of: 2)
            )
        }

        try await withThrowingTaskGroup(of: Void.self) { group in
            for item in candidates {
                group.addTask {
                    try await store.save(item)
                }
            }
            try await group.waitForAll()
        }

        let entries = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        #expect(entries.map(\.lastPathComponent) == ["settings.json"])
        let loaded = try #require(await store.load())
        #expect(candidates.contains(loaded))
    }

    @Test("clear() removes settings.json and quarantined .corrupt-* siblings without touching other files")
    func clearRemovesSettingsAndQuarantinedSiblings() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let fileURL = makeSettingsFileURL(in: sandbox)
        let dir = fileURL.deletingLastPathComponent()
        let store = UserSettingsStore(fileURL: fileURL)

        // Idempotent when missing
        await store.clear()

        try await store.save(UserSettings(oldFileThresholdDays: 77))
        let corruptSibling = dir.appendingPathComponent("settings.json.corrupt-2026-01-01T00:00:00Z")
        try Data("corrupt".utf8).write(to: corruptSibling)
        let historySibling = dir.appendingPathComponent("trash-history.json")
        try Data("[]".utf8).write(to: historySibling)

        await store.clear()

        #expect(!FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)))
        #expect(!FileManager.default.fileExists(atPath: corruptSibling.path(percentEncoded: false)))
        #expect(FileManager.default.fileExists(atPath: historySibling.path(percentEncoded: false)))
        #expect(await store.load() == nil)

        await store.clear()
    }
}

