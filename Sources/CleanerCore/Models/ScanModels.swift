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
    case brokenDownload
    case emptyDirectory

    public var displayLabel: String {
        switch self {
        case .orphanedAppData: "Orphaned App Data"
        case .staleCache: "Stale Cache"
        case .brokenDownload: "Broken Download"
        case .emptyDirectory: "Empty Folder"
        }
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
            inApplicationSupport: url.path.contains("/Library/Application Support/")
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
        duplicates.reduce(0) { $0 &+ $1.logicalSize }
    }

    public var allItems: [ScannedItem] {
        [original] + duplicates
    }
}

public enum AgeBasis: String, CaseIterable, Codable, Sendable {
    case lastAccessedOrModified
    case lastModifiedOnly

    public var displayName: String {
        switch self {
        case .lastAccessedOrModified: "Last Accessed or Modified"
        case .lastModifiedOnly: "Last Modified Only"
        }
    }
}

public struct ScanConfiguration: Codable, Sendable, Equatable {
    public var roots: [URL]
    public var downloadsOverride: URL?
    public var libraryOverride: URL?
    public var appSearchRootsOverride: [URL]?
    public var categories: Set<ScanCategory>
    public var minDuplicateBytes: UInt64
    public var largeFileThresholdBytes: UInt64
    public var oldFileThresholdDays: Int
    public var ageBasis: AgeBasis
    public var excludedFolders: [String]
    public var allowAppBundles: Bool
    public var skipHiddenFiles: Bool

    public init(
        roots: [URL] = [FileManager.default.homeDirectoryForCurrentUser],
        downloadsOverride: URL? = nil,
        libraryOverride: URL? = nil,
        appSearchRootsOverride: [URL]? = nil,
        categories: Set<ScanCategory> = Set(ScanCategory.allCases),
        minDuplicateBytes: UInt64 = 1_048_576,
        largeFileThresholdBytes: UInt64 = 104_857_600,
        oldFileThresholdDays: Int = 180,
        ageBasis: AgeBasis = .lastAccessedOrModified,
        excludedFolders: [String] = [],
        allowAppBundles: Bool = false,
        skipHiddenFiles: Bool = true
    ) {
        self.roots = roots
        self.downloadsOverride = downloadsOverride
        self.libraryOverride = libraryOverride
        self.appSearchRootsOverride = appSearchRootsOverride
        self.categories = categories
        self.minDuplicateBytes = minDuplicateBytes
        self.largeFileThresholdBytes = largeFileThresholdBytes
        self.oldFileThresholdDays = oldFileThresholdDays
        self.ageBasis = ageBasis
        self.excludedFolders = excludedFolders
        self.allowAppBundles = allowAppBundles
        self.skipHiddenFiles = skipHiddenFiles
    }
}

