import Foundation
import CleanerCore
import CleanerSystem
import CleanerUI

extension ScanCoordinator: ScanningServicing {
    public func volumeStorageSnapshot(for root: URL) async -> VolumeStorageSnapshot? {
        FilesystemProbes.volumeStorageSnapshot(for: root)
    }
}
extension DeletionExecutor: DeletionServicing {}
extension CleanHistoryStore: HistoryStoring {}
