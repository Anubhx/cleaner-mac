import Testing
import Foundation
import Darwin
@testable import CleanerCore
@testable import CleanerSystem

@Suite("ScanCheckpointStore & Compression & Periodic Triggers")
struct ScanCheckpointStoreTests {
    private func makeSandbox() throws -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScanCheckpointStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    private func makeCheckpointFileURL(in sandbox: URL) -> URL {
        sandbox
            .appendingPathComponent("CleanerMac", isDirectory: true)
            .appendingPathComponent("session", isDirectory: true)
            .appendingPathComponent("checkpoint.json", isDirectory: false)
    }

    private func posixMode(of url: URL) throws -> Int {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))
        let number = try #require(attrs[.posixPermissions] as? NSNumber)
        return number.intValue & 0o777
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

    private func makeRealisticCheckpoint(directoryCount: Int = 500, filesPerDir: Int = 6) -> ScanCheckpoint {
        var visited: Set<String> = []
        var pending: [URL] = []
        var candidates: [ScannedItem] = []

        for d in 0..<directoryCount {
            let dirPath = "/Users/alice/Projects/workspace/module-\(d / 20)/submodule-\(d)"
            visited.insert(dirPath)
            if d > directoryCount / 2 {
                pending.append(URL(fileURLWithPath: dirPath))
            } else {
                for f in 0..<filesPerDir {
                    let fileURL = URL(fileURLWithPath: "\(dirPath)/artifact_\(f).dat")
                    candidates.append(
                        ScannedItem(
                            url: fileURL,
                            name: fileURL.lastPathComponent,
                            logicalSize: UInt64(1024 * (f + 1)),
                            allocatedSize: UInt64(4096 * (f + 1)),
                            isDirectory: false,
                            modifiedDate: Date(timeIntervalSince1970: 1_700_000_000 + TimeInterval(f)),
                            category: .largeFiles
                        )
                    )
                }
            }
        }

        return ScanCheckpoint(
            configuration: ScanConfiguration(roots: [URL(fileURLWithPath: "/Users/alice/Projects")]),
            pendingDirectories: pending,
            candidateFiles: candidates,
            deadItems: [],
            visitedDirectoryPaths: visited,
            scannedFiles: candidates.count,
            bytesEvaluated: 50_000_000,
            skippedProtectedDirectories: 2,
            startedAt: Date(timeIntervalSince1970: 1_731_300_000)
        )
    }

    @Test("Default file URL resolves to Library/Application Support/CleanerMac/session/checkpoint.json")
    func defaultFileURLMatchesSessionLayout() {
        let store = ScanCheckpointStore()
        let url = store.fileURL
        #expect(url == ScanCheckpointStore.defaultFileURL)
        #expect(url.pathComponents.suffix(5) == ["Library", "Application Support", "CleanerMac", "session", "checkpoint.json"])
    }

    @Test("Compression shrinks realistic ScanCheckpoint JSON dramatically and preserves identical round-trip with 0600/0700 atomic rename")
    func compressionRoundTripAndPermissions() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let fileURL = makeCheckpointFileURL(in: sandbox)
        let dirURL = fileURL.deletingLastPathComponent()
        let now = Date(timeIntervalSince1970: 1_731_350_000)
        let store = ScanCheckpointStore(fileURL: fileURL, nowProvider: { now })

        let checkpoint = makeRealisticCheckpoint(directoryCount: 600, filesPerDir: 5)
        try await store.save(checkpoint)

        #expect(try posixMode(of: dirURL) == 0o700)
        #expect(try posixMode(of: fileURL) == 0o600)
        let firstInode = try inodeNumber(of: fileURL)

        let rawFileData = try Data(contentsOf: fileURL)
        guard case .loaded(let restored, let savedAt, let compressedBytes, let uncompressedBytes) = await store.load() else {
            Issue.record("Expected loaded ScanCheckpoint")
            return
        }

        #expect(restored == checkpoint)
        #expect(abs(savedAt.timeIntervalSince(now)) < 1.0)
        #expect(compressedBytes == rawFileData.count)
        // Compressed checkpoint envelope on disk must be much smaller than uncompressed JSON (typically < 30%)
        #expect(Double(rawFileData.count) < Double(uncompressedBytes) * 0.35)

        // Overwrite uses atomic temp-file-then-rename and enforces 0600/0700 again
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: fileURL.path(percentEncoded: false))
        try await store.save(checkpoint)
        #expect(try posixMode(of: fileURL) == 0o600)
        #expect(try inodeNumber(of: fileURL) != firstInode)
    }

    @Test("Schema mismatch quarantines file and returns schemaMismatch; corrupted JSON quarantines and returns corrupted")
    func schemaMismatchAndCorruptionHandling() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let fileURL = makeCheckpointFileURL(in: sandbox)
        let dirURL = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
        let store = ScanCheckpointStore(fileURL: fileURL)

        // 1. Future schema version
        try Data(#"{"schemaVersion": 999}"#.utf8).write(to: fileURL)
        let mismatchResult = await store.load()
        #expect(mismatchResult == .schemaMismatch(found: 999, supported: ScanCheckpointEnvelope.currentSchemaVersion))
        #expect(!FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)))
        let afterMismatch = try FileManager.default.contentsOfDirectory(at: dirURL, includingPropertiesForKeys: nil)
        #expect(afterMismatch.count == 1)
        #expect(afterMismatch[0].lastPathComponent.hasPrefix("checkpoint.json.corrupt-"))

        // 2. Corrupt syntax
        try Data("{corrupt json".utf8).write(to: fileURL)
        let corruptResult = await store.load()
        #expect(corruptResult == .corrupted)
        #expect(!FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)))
        let afterCorrupt = try FileManager.default.contentsOfDirectory(at: dirURL, includingPropertiesForKeys: nil)
        #expect(afterCorrupt.count == 2)
    }

    @Test("Checkpoints older than 24 hours are discarded on load while under-24h checkpoints remain resumable")
    func expiresCheckpointsOlderThan24Hours() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let fileURL = makeCheckpointFileURL(in: sandbox)
        let savedTime = Date(timeIntervalSince1970: 1_731_300_000)
        let writerStore = ScanCheckpointStore(fileURL: fileURL, nowProvider: { savedTime })
        try await writerStore.save(makeRealisticCheckpoint(directoryCount: 10, filesPerDir: 2))

        // 23h 59m later -> still valid
        let almostExpiredReader = ScanCheckpointStore(fileURL: fileURL, nowProvider: { savedTime.addingTimeInterval(23 * 3600 + 3540) })
        if case .loaded = await almostExpiredReader.load() {
            // ok
        } else {
            Issue.record("Expected checkpoint under 24h to load")
        }

        // 24h 01m later -> expired and discarded
        let expiredReader = ScanCheckpointStore(fileURL: fileURL, nowProvider: { savedTime.addingTimeInterval(86_460) })
        let expiredResult = await expiredReader.load()
        #expect(expiredResult == .expired)
        #expect(!FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)))
    }

    @Test("ScanCoordinator saves checkpoint every N directories, saves on pause, and clears on completion or cancel")
    func coordinatorPeriodicSavePauseAndClear() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let scanRoot = sandbox.appendingPathComponent("ScanTree", isDirectory: true)
        for i in 0..<15 {
            let folder = scanRoot.appendingPathComponent("dir-\(i)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appendingPathComponent("data.bin")
            try Data(repeating: UInt8(i), count: 8192).write(to: file)
        }

        let checkpointURL = makeCheckpointFileURL(in: sandbox)
        let checkpointStore = ScanCheckpointStore(fileURL: checkpointURL)
        let config = ScanConfiguration(
            roots: [scanRoot],
            categories: [.largeFiles],
            largeFileThresholdBytes: 4096
        )

        let baselineCoordinator = ScanCoordinator(safetyGuard: SafetyGuard(currentUserHome: sandbox))
        let baseline = await baselineCoordinator.runFullScan(configuration: config)
        #expect(baseline.items(in: .largeFiles).count == 15)

        // 1. Periodic checkpoint trigger every 4 directories -> pause mid-scan -> verify checkpoint exists -> resume -> clears on complete
        let coordinator = ScanCoordinator(
            safetyGuard: SafetyGuard(currentUserHome: sandbox),
            perDirectoryDelay: .milliseconds(20),
            checkpointDirectoryInterval: 4,
            checkpointStore: checkpointStore
        )

        let scanTask = Task {
            await coordinator.runFullScan(configuration: config)
        }
        try await Task.sleep(for: .milliseconds(130))

        // Mid-scan periodic checkpoint should already exist on disk
        if case .loaded(let midScanCheckpoint, _, _, _) = await checkpointStore.load() {
            #expect(midScanCheckpoint.scannedFiles > 0)
            #expect(!midScanCheckpoint.visitedDirectoryPaths.isEmpty)
        } else {
            Issue.record("Expected periodic checkpoint on disk mid-scan")
        }

        let pausedCheckpoint = await coordinator.pause()
        let pausedOutcome = await scanTask.value
        #expect(pausedOutcome.progress.phase == .paused)

        // Synchronous capture returns current checkpoint while paused
        #expect(coordinator.captureCheckpointSynchronously() != nil)

        // Completed resume removes checkpoint.json and achieves exact baseline file parity
        let resumedOutcome = await coordinator.resume(from: pausedCheckpoint)
        #expect(resumedOutcome.progress.phase == .completed)
        #expect(Set(resumedOutcome.items(in: .largeFiles).map(\.url)) == Set(baseline.items(in: .largeFiles).map(\.url)))
        #expect(!FileManager.default.fileExists(atPath: checkpointURL.path(percentEncoded: false)))
    }

    @Test("Urgent synchronous capture during active scan saves valid checkpoint and pause-then-cancel clears checkpoint")
    func activeSyncCaptureAndPauseThenCancel() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let scanRoot = sandbox.appendingPathComponent("Tree", isDirectory: true)
        for i in 0..<20 {
            let folder = scanRoot.appendingPathComponent("dir-\(i)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(repeating: UInt8(i), count: 8192).write(to: folder.appendingPathComponent("blob.bin"))
        }

        let checkpointURL = makeCheckpointFileURL(in: sandbox)
        let checkpointStore = ScanCheckpointStore(fileURL: checkpointURL)
        let config = ScanConfiguration(
            roots: [scanRoot],
            categories: [.largeFiles],
            largeFileThresholdBytes: 4096
        )

        let baselineCoordinator = ScanCoordinator(safetyGuard: SafetyGuard(currentUserHome: sandbox))
        let baseline = await baselineCoordinator.runFullScan(configuration: config)
        #expect(baseline.items(in: .largeFiles).count == 20)

        // 1. Capture synchronously mid-flight (simulating willTerminateNotification during active scan)
        let activeCoordinator = ScanCoordinator(
            safetyGuard: SafetyGuard(currentUserHome: sandbox),
            perDirectoryDelay: .milliseconds(25),
            checkpointDirectoryInterval: 100, // won't trigger periodically yet — relies on urgent capture
            checkpointStore: checkpointStore
        )
        let activeTask = Task {
            await activeCoordinator.runFullScan(configuration: config)
        }
        try await Task.sleep(for: .milliseconds(120))

        let captured = try #require(activeCoordinator.captureCheckpointSynchronously())
        try checkpointStore.saveSynchronously(captured)
        _ = await activeTask.value

        // Resume captured checkpoint in a brand-new ScanCoordinator -> full baseline parity
        guard case .loaded(let reloaded, _, _, _) = await checkpointStore.load() else {
            Issue.record("Expected synchronously saved checkpoint to reload cleanly")
            return
        }
        let freshCoordinator = ScanCoordinator(
            safetyGuard: SafetyGuard(currentUserHome: sandbox),
            checkpointStore: checkpointStore
        )
        let resumed = await freshCoordinator.resume(from: reloaded)
        #expect(resumed.progress.phase == .completed)
        #expect(Set(resumed.items(in: .largeFiles).map(\.url)) == Set(baseline.items(in: .largeFiles).map(\.url)))
        #expect(!FileManager.default.fileExists(atPath: checkpointURL.path(percentEncoded: false)))

        // 2. Pause -> Cancel clears checkpoint.json
        let pauseCancelCoordinator = ScanCoordinator(
            safetyGuard: SafetyGuard(currentUserHome: sandbox),
            perDirectoryDelay: .milliseconds(25),
            checkpointDirectoryInterval: 2,
            checkpointStore: checkpointStore
        )
        let task2 = Task { await pauseCancelCoordinator.runFullScan(configuration: config) }
        try await Task.sleep(for: .milliseconds(100))
        _ = await pauseCancelCoordinator.pause()
        _ = await task2.value
        #expect(FileManager.default.fileExists(atPath: checkpointURL.path(percentEncoded: false)))

        let cancelOutcome = await pauseCancelCoordinator.cancel()
        #expect(cancelOutcome.wasCancelled)
        #expect(!FileManager.default.fileExists(atPath: checkpointURL.path(percentEncoded: false)))
    }

    @Test("clear() deletes checkpoint.json and quarantined .corrupt-* siblings cleanly while preserving sibling last-scan.json")
    func clearDeletesCheckpointAndQuarantinedSiblings() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let fileURL = makeCheckpointFileURL(in: sandbox)
        let dirURL = fileURL.deletingLastPathComponent()
        let store = ScanCheckpointStore(fileURL: fileURL)

        await store.clear()

        try await store.save(makeRealisticCheckpoint(directoryCount: 10, filesPerDir: 2))
        let corruptSibling = dirURL.appendingPathComponent("checkpoint.json.corrupt-2026-01-01T00:00:00Z")
        try Data("bad".utf8).write(to: corruptSibling)
        let snapshotSibling = dirURL.appendingPathComponent("last-scan.json")
        try Data("{}".utf8).write(to: snapshotSibling)

        await store.clear()

        #expect(!FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)))
        #expect(!FileManager.default.fileExists(atPath: corruptSibling.path(percentEncoded: false)))
        #expect(FileManager.default.fileExists(atPath: snapshotSibling.path(percentEncoded: false)))
        #expect(await store.load() == .none)
    }
}

