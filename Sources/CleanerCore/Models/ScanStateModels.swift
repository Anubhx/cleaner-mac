import Foundation

public enum ScanPhase: String, Codable, Sendable, Equatable {
    case idle
    case enumerating
    case hashingDuplicates
    case paused
    case completed
    case cancelled
}

public struct ScanProgress: Codable, Sendable, Equatable {
    public var phase: ScanPhase
    public var currentPath: String
    public var scannedFiles: Int
    public var bytesEvaluated: UInt64
    public var pendingDirectoriesCount: Int
    public var skippedProtectedDirectories: Int
    public var startedAt: Date

    public init(
        phase: ScanPhase = .idle,
        currentPath: String = "",
        scannedFiles: Int = 0,
        bytesEvaluated: UInt64 = 0,
        pendingDirectoriesCount: Int = 0,
        skippedProtectedDirectories: Int = 0,
        startedAt: Date = Date()
    ) {
        self.phase = phase
        self.currentPath = currentPath
        self.scannedFiles = scannedFiles
        self.bytesEvaluated = bytesEvaluated
        self.pendingDirectoriesCount = pendingDirectoriesCount
        self.skippedProtectedDirectories = skippedProtectedDirectories
        self.startedAt = startedAt
    }

    private enum CodingKeys: String, CodingKey {
        case phase
        case currentPath
        case scannedFiles
        case bytesEvaluated
        case pendingDirectoriesCount
        case skippedProtectedDirectories
        case startedAt
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.phase = try container.decode(ScanPhase.self, forKey: .phase)
        self.currentPath = try container.decode(String.self, forKey: .currentPath)
        self.scannedFiles = try container.decode(Int.self, forKey: .scannedFiles)
        self.bytesEvaluated = try container.decode(UInt64.self, forKey: .bytesEvaluated)
        self.pendingDirectoriesCount = try container.decode(Int.self, forKey: .pendingDirectoriesCount)
        self.skippedProtectedDirectories = try container.decodeIfPresent(Int.self, forKey: .skippedProtectedDirectories) ?? 0
        self.startedAt = try container.decode(Date.self, forKey: .startedAt)
    }
}

public struct ScanCheckpoint: Codable, Sendable, Equatable {
    public let configuration: ScanConfiguration
    public let pendingDirectories: [URL]
    public let candidateFiles: [ScannedItem]
    public let deadItems: [ScannedItem]
    public let visitedDirectoryPaths: Set<String>
    public let scannedFiles: Int
    public let bytesEvaluated: UInt64
    public let skippedProtectedDirectories: Int
    public let startedAt: Date

    public init(
        configuration: ScanConfiguration,
        pendingDirectories: [URL],
        candidateFiles: [ScannedItem],
        deadItems: [ScannedItem],
        visitedDirectoryPaths: Set<String>,
        scannedFiles: Int,
        bytesEvaluated: UInt64,
        skippedProtectedDirectories: Int = 0,
        startedAt: Date
    ) {
        self.configuration = configuration
        self.pendingDirectories = pendingDirectories
        self.candidateFiles = candidateFiles
        self.deadItems = deadItems
        self.visitedDirectoryPaths = visitedDirectoryPaths
        self.scannedFiles = scannedFiles
        self.bytesEvaluated = bytesEvaluated
        self.skippedProtectedDirectories = skippedProtectedDirectories
        self.startedAt = startedAt
    }

    private enum CodingKeys: String, CodingKey {
        case configuration
        case pendingDirectories
        case candidateFiles
        case deadItems
        case visitedDirectoryPaths
        case scannedFiles
        case bytesEvaluated
        case skippedProtectedDirectories
        case startedAt
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.configuration = try container.decode(ScanConfiguration.self, forKey: .configuration)
        self.pendingDirectories = try container.decode([URL].self, forKey: .pendingDirectories)
        self.candidateFiles = try container.decode([ScannedItem].self, forKey: .candidateFiles)
        self.deadItems = try container.decode([ScannedItem].self, forKey: .deadItems)
        self.visitedDirectoryPaths = try container.decode(Set<String>.self, forKey: .visitedDirectoryPaths)
        self.scannedFiles = try container.decode(Int.self, forKey: .scannedFiles)
        self.bytesEvaluated = try container.decode(UInt64.self, forKey: .bytesEvaluated)
        self.skippedProtectedDirectories = try container.decodeIfPresent(Int.self, forKey: .skippedProtectedDirectories) ?? 0
        self.startedAt = try container.decode(Date.self, forKey: .startedAt)
    }
}

public struct ScanBatch: Sendable, Equatable {
    public let items: [ScannedItem]
    public let progress: ScanProgress

    public init(items: [ScannedItem], progress: ScanProgress) {
        self.items = items
        self.progress = progress
    }
}

public struct ScanOutcome: Sendable, Equatable {
    public let itemsByCategory: [ScanCategory: [ScannedItem]]
    public let duplicateGroups: [DuplicateGroup]
    public let progress: ScanProgress
    public let wasCancelled: Bool

    public init(
        itemsByCategory: [ScanCategory: [ScannedItem]] = [:],
        duplicateGroups: [DuplicateGroup] = [],
        progress: ScanProgress = ScanProgress(),
        wasCancelled: Bool = false
    ) {
        self.itemsByCategory = itemsByCategory
        self.duplicateGroups = duplicateGroups
        self.progress = progress
        self.wasCancelled = wasCancelled
    }

    public func items(in category: ScanCategory) -> [ScannedItem] {
        itemsByCategory[category] ?? []
    }

    public var allItems: [ScannedItem] {
        ScanCategory.allCases.flatMap { items(in: $0) }
    }

    public var totalReclaimableBytes: UInt64 {
        var seenURLs = Set<URL>()
        var total: UInt64 = 0
        for item in allItems where !item.isRecommendedKeep {
            if seenURLs.insert(item.url).inserted {
                total &+= item.reclaimableDiskBytes
            }
        }
        return total
    }
}

