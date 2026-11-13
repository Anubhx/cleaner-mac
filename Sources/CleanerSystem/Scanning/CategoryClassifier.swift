import Foundation
import CleanerCore

struct DeadFilesClassification: Sendable, Equatable {
    let items: [ScannedItem]
    let skippedProtectedDirectoryPaths: Set<String>
}

enum CategoryClassifier {
    static func largeFiles(from candidates: [ScannedItem], thresholdBytes: UInt64) -> [ScannedItem] {
        candidates
            .filter { $0.reclaimableDiskBytes >= thresholdBytes }
            .map { makeCategorizedItem(from: $0, category: .largeFiles) }
            .sorted { $0.reclaimableDiskBytes > $1.reclaimableDiskBytes }
    }

    static func oldFiles(
        from candidates: [ScannedItem],
        thresholdDays: Int,
        basis: AgeBasis,
        excludedLibraryPrefix: String? = nil,
        now: Date = Date()
    ) -> [ScannedItem] {
        let cutoff = now.addingTimeInterval(-TimeInterval(thresholdDays) * 86_400)
        return candidates.compactMap { item -> ScannedItem? in
            if let excludedLibraryPrefix {
                let canonical = SafetyGuard.canonicalizeFirmlink(item.url.standardizedFileURL.path(percentEncoded: false))
                if DirectoryFrontierWalker.isInsideUserLibrary(canonical, userLibraryPath: excludedLibraryPrefix) {
                    return nil
                }
            }
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
        deadFilesWithDiagnostics(
            emptyDirectories: emptyDirectories,
            configuration: configuration,
            safetyGuard: safetyGuard
        ).items
    }

    static func deadFilesWithDiagnostics(
        emptyDirectories: [ScannedItem],
        configuration: ScanConfiguration,
        safetyGuard: SafetyGuard
    ) -> DeadFilesClassification {
        var combined = emptyDirectories
        var skippedProtectedDirectoryPaths: Set<String> = []

        let homeRoot = configuration.homeOverride ?? safetyGuard.currentUserHome
        let downloadsRoot = configuration.downloadsOverride
            ?? homeRoot.appendingPathComponent("Downloads", isDirectory: true)
        if !Task.isCancelled {
            combined.append(contentsOf: DeadFileScanner.scanBrokenDownloads(
                downloadsRoot: downloadsRoot,
                safetyGuard: safetyGuard,
                excludedFolders: configuration.excludedFolders,
                skippedProtectedDirectoryPaths: &skippedProtectedDirectoryPaths
            ))
        }

        let libraryRoot = configuration.libraryOverride
            ?? homeRoot.appendingPathComponent("Library", isDirectory: true)
        let appRoots = configuration.appSearchRootsOverride ?? InstalledAppIndex.defaultSearchRoots
        let installedIDs = Task.isCancelled ? [] : InstalledAppIndex.installedBundleIDs(in: appRoots)
        if !Task.isCancelled {
            combined.append(contentsOf: DeadFileScanner.scanOrphanedAppData(
                libraryRoot: libraryRoot,
                installedBundleIDs: installedIDs,
                safetyGuard: safetyGuard,
                excludedFolders: configuration.excludedFolders,
                skippedProtectedDirectoryPaths: &skippedProtectedDirectoryPaths
            ))
        }
        if !Task.isCancelled {
            combined.append(contentsOf: DeadFileScanner.scanStaleCaches(
                libraryRoot: libraryRoot,
                safetyGuard: safetyGuard,
                excludedFolders: configuration.excludedFolders,
                minimumActiveCacheBytes: configuration.minimumActiveCacheBytes,
                skippedProtectedDirectoryPaths: &skippedProtectedDirectoryPaths
            ))
        }
        if !Task.isCancelled {
            combined.append(contentsOf: DeadFileScanner.scanDeveloperCaches(
                homeRoot: homeRoot,
                libraryRoot: libraryRoot,
                safetyGuard: safetyGuard,
                excludedFolders: configuration.excludedFolders,
                minimumBytes: min(10_485_760, configuration.minimumActiveCacheBytes),
                skippedProtectedDirectoryPaths: &skippedProtectedDirectoryPaths
            ))
        }

        var seenURLs = Set<URL>()
        let items = combined
            .filter { seenURLs.insert($0.url).inserted }
            .sorted { $0.logicalSize > $1.logicalSize }
        return DeadFilesClassification(
            items: items,
            skippedProtectedDirectoryPaths: skippedProtectedDirectoryPaths
        )
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
            inode: source.inode ?? FilesystemProbes.inodeIdentity(for: source.url),
            linkCount: source.linkCount,
            isCloudDataless: source.isCloudDataless,
            contentTypeIdentifier: source.contentTypeIdentifier
        )
    }
}

