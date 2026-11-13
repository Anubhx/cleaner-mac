import Foundation

public enum ScanSnapshotError: Error, LocalizedError, Equatable, Sendable {
    case unsupportedSchemaVersion(found: Int, supported: Int)

    public var errorDescription: String? {
        switch self {
        case .unsupportedSchemaVersion(let found, let supported):
            "Unsupported scan snapshot schema version \(found); expected \(supported)."
        }
    }
}

public struct CategorySnapshot: Codable, Sendable, Equatable {
    public var category: ScanCategory
    public var items: [ScannedItem]

    public init(category: ScanCategory, items: [ScannedItem]) {
        self.category = category
        self.items = items
    }
}

public struct ScanSnapshot: Identifiable, Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var id: UUID
    public var startedAt: Date
    public var finishedAt: Date
    public var duration: TimeInterval
    public var appVersion: String
    public var configuration: ScanConfiguration
    public var progress: ScanProgress
    public var categories: [CategorySnapshot]
    public var duplicateGroups: [DuplicateGroup]
    public var totalReclaimableBytes: UInt64

    public init(
        schemaVersion: Int = ScanSnapshot.currentSchemaVersion,
        id: UUID = UUID(),
        startedAt: Date,
        finishedAt: Date,
        duration: TimeInterval,
        appVersion: String,
        configuration: ScanConfiguration,
        progress: ScanProgress,
        categories: [CategorySnapshot],
        duplicateGroups: [DuplicateGroup],
        totalReclaimableBytes: UInt64
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.duration = duration
        self.appVersion = appVersion
        self.configuration = configuration
        self.progress = progress
        self.categories = categories
        self.duplicateGroups = duplicateGroups
        self.totalReclaimableBytes = totalReclaimableBytes
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case id
        case startedAt
        case finishedAt
        case duration
        case appVersion
        case configuration
        case progress
        case categories
        case duplicateGroups
        case totalReclaimableBytes
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .schemaVersion)
        guard version == Self.currentSchemaVersion else {
            throw ScanSnapshotError.unsupportedSchemaVersion(
                found: version,
                supported: Self.currentSchemaVersion
            )
        }

        self.schemaVersion = version
        self.id = try container.decode(UUID.self, forKey: .id)
        self.startedAt = try container.decode(Date.self, forKey: .startedAt)
        self.finishedAt = try container.decode(Date.self, forKey: .finishedAt)
        self.duration = try container.decode(TimeInterval.self, forKey: .duration)
        self.appVersion = try container.decode(String.self, forKey: .appVersion)
        self.configuration = try container.decode(ScanConfiguration.self, forKey: .configuration)
        self.progress = try container.decode(ScanProgress.self, forKey: .progress)
        self.categories = try container.decode([CategorySnapshot].self, forKey: .categories)
        self.duplicateGroups = try container.decode([DuplicateGroup].self, forKey: .duplicateGroups)
        self.totalReclaimableBytes = try container.decode(UInt64.self, forKey: .totalReclaimableBytes)
    }
}
