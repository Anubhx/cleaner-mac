import Foundation
import CleanerCore

public enum ScanSnapshotStoreError: Error, LocalizedError, Equatable, Sendable {
    case tempFileCreationFailed(path: String)

    public var errorDescription: String? {
        switch self {
        case .tempFileCreationFailed(let path):
            "Failed to create temporary snapshot file at \(path)."
        }
    }
}

public actor ScanSnapshotStore {
    public nonisolated let fileURL: URL

    public static var defaultFileURL: URL {
        AtomicJSONFile.applicationSupportDirectory()
            .appendingPathComponent("session", isDirectory: true)
            .appendingPathComponent("last-scan.json", isDirectory: false)
    }

    public init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.defaultFileURL
    }

    public func load() -> ScanSnapshot? {
        AtomicJSONFile.load(ScanSnapshot.self, from: fileURL)
    }

    public func save(_ snapshot: ScanSnapshot) throws {
        guard snapshot.progress.phase == .completed else {
            return
        }

        do {
            try AtomicJSONFile.save(snapshot, to: fileURL)
        } catch AtomicJSONFileError.tempFileCreationFailed(let path) {
            throw ScanSnapshotStoreError.tempFileCreationFailed(path: path)
        }
    }

    public func clear() {
        AtomicJSONFile.removeFileAndQuarantinedSiblings(at: fileURL)
    }
}
