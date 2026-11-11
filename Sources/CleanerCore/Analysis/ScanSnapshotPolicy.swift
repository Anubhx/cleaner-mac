import Foundation

public enum SnapshotStaleness: String, Equatable, Sendable {
    case fresh
    case subtle
    case stale

    public static let subtleThresholdSeconds: TimeInterval = 3_600
    public static let staleThresholdSeconds: TimeInterval = 86_400

    public static func classify(age: TimeInterval) -> SnapshotStaleness {
        let clampedAge = max(0, age)
        if clampedAge < subtleThresholdSeconds {
            return .fresh
        } else if clampedAge <= staleThresholdSeconds {
            return .subtle
        } else {
            return .stale
        }
    }
}

public struct RestoredScanSnapshot: Sendable, Equatable {
    public let snapshotID: UUID
    public let startedAt: Date
    public let finishedAt: Date
    public let configuration: ScanConfiguration
    public let progress: ScanProgress
    public let itemsByCategory: [ScanCategory: [ScannedItem]]
    public let duplicateGroups: [DuplicateGroup]
    public let unavailableRoots: [URL]
    public let unavailableItems: [ScannedItem]
    public let prunedMissingItemCount: Int

    public init(
        snapshotID: UUID,
        startedAt: Date,
        finishedAt: Date,
        configuration: ScanConfiguration,
        progress: ScanProgress,
        itemsByCategory: [ScanCategory: [ScannedItem]],
        duplicateGroups: [DuplicateGroup],
        unavailableRoots: [URL],
        unavailableItems: [ScannedItem],
        prunedMissingItemCount: Int
    ) {
        self.snapshotID = snapshotID
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.configuration = configuration
        self.progress = progress
        self.itemsByCategory = itemsByCategory
        self.duplicateGroups = duplicateGroups
        self.unavailableRoots = unavailableRoots
        self.unavailableItems = unavailableItems
        self.prunedMissingItemCount = prunedMissingItemCount
    }
}

public enum ScanSnapshotRestorer {
    private struct ClassifiedRoot {
        let normalizedPath: String
        let isAvailable: Bool
    }

    public static func restore(
        from snapshot: ScanSnapshot,
        pathExists: (URL) -> Bool
    ) -> RestoredScanSnapshot {
        var classifiedRoots: [ClassifiedRoot] = []
        var unavailableRoots: [URL] = []

        for root in snapshot.configuration.roots {
            let isAvailable = pathExists(root)
            classifiedRoots.append(ClassifiedRoot(
                normalizedPath: normalizedCanonicalPath(root),
                isAvailable: isAvailable
            ))
            if !isAvailable {
                unavailableRoots.append(root)
            }
        }

        let hasAnyAvailableRoot = classifiedRoots.contains(where: \.isAvailable)
        let hasAnyUnavailableRoot = !unavailableRoots.isEmpty

        func belongsToUnavailableRoot(_ itemURL: URL) -> Bool {
            guard hasAnyUnavailableRoot else { return false }
            let itemPath = normalizedCanonicalPath(itemURL)

            var bestMatch: ClassifiedRoot?
            var bestLength = -1
            for root in classifiedRoots {
                guard pathMatchesRoot(itemPath: itemPath, rootPath: root.normalizedPath) else {
                    continue
                }
                if root.normalizedPath.count > bestLength {
                    bestLength = root.normalizedPath.count
                    bestMatch = root
                }
            }

            if let bestMatch {
                return !bestMatch.isAvailable
            }
            return !hasAnyAvailableRoot
        }

        var unavailableItems: [ScannedItem] = []
        var seenUnavailableKeys = Set<String>()
        var prunedMissingItemCount = 0

        func recordUnavailable(_ item: ScannedItem) {
            let key = normalizedCanonicalPath(item.url)
            if seenUnavailableKeys.insert(key).inserted {
                unavailableItems.append(item)
            }
        }

        func isAvailableAndPresent(_ item: ScannedItem) -> Bool {
            if belongsToUnavailableRoot(item.url) {
                recordUnavailable(item)
                return false
            }
            guard pathExists(item.url) else {
                prunedMissingItemCount += 1
                return false
            }
            return true
        }

        var restoredCategories: [ScanCategory: [ScannedItem]] = [:]
        var includedDuplicateCategory = false

        for entry in snapshot.categories {
            if entry.category == .duplicates {
                includedDuplicateCategory = true
                for item in entry.items {
                    _ = isAvailableAndPresent(item)
                }
                continue
            }

            let surviving = entry.items
                .filter { isAvailableAndPresent($0) }
                .map { $0.markedAsKeep(false) }
            restoredCategories[entry.category] = surviving
        }

        var digestMap: [String: [ScannedItem]] = [:]
        for group in snapshot.duplicateGroups {
            let surviving = group.allItems
                .filter { isAvailableAndPresent($0) }
                .map { $0.markedAsKeep(false) }
            guard !surviving.isEmpty else { continue }
            digestMap[group.id, default: []].append(contentsOf: surviving)
        }

        let recomputedGroups = DuplicateGrouper.buildGroups(from: digestMap)
        if includedDuplicateCategory || !recomputedGroups.isEmpty {
            restoredCategories[.duplicates] = recomputedGroups.flatMap(\.allItems)
        }

        return RestoredScanSnapshot(
            snapshotID: snapshot.id,
            startedAt: snapshot.startedAt,
            finishedAt: snapshot.finishedAt,
            configuration: snapshot.configuration,
            progress: snapshot.progress,
            itemsByCategory: restoredCategories,
            duplicateGroups: recomputedGroups,
            unavailableRoots: unavailableRoots,
            unavailableItems: unavailableItems,
            prunedMissingItemCount: prunedMissingItemCount
        )
    }

    private static func normalizedCanonicalPath(_ url: URL) -> String {
        var path = SafetyGuard.canonicalizeFirmlink(url.standardizedFileURL.path(percentEncoded: false))
        while path.count > 1 && path.hasSuffix("/") {
            path.removeLast()
        }
        return path
    }

    private static func pathMatchesRoot(itemPath: String, rootPath: String) -> Bool {
        if rootPath == "/" {
            return itemPath.hasPrefix("/")
        }
        return itemPath == rootPath || itemPath.hasPrefix(rootPath + "/")
    }
}
