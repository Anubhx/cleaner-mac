import Foundation
import CleanerCore

enum DuplicateScanPipeline {
    static func findDuplicateGroups(_ files: [ScannedItem]) async -> [DuplicateGroup] {
        let sizeBuckets = Dictionary(grouping: files, by: \.logicalSize).values.filter { $0.count >= 2 }
        var partialBuckets: [String: [ScannedItem]] = [:]

        await withTaskGroup(of: (String, ScannedItem)?.self) { group in
            for bucket in sizeBuckets {
                for item in bucket {
                    group.addTask(priority: .utility) {
                        guard !Task.isCancelled,
                              let digest = StreamingHasher.partialDigest(for: item.url) else {
                            return nil
                        }
                        return ("\(item.logicalSize)-\(digest)", item)
                    }
                }
            }
            for await entry in group {
                guard let (key, item) = entry else { continue }
                partialBuckets[key, default: []].append(item)
            }
        }

        let fullCandidates = partialBuckets.values.filter { $0.count >= 2 }.flatMap { $0 }
        var fullBuckets: [String: [ScannedItem]] = [:]

        await withTaskGroup(of: (String, ScannedItem)?.self) { group in
            for item in fullCandidates {
                group.addTask(priority: .utility) {
                    guard !Task.isCancelled,
                          let digest = await StreamingHasher.fullDigest(for: item.url) else {
                        return nil
                    }
                    let dupItem = ScannedItem(
                        url: item.url,
                        name: item.name,
                        logicalSize: item.logicalSize,
                        allocatedSize: item.allocatedSize,
                        isDirectory: false,
                        modifiedDate: item.modifiedDate,
                        createdDate: item.createdDate,
                        accessedDate: item.accessedDate,
                        category: .duplicates,
                        inode: item.inode ?? FilesystemProbes.inodeIdentity(for: item.url),
                        linkCount: item.linkCount,
                        isCloudDataless: item.isCloudDataless,
                        contentTypeIdentifier: item.contentTypeIdentifier
                    )
                    return (digest, dupItem)
                }
            }
            for await entry in group {
                guard let (digest, item) = entry else { continue }
                fullBuckets[digest, default: []].append(item)
            }
        }

        return DuplicateGrouper.buildGroups(from: fullBuckets)
    }
}
