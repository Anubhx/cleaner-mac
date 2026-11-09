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
    public var startedAt: Date

    public init(
        phase: ScanPhase = .idle,
        currentPath: String = "",
        scannedFiles: Int = 0,
        bytesEvaluated: UInt64 = 0,
        pendingDirectoriesCount: Int = 0,
        startedAt: Date = Date()
    ) {
        self.phase = phase
        self.currentPath = currentPath
        self.scannedFiles = scannedFiles
        self.bytesEvaluated = bytesEvaluated
        self.pendingDirectoriesCount = pendingDirectoriesCount
        self.startedAt = startedAt
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
    public let startedAt: Date

    public init(
        configuration: ScanConfiguration,
        pendingDirectories: [URL],
        candidateFiles: [ScannedItem],
        deadItems: [ScannedItem],
        visitedDirectoryPaths: Set<String>,
        scannedFiles: Int,
        bytesEvaluated: UInt64,
        startedAt: Date
    ) {
        self.configuration = configuration
        self.pendingDirectories = pendingDirectories
        self.candidateFiles = candidateFiles
        self.deadItems = deadItems
        self.visitedDirectoryPaths = visitedDirectoryPaths
        self.scannedFiles = scannedFiles
        self.bytesEvaluated = bytesEvaluated
        self.startedAt = startedAt
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

