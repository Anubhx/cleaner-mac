import Foundation
import CleanerCore

enum CategoryClassifier {
    static func largeFiles(from candidates: [ScannedItem], thresholdBytes: UInt64) -> [ScannedItem] {
        candidates
            .filter { $0.logicalSize >= thresholdBytes }
            .map { makeCategorizedItem(from: $0, category: .largeFiles) }
            .sorted { $0.logicalSize > $1.logicalSize }
    }

    static func oldFiles(
        from candidates: [ScannedItem],
        thresholdDays: Int,
        basis: AgeBasis,
        now: Date = Date()
    ) -> [ScannedItem] {
        let cutoff = now.addingTimeInterval(-TimeInterval(thresholdDays) * 86_400)
        return candidates.compactMap { item -> ScannedItem? in
            let relevantDate: Date?
            switch basis {
            case .lastAccessedOrModified:
                relevantDate = [item.accessedDate, item.modifiedDate].compactMap { $0 }.max()
            case .lastModifiedOnly:
                relevantDate = item.modifiedDate
            }
            guard let relevantDate, relevantDate < cutoff else { return nil }
            return makeCategorizedItem(from: item, category: .oldFiles)
        }
        .sorted { ($0.modifiedDate ?? .distantFuture) < ($1.modifiedDate ?? .distantFuture) }
    }

    static func deadFiles(
        emptyDirectories: [ScannedItem],
        configuration: ScanConfiguration,
        safetyGuard: SafetyGuard
    ) -> [ScannedItem] {
        var combined = emptyDirectories

        let downloadsRoot = configuration.downloadsOverride
            ?? safetyGuard.currentUserHome.appendingPathComponent("Downloads", isDirectory: true)
        combined.append(contentsOf: DeadFileScanner.scanBrokenDownloads(
            downloadsRoot: downloadsRoot,
            safetyGuard: safetyGuard,
            excludedFolders: configuration.excludedFolders
        ))

        let libraryRoot = configuration.libraryOverride
            ?? safetyGuard.currentUserHome.appendingPathComponent("Library", isDirectory: true)
        let appRoots = configuration.appSearchRootsOverride ?? InstalledAppIndex.defaultSearchRoots
        let installedIDs = InstalledAppIndex.installedBundleIDs(in: appRoots)
        combined.append(contentsOf: DeadFileScanner.scanOrphanedAppData(
            libraryRoot: libraryRoot,
            installedBundleIDs: installedIDs,
            safetyGuard: safetyGuard,
            excludedFolders: configuration.excludedFolders
        ))

        var seenURLs = Set<URL>()
        return combined
            .filter { seenURLs.insert($0.url).inserted }
            .sorted { $0.logicalSize > $1.logicalSize }
    }

    private static func makeCategorizedItem(from source: ScannedItem, category: ScanCategory) -> ScannedItem {
        ScannedItem(
            url: source.url,
            name: source.name,
            logicalSize: source.logicalSize,
            allocatedSize: source.allocatedSize,
            isDirectory: source.isDirectory,
            modifiedDate: source.modifiedDate,
            createdDate: source.createdDate,
            accessedDate: source.accessedDate,
            category: category,
            deadKind: source.deadKind,
            inode: source.inode,
            linkCount: source.linkCount,
            isCloudDataless: source.isCloudDataless,
            contentTypeIdentifier: source.contentTypeIdentifier
        )
    }
}
