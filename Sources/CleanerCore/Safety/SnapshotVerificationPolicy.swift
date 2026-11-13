import Foundation

public enum SnapshotVerificationStatus: String, Codable, Sendable, Equatable, Hashable {
    case unchanged
    case modified
    case missing
    case replaced

    public var displayLabel: String {
        switch self {
        case .unchanged: "Unchanged"
        case .modified: "Modified"
        case .missing: "Missing"
        case .replaced: "Replaced"
        }
    }
}

public struct LiveFileStat: Sendable, Equatable {
    public let exists: Bool
    public let isSymlink: Bool
    public let isDirectory: Bool
    public let inode: InodeIdentity?
    public let logicalSize: UInt64
    public let modifiedDate: Date?

    public init(
        exists: Bool,
        isSymlink: Bool = false,
        isDirectory: Bool = false,
        inode: InodeIdentity? = nil,
        logicalSize: UInt64 = 0,
        modifiedDate: Date? = nil
    ) {
        self.exists = exists
        self.isSymlink = isSymlink
        self.isDirectory = isDirectory
        self.inode = inode
        self.logicalSize = logicalSize
        self.modifiedDate = modifiedDate
    }

    public static let missing = LiveFileStat(exists: false)
}

public enum SnapshotVerificationPolicy {
    public static let staleSnapshotBlockedReason = "This file changed since the scan. Rescan before removing it."
    public static let missingFileBlockedReason = "Missing since the scan — this file no longer exists on disk."

    public static func verify(item: ScannedItem, against live: LiveFileStat) -> SnapshotVerificationStatus {
        guard live.exists else {
            return .missing
        }

        if live.isSymlink || live.isDirectory != item.isDirectory {
            return .replaced
        }

        guard let recordedInode = item.inode,
              let liveInode = live.inode,
              recordedInode == liveInode else {
            return .replaced
        }

        if !item.isDirectory && live.logicalSize != item.logicalSize {
            return .modified
        }

        guard let recordedDate = item.modifiedDate,
              let liveDate = live.modifiedDate,
              modificationDatesMatch(recorded: recordedDate, live: liveDate) else {
            return .modified
        }

        return .unchanged
    }

    public static func blockedReason(for status: SnapshotVerificationStatus) -> String? {
        switch status {
        case .unchanged:
            nil
        case .missing:
            missingFileBlockedReason
        case .modified, .replaced:
            staleSnapshotBlockedReason
        }
    }

    private static func modificationDatesMatch(recorded: Date, live: Date) -> Bool {
        let recordedSeconds = recorded.timeIntervalSince1970
        let liveSeconds = live.timeIntervalSince1970
        let recordedWhole = recordedSeconds.rounded(.towardZero)
        if abs(recordedSeconds - recordedWhole) < 1e-6 {
            return recordedWhole == liveSeconds.rounded(.towardZero)
        }
        return abs(recordedSeconds - liveSeconds) < 0.001
    }
}
