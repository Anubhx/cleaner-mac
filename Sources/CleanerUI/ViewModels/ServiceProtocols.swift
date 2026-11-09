import Foundation
import CleanerCore

public protocol ScanningServicing: Sendable {
    func makeProgressStream() async -> AsyncStream<ScanBatch>
    func runFullScan(configuration: ScanConfiguration) async -> ScanOutcome
    func start(configuration: ScanConfiguration) async throws
    func pause() async -> ScanCheckpoint
    func resume(from checkpoint: ScanCheckpoint) async -> ScanOutcome
    func cancel() async -> ScanOutcome
}

public protocol DeletionServicing: Sendable {
    func execute(
        items: [ScannedItem],
        mode: DeletionMode,
        dryRun: Bool,
        excludedFolders: [String],
        allowAppBundles: Bool
    ) async throws -> DeletionExecutionReport

    func restore(entries: [TrashHistoryEntry]) async -> (restoredIDs: Set<UUID>, failures: [DeletionFailure])
}

public protocol HistoryStoring: Sendable {
    func loadEntries() async -> [TrashHistoryEntry]
    func append(_ newEntries: [TrashHistoryEntry]) async
    func remove(ids: Set<UUID>) async
}
