import Foundation

public struct ScannedItem: Identifiable, Codable, Sendable, Equatable, Hashable {
    public let id: UUID
    public let url: URL
    public let name: String
    public let logicalSize: UInt64
    public let allocatedSize: UInt64
    public let isDirectory: Bool
    public let modifiedDate: Date?
    public let createdDate: Date?
    public let accessedDate: Date?
    public let category: ScanCategory
    public let deadKind: DeadFileKind?
    public let risk: RiskAssessment
    public let inode: InodeIdentity?
    public let linkCount: Int
    public let isCloudDataless: Bool
    public let contentTypeIdentifier: String?
    public let isRecommendedKeep: Bool

    public init(
        id: UUID = UUID(),
        url: URL,
        name: String,
        logicalSize: UInt64,
        allocatedSize: UInt64,
        isDirectory: Bool,
        modifiedDate: Date? = nil,
        createdDate: Date? = nil,
        accessedDate: Date? = nil,
        category: ScanCategory,
        deadKind: DeadFileKind? = nil,
        risk: RiskAssessment? = nil,
        inode: InodeIdentity? = nil,
        linkCount: Int = 1,
        isCloudDataless: Bool = false,
        contentTypeIdentifier: String? = nil,
        isRecommendedKeep: Bool = false
    ) {
        self.id = id
        self.url = url.standardizedFileURL
        self.name = name
        self.logicalSize = logicalSize
        self.allocatedSize = allocatedSize
        self.isDirectory = isDirectory
        self.modifiedDate = modifiedDate
        self.createdDate = createdDate
        self.accessedDate = accessedDate
        self.category = category
        self.deadKind = deadKind
        self.risk = risk ?? RiskEvaluator.assess(
            category: category,
            deadKind: deadKind,
            isCloudDataless: isCloudDataless,
            inApplicationSupport: url.path.contains("/Library/Application Support/"),
            inContainerOrSupport: url.path.contains("/Library/Containers/") || url.path.contains("/Library/Application Support/")
        )
        self.inode = inode
        self.linkCount = linkCount
        self.isCloudDataless = isCloudDataless
        self.contentTypeIdentifier = contentTypeIdentifier
        self.isRecommendedKeep = isRecommendedKeep
    }

    public var effectiveSize: UInt64 {
        allocatedSize > 0 ? allocatedSize : logicalSize
    }

    /// Physical disk bytes reclaimed if removed (uses allocated storage for sparse files and 0 for dataless stubs).
    public var reclaimableDiskBytes: UInt64 {
        if isCloudDataless { return 0 }
        return min(logicalSize, allocatedSize)
    }

    public func markedAsKeep(_ keep: Bool) -> ScannedItem {
        ScannedItem(
            id: id,
            url: url,
            name: name,
            logicalSize: logicalSize,
            allocatedSize: allocatedSize,
            isDirectory: isDirectory,
            modifiedDate: modifiedDate,
            createdDate: createdDate,
            accessedDate: accessedDate,
            category: category,
            deadKind: deadKind,
            risk: risk,
            inode: inode,
            linkCount: linkCount,
            isCloudDataless: isCloudDataless,
            contentTypeIdentifier: contentTypeIdentifier,
            isRecommendedKeep: keep
        )
    }
}

public struct DuplicateGroup: Identifiable, Codable, Sendable, Equatable {
    public let id: String
    public let original: ScannedItem
    public let duplicates: [ScannedItem]

    public init(id: String, original: ScannedItem, duplicates: [ScannedItem]) {
        self.id = id
        self.original = original.markedAsKeep(true)
        self.duplicates = duplicates.map { $0.markedAsKeep(false) }
    }

    public var reclaimableBytes: UInt64 {
        duplicates.reduce(0) { $0 &+ $1.reclaimableDiskBytes }
    }

    public var allItems: [ScannedItem] {
        [original] + duplicates
    }
}
