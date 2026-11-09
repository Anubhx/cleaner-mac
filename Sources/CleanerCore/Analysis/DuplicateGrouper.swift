import Foundation

public enum DuplicateGrouper {
    public static func buildGroups(from digestMap: [String: [ScannedItem]]) -> [DuplicateGroup] {
        var groups: [DuplicateGroup] = []

        for (digest, rawItems) in digestMap {
            let uniqueInodes = deduplicateHardLinks(rawItems)
            guard uniqueInodes.count >= 2 else { continue }

            let sorted = sortForCanonicalOriginal(uniqueInodes)
            let original = sorted[0]
            let extras = Array(sorted.dropFirst())
            groups.append(DuplicateGroup(id: digest, original: original, duplicates: extras))
        }

        return groups.sorted { lhs, rhs in
            if lhs.reclaimableBytes != rhs.reclaimableBytes {
                return lhs.reclaimableBytes > rhs.reclaimableBytes
            }
            return lhs.original.name.localizedStandardCompare(rhs.original.name) == .orderedAscending
        }
    }

    private static func deduplicateHardLinks(_ items: [ScannedItem]) -> [ScannedItem] {
        var tracker = HardLinkTracker()
        var uniqueByURL = Set<URL>()
        var result: [ScannedItem] = []

        for item in sortForCanonicalOriginal(items) {
            guard uniqueByURL.insert(item.url).inserted else { continue }
            guard tracker.registerIfFirstSighting(of: item.inode) else { continue }
            result.append(item)
        }
        return result
    }

    private static func sortForCanonicalOriginal(_ items: [ScannedItem]) -> [ScannedItem] {
        items.sorted { lhs, rhs in
            let lhsDownloads = lhs.url.path.contains("/Downloads/")
            let rhsDownloads = rhs.url.path.contains("/Downloads/")
            if lhsDownloads != rhsDownloads {
                return !lhsDownloads
            }

            let lhsDate = lhs.createdDate ?? lhs.modifiedDate ?? .distantFuture
            let rhsDate = rhs.createdDate ?? rhs.modifiedDate ?? .distantFuture
            if lhsDate != rhsDate {
                return lhsDate < rhsDate
            }

            let lhsDepth = lhs.url.pathComponents.count
            let rhsDepth = rhs.url.pathComponents.count
            if lhsDepth != rhsDepth {
                return lhsDepth < rhsDepth
            }

            return lhs.url.path < rhs.url.path
        }
    }
}

public enum SelectionMetrics {
    public static func uniqueSelectedBytes(
        items: [ScannedItem],
        selectedIDs: Set<UUID>
    ) -> UInt64 {
        var seenURLs = Set<URL>()
        var total: UInt64 = 0

        for item in items where selectedIDs.contains(item.id) {
            if seenURLs.insert(item.url).inserted {
                total &+= item.reclaimableDiskBytes
            }
        }
        return total
    }
}

