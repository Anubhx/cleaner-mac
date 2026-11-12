import Foundation
import CleanerCore
import CleanerPreview

public protocol PreviewServicing: Sendable {
    func loadPreview(for item: ScannedItem) async -> PreviewPayload
}

extension PreviewService: PreviewServicing {}

public protocol ScanningServicing: Sendable {
    func makeProgressStream() async -> AsyncStream<ScanBatch>
    func runFullScan(configuration: ScanConfiguration) async -> ScanOutcome
    func start(configuration: ScanConfiguration) async throws
    func pause() async -> ScanCheckpoint
    func resume(from checkpoint: ScanCheckpoint) async -> ScanOutcome
    func cancel() async -> ScanOutcome
    func volumeStorageSnapshot(for root: URL) async -> VolumeStorageSnapshot?
    nonisolated func captureCheckpointSynchronously() -> ScanCheckpoint?
}

public extension ScanningServicing {
    func volumeStorageSnapshot(for root: URL) async -> VolumeStorageSnapshot? { nil }
    nonisolated func captureCheckpointSynchronously() -> ScanCheckpoint? { nil }
}

public protocol DeletionServicing: Sendable {
    func execute(
        items: [ScannedItem],
        mode: DeletionMode,
        dryRun: Bool,
        excludedFolders: [String],
        allowAppBundles: Bool,
        verifySnapshotItems: Bool
    ) async throws -> DeletionExecutionReport

    func verifySnapshotItems(_ items: [ScannedItem]) async -> [UUID: SnapshotVerificationStatus]

    func restore(entries: [TrashHistoryEntry]) async -> (restoredIDs: Set<UUID>, failures: [DeletionFailure])
}

public extension DeletionServicing {
    func verifySnapshotItems(_ items: [ScannedItem]) async -> [UUID: SnapshotVerificationStatus] {
        [:]
    }
}

public protocol HistoryStoring: Sendable {
    func loadEntries() async -> [TrashHistoryEntry]
    func append(_ newEntries: [TrashHistoryEntry]) async
    func remove(ids: Set<UUID>) async
}

public protocol ScanSnapshotStoring: Sendable {
    func load() async -> ScanSnapshot?
    func save(_ snapshot: ScanSnapshot) async throws
    func clear() async
}

public protocol UserSettingsStoring: Sendable {
    func load() async -> UserSettings?
    func save(_ settings: UserSettings) async throws
    func clear() async
}

public protocol ScanCheckpointStoring: Sendable {
    func load() async -> ScanCheckpointLoadResult
    func save(_ checkpoint: ScanCheckpoint) async throws
    nonisolated func saveSynchronously(_ checkpoint: ScanCheckpoint) throws
    func clear() async
}
