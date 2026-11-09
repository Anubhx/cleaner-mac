import Foundation

public enum ScanCategory: String, CaseIterable, Codable, Sendable, Identifiable {
    case duplicates
    case largeFiles
    case oldFiles
    case deadFiles

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .duplicates: "Duplicates"
        case .largeFiles: "Large Files"
        case .oldFiles: "Old Files"
        case .deadFiles: "Dead & Leftover Files"
        }
    }

    public var symbolName: String {
        switch self {
        case .duplicates: "doc.on.doc"
        case .largeFiles: "arrow.up.left.and.arrow.down.right"
        case .oldFiles: "clock.arrow.circlepath"
        case .deadFiles: "tray.full"
        }
    }

    public var subtitle: String {
        switch self {
        case .duplicates: "Exact content matches verified by SHA-256"
        case .largeFiles: "Files above your size threshold"
        case .oldFiles: "Untouched files past your age threshold"
        case .deadFiles: "Orphaned app data, stale caches, broken downloads, empty folders"
        }
    }
}

public enum DeadFileKind: String, Codable, Sendable {
    case orphanedAppData
    case staleCache
    case developerCache
    case brokenDownload
    case emptyDirectory

    public var displayLabel: String {
        switch self {
        case .orphanedAppData: "Orphaned App Data"
        case .staleCache: "Stale Cache"
        case .developerCache: "Developer Cache"
        case .brokenDownload: "Broken Download"
        case .emptyDirectory: "Empty Folder"
        }
    }
}

public struct VolumeStorageSnapshot: Sendable, Equatable {
    public let volumeName: String
    public let totalBytes: UInt64
    public let availableBytes: UInt64

    public init(volumeName: String, totalBytes: UInt64, availableBytes: UInt64) {
        self.volumeName = volumeName
        self.totalBytes = totalBytes
        self.availableBytes = availableBytes
    }

    public var usedBytes: UInt64 {
        totalBytes >= availableBytes ? totalBytes - availableBytes : 0
    }

    public var usedFraction: Double {
        guard totalBytes > 0 else { return 0 }
        return min(1.0, max(0.0, Double(usedBytes) / Double(totalBytes)))
    }
}

public enum RiskLevel: Int, Codable, Sendable, Comparable {
    case low = 0
    case moderate = 1
    case high = 2

    public static func < (lhs: RiskLevel, rhs: RiskLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public var label: String {
        switch self {
        case .low: "Low Risk"
        case .moderate: "Review Carefully"
        case .high: "High Risk"
        }
    }

    public var symbolName: String {
        switch self {
        case .low: "checkmark.shield"
        case .moderate: "exclamationmark.triangle"
        case .high: "exclamationmark.octagon"
        }
    }
}

public struct RiskAssessment: Codable, Sendable, Equatable, Hashable {
    public let level: RiskLevel
    public let reason: String

    public init(level: RiskLevel, reason: String) {
        self.level = level
        self.reason = reason
    }
}

public struct InodeIdentity: Codable, Sendable, Equatable, Hashable {
    public let device: UInt64
    public let inode: UInt64

    public init(device: UInt64, inode: UInt64) {
        self.device = device
        self.inode = inode
    }
}
