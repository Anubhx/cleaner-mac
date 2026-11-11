import Testing
import Foundation
import Darwin
@testable import CleanerCore
@testable import CleanerSystem

@Suite("ScanSnapshotStore Persistence")
struct ScanSnapshotStoreTests {
    private func makeSandbox() throws -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScanSnapshotStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    private func makeSessionFileURL(in sandbox: URL) -> URL {
        sandbox
            .appendingPathComponent("CleanerMac", isDirectory: true)
            .appendingPathComponent("session", isDirectory: true)
            .appendingPathComponent("last-scan.json", isDirectory: false)
    }

    private func makeConfiguration(
        roots: [URL] = [URL(fileURLWithPath: "/Users/alice/Downloads")]
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
            excludedFolders: [".git", "node_modules"],
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

    private func makeSnapshot(
        id: UUID = UUID(),
        phase: ScanPhase = .completed,
        scannedFiles: Int = 250,
        startedAt: Date = Date(timeIntervalSince1970: 1_731_300_000),
        finishedAt: Date = Date(timeIntervalSince1970: 1_731_300_012),
        itemName: String = "archive-日本語-🧹.zip"
    ) -> ScanSnapshot {
        let original = makeSampleItem(
            path: "/Users/alice/Downloads/\(itemName)",
            name: itemName,
            category: .duplicates,
            size: 20_971_520,
            isRecommendedKeep: true
        )
        let duplicate = makeSampleItem(
            path: "/Users/alice/Documents/copy-\(itemName)",
            name: "copy-\(itemName)",
            category: .duplicates,
            size: 20_971_520,
            isRecommendedKeep: false
        )
        let large = makeSampleItem(
            path: "/Users/alice/Downloads/ubuntu.iso",
            name: "ubuntu.iso",
            category: .largeFiles,
            size: 1_073_741_824
        )
        let group = DuplicateGroup(
            id: "sha256:feedface",
            original: original,
            duplicates: [duplicate]
        )
        return ScanSnapshot(
            id: id,
            startedAt: startedAt,
            finishedAt: finishedAt,
            duration: finishedAt.timeIntervalSince(startedAt),
            appVersion: "1.0.0",
            configuration: makeConfiguration(),
            progress: ScanProgress(
                phase: phase,
                currentPath: "/Users/alice/Downloads",
                scannedFiles: scannedFiles,
                bytesEvaluated: 2_147_483_648,
                pendingDirectoriesCount: phase == .completed ? 0 : 12,
                skippedProtectedDirectories: 1,
                startedAt: startedAt
            ),
            categories: [
                CategorySnapshot(category: .largeFiles, items: [large]),
                CategorySnapshot(category: .duplicates, items: [original, duplicate])
            ],
            duplicateGroups: [group],
            totalReclaimableBytes: 20_971_520 + 1_073_741_824
        )
    }

    private func posixMode(of url: URL) throws -> Int {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))
        let modeNumber = try #require(attrs[.posixPermissions] as? NSNumber)
        return modeNumber.intValue & 0o777
    }

    private func lstatPermissions(of url: URL) throws -> Int {
        var info = stat()
        let result = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return lstat(path, &info)
        }
        #expect(result == 0)
        return Int(info.st_mode & 0o777)
    }

    @Test("Default file URL resolves to Library/Application Support/CleanerMac/session/last-scan.json")
    func defaultFileURLMatchesExpectedLayout() {
        let store = ScanSnapshotStore()
        let url = store.fileURL
        #expect(url == ScanSnapshotStore.defaultFileURL)

        let components = url.pathComponents
        #expect(components.suffix(5) == ["Library", "Application Support", "CleanerMac", "session", "last-scan.json"])
    }

    @Test("Round-trip save and load uses ISO-8601 dates and returns identical snapshot")
    func roundTripSaveAndLoad() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let fileURL = makeSessionFileURL(in: sandbox)
        let store = ScanSnapshotStore(fileURL: fileURL)
        let snapshot = makeSnapshot()

        try await store.save(snapshot)

        #expect(FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)))
        let rawJSON = try String(contentsOf: fileURL, encoding: .utf8)
        #expect(rawJSON.contains("\"startedAt\":\"2024-11-11T"))

        let loaded = await store.load()
        #expect(loaded == snapshot)
    }

    @Test("Load returns nil cleanly when snapshot file does not exist")
    func loadMissingFileReturnsNil() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let fileURL = makeSessionFileURL(in: sandbox)
        let store = ScanSnapshotStore(fileURL: fileURL)

        let loaded = await store.load()
        #expect(loaded == nil)
        #expect(!FileManager.default.fileExists(atPath: fileURL.deletingLastPathComponent().path(percentEncoded: false)))
    }

    @Test("Corrupted JSON on disk is renamed to last-scan.json.corrupt-<ISO8601> and load returns nil")
    func corruptedJSONIsRenamedAndReturnsNil() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let fileURL = makeSessionFileURL(in: sandbox)
        let sessionDir = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)

        let corruptPayload = Data("{corrupted-json: [not-closed".utf8)
        try corruptPayload.write(to: fileURL)

        let store = ScanSnapshotStore(fileURL: fileURL)
        let loaded = await store.load()

        #expect(loaded == nil)
        #expect(!FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)))

        let contents = try FileManager.default.contentsOfDirectory(
            at: sessionDir,
            includingPropertiesForKeys: nil
        )
        #expect(contents.count == 1)

        let quarantined = try #require(contents.first)
        let prefix = "last-scan.json.corrupt-"
        #expect(quarantined.lastPathComponent.hasPrefix(prefix))

        let isoSuffix = String(quarantined.lastPathComponent.dropFirst(prefix.count))
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        #expect(formatter.date(from: isoSuffix) != nil)

        let preservedBytes = try Data(contentsOf: quarantined)
        #expect(preservedBytes == corruptPayload)
    }

    @Test("Schema version mismatch is renamed to last-scan.json.corrupt-<ISO8601> and load returns nil")
    func schemaMismatchIsRenamedAndReturnsNil() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let fileURL = makeSessionFileURL(in: sandbox)
        let sessionDir = fileURL.deletingLastPathComponent()
        let store = ScanSnapshotStore(fileURL: fileURL)

        try await store.save(makeSnapshot())
        let originalData = try Data(contentsOf: fileURL)
        var rawObject = try #require(try JSONSerialization.jsonObject(with: originalData) as? [String: Any])
        rawObject["schemaVersion"] = 999
        let mismatchedData = try JSONSerialization.data(withJSONObject: rawObject, options: [.sortedKeys])
        try mismatchedData.write(to: fileURL)

        let loaded = await store.load()

        #expect(loaded == nil)
        #expect(!FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)))

        let contents = try FileManager.default.contentsOfDirectory(
            at: sessionDir,
            includingPropertiesForKeys: nil
        )
        #expect(contents.count == 1)

        let quarantined = try #require(contents.first)
        let prefix = "last-scan.json.corrupt-"
        #expect(quarantined.lastPathComponent.hasPrefix(prefix))

        let isoSuffix = String(quarantined.lastPathComponent.dropFirst(prefix.count))
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        #expect(formatter.date(from: isoSuffix) != nil)

        let preservedBytes = try Data(contentsOf: quarantined)
        #expect(preservedBytes == mismatchedData)
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

    @Test("Enforces 0600 file permissions and 0700 parent directory permissions on save and overwrite")
    func enforces0600FileAnd0700DirectoryPermissions() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let fileURL = makeSessionFileURL(in: sandbox)
        let sessionDir = fileURL.deletingLastPathComponent()
        let store = ScanSnapshotStore(fileURL: fileURL)

        // Initial save creates CleanerMac/session/last-scan.json
        let firstSnapshot = makeSnapshot(scannedFiles: 100)
        try await store.save(firstSnapshot)

        #expect(try posixMode(of: sessionDir) == 0o700)
        #expect(try lstatPermissions(of: sessionDir) == 0o700)
        #expect(try posixMode(of: fileURL) == 0o600)
        #expect(try lstatPermissions(of: fileURL) == 0o600)
        let firstInode = try inodeNumber(of: fileURL)

        // Simulate overly permissive pre-existing modes, then overwrite via atomic temp+rename
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: sessionDir.path(percentEncoded: false))
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: fileURL.path(percentEncoded: false))

        let secondSnapshot = makeSnapshot(scannedFiles: 400)
        try await store.save(secondSnapshot)

        #expect(try posixMode(of: sessionDir) == 0o700)
        #expect(try posixMode(of: fileURL) == 0o600)
        let secondInode = try inodeNumber(of: fileURL)
        #expect(secondInode != firstInode)

        // Verify no leftover temp files remain in session/
        let entries = try FileManager.default.contentsOfDirectory(
            at: sessionDir,
            includingPropertiesForKeys: nil
        )
        #expect(entries.map(\.lastPathComponent) == ["last-scan.json"])
        #expect(await store.load() == secondSnapshot)
    }

    @Test("Save ignores cancelled or incomplete scans so previous good snapshot stays untouched")
    func saveIgnoresCancelledAndIncompleteScans() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let fileURL = makeSessionFileURL(in: sandbox)
        let store = ScanSnapshotStore(fileURL: fileURL)

        // Attempt to save cancelled scan when nothing exists yet
        let cancelledSnapshot = makeSnapshot(phase: .cancelled, scannedFiles: 12)
        try await store.save(cancelledSnapshot)
        #expect(!FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)))

        // Save a completed snapshot
        let goodSnapshot = makeSnapshot(phase: .completed, scannedFiles: 500)
        try await store.save(goodSnapshot)
        let baselineBytes = try Data(contentsOf: fileURL)

        // Attempt saves with non-completed phases
        for phase in [ScanPhase.cancelled, .paused, .idle, .enumerating, .hashingDuplicates] {
            let partial = makeSnapshot(phase: phase, scannedFiles: 7)
            try await store.save(partial)
        }

        let afterBytes = try Data(contentsOf: fileURL)
        #expect(afterBytes == baselineBytes)
        #expect(await store.load() == goodSnapshot)
    }

    @Test("Concurrent save calls preserve valid JSON without corruption via actor isolation")
    func concurrentSavesDoNotCorruptFile() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let fileURL = makeSessionFileURL(in: sandbox)
        let sessionDir = fileURL.deletingLastPathComponent()
        let store = ScanSnapshotStore(fileURL: fileURL)

        let snapshots = (0..<25).map { index in
            makeSnapshot(
                phase: .completed,
                scannedFiles: 1_000 + index,
                startedAt: Date(timeIntervalSince1970: 1_731_300_000 + Double(index)),
                finishedAt: Date(timeIntervalSince1970: 1_731_300_010 + Double(index))
            )
        }

        try await withThrowingTaskGroup(of: Void.self) { group in
            for snapshot in snapshots {
                group.addTask {
                    try await store.save(snapshot)
                }
            }
            try await group.waitForAll()
        }

        let entries = try FileManager.default.contentsOfDirectory(
            at: sessionDir,
            includingPropertiesForKeys: nil
        )
        #expect(entries.map(\.lastPathComponent) == ["last-scan.json"])
        #expect(try posixMode(of: sessionDir) == 0o700)
        #expect(try posixMode(of: fileURL) == 0o600)

        let loaded = await store.load()
        let unwrapped = try #require(loaded)
        #expect(snapshots.contains(unwrapped))
    }

    @Test("Zero-byte snapshot file is treated as corrupt, renamed safely, and subsequent load stays nil")
    func zeroByteFileIsQuarantinedSafely() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let fileURL = makeSessionFileURL(in: sandbox)
        let sessionDir = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: fileURL.path(percentEncoded: false), contents: Data())

        let store = ScanSnapshotStore(fileURL: fileURL)
        #expect(await store.load() == nil)
        #expect(await store.load() == nil)

        let entries = try FileManager.default.contentsOfDirectory(
            at: sessionDir,
            includingPropertiesForKeys: nil
        )
        #expect(entries.count == 1)
        #expect(entries[0].lastPathComponent.hasPrefix("last-scan.json.corrupt-"))
    }

    @Test("Decode executes inside actor off the main thread even when invoked from MainActor")
    @MainActor
    func loadDecodesOffMainActor() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let fileURL = makeSessionFileURL(in: sandbox)
        let store = ScanSnapshotStore(fileURL: fileURL)
        let snapshot = makeSnapshot()
        try await store.save(snapshot)

        let loaded = await store.load()
        #expect(loaded == snapshot)
    }
}
