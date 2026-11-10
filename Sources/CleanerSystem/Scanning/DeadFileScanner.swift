import Foundation
import CleanerCore

public enum DeadFileScanner {
    private static let orphanSubfolders: [(relative: String, inAppSupport: Bool)] = [
        ("Caches", false),
        ("Logs", false),
        ("HTTPStorages", false),
        ("Saved Application State", false),
        ("WebKit", false),
        ("Application Support", true),
    ]

    public static func scanOrphanedAppData(
        libraryRoot: URL,
        installedBundleIDs: Set<String>,
        safetyGuard: SafetyGuard,
        excludedFolders: [String]
    ) -> [ScannedItem] {
        var ignored: Set<String> = []
        return scanOrphanedAppData(
            libraryRoot: libraryRoot,
            installedBundleIDs: installedBundleIDs,
            safetyGuard: safetyGuard,
            excludedFolders: excludedFolders,
            skippedProtectedDirectoryPaths: &ignored
        )
    }

    static func scanOrphanedAppData(
        libraryRoot: URL,
        installedBundleIDs: Set<String>,
        safetyGuard: SafetyGuard,
        excludedFolders: [String],
        skippedProtectedDirectoryPaths: inout Set<String>
    ) -> [ScannedItem] {
        guard !installedBundleIDs.isEmpty else { return [] }

        let fm = FileManager.default
        var results: [ScannedItem] = []

        for (subfolder, isAppSupport) in orphanSubfolders {
            if Task.isCancelled { return results }
            let root = libraryRoot.appendingPathComponent(subfolder, isDirectory: true)
            guard safetyGuard.isScanDirectoryAllowed(root, excludedFolders: excludedFolders) else { continue }

            let entries: [URL]
            do {
                entries = try fm.contentsOfDirectory(
                    at: root,
                    includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey, .creationDateKey],
                    options: [.skipsHiddenFiles]
                )
            } catch {
                if FilesystemProbes.isPermissionError(error) {
                    recordProtectedDirectory(
                        root,
                        boundaries: [libraryRoot],
                        safetyGuard: safetyGuard,
                        excludedFolders: excludedFolders,
                        into: &skippedProtectedDirectoryPaths
                    )
                }
                continue
            }

            for entry in entries {
                if Task.isCancelled { return results }
                let candidateName = entry.lastPathComponent
                guard OrphanAppDetector.isOrphan(
                    entryName: candidateName,
                    installedBundleIDs: installedBundleIDs
                ) else { continue }

                guard (try? safetyGuard.validatePath(entry, excludedFolders: excludedFolders)) != nil else {
                    continue
                }

                let values: URLResourceValues
                do {
                    values = try entry.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey, .creationDateKey])
                } catch {
                    if FilesystemProbes.isPermissionError(error), FilesystemProbes.isDirectoryPath(entry) {
                        skippedProtectedDirectoryPaths.insert(FilesystemProbes.canonicalPath(for: entry))
                    }
                    continue
                }

                let isDir = values.isDirectory ?? true
                guard FilesystemProbes.isCleanableByCurrentProcess(entry) else {
                    if isDir && FilesystemProbes.isUnreadableProtectedDirectory(entry) {
                        skippedProtectedDirectoryPaths.insert(FilesystemProbes.canonicalPath(for: entry))
                    }
                    continue
                }

                let size = isDir
                    ? FilesystemProbes.directorySize(at: entry, skippedProtectedDirectoryPaths: &skippedProtectedDirectoryPaths)
                    : 0
                guard size > 0 else { continue }

                let risk = RiskEvaluator.assess(
                    category: .deadFiles,
                    deadKind: .orphanedAppData,
                    isCloudDataless: false,
                    inApplicationSupport: isAppSupport
                )

                results.append(ScannedItem(
                    url: entry,
                    name: candidateName,
                    logicalSize: size,
                    allocatedSize: size,
                    isDirectory: isDir,
                    modifiedDate: values.contentModificationDate,
                    createdDate: values.creationDate,
                    accessedDate: nil,
                    category: .deadFiles,
                    deadKind: .orphanedAppData,
                    risk: risk,
                    inode: FilesystemProbes.inodeIdentity(for: entry),
                    linkCount: 1,
                    isCloudDataless: false
                ))
            }
        }

        return results
    }

    public static func scanStaleCaches(
        libraryRoot: URL,
        safetyGuard: SafetyGuard,
        excludedFolders: [String],
        staleDays: Int = 30,
        minimumActiveCacheBytes: UInt64 = 52_428_800,
        now: Date = Date()
    ) -> [ScannedItem] {
        var ignored: Set<String> = []
        return scanStaleCaches(
            libraryRoot: libraryRoot,
            safetyGuard: safetyGuard,
            excludedFolders: excludedFolders,
            staleDays: staleDays,
            minimumActiveCacheBytes: minimumActiveCacheBytes,
            now: now,
            skippedProtectedDirectoryPaths: &ignored
        )
    }

    static func scanStaleCaches(
        libraryRoot: URL,
        safetyGuard: SafetyGuard,
        excludedFolders: [String],
        staleDays: Int = 30,
        minimumActiveCacheBytes: UInt64 = 52_428_800,
        now: Date = Date(),
        skippedProtectedDirectoryPaths: inout Set<String>
    ) -> [ScannedItem] {
        let fm = FileManager.default
        let cachesRoot = libraryRoot.appendingPathComponent("Caches", isDirectory: true)
        guard safetyGuard.isScanDirectoryAllowed(cachesRoot, excludedFolders: excludedFolders) else { return [] }

        let keys: [URLResourceKey] = [
            .isDirectoryKey,
            .isSymbolicLinkKey,
            .contentModificationDateKey,
            .creationDateKey,
            .fileSizeKey,
            .fileAllocatedSizeKey,
        ]
        let entries: [URL]
        do {
            entries = try fm.contentsOfDirectory(
                at: cachesRoot,
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles]
            )
        } catch {
            if FilesystemProbes.isPermissionError(error) {
                recordProtectedDirectory(
                    cachesRoot,
                    boundaries: [libraryRoot],
                    safetyGuard: safetyGuard,
                    excludedFolders: excludedFolders,
                    into: &skippedProtectedDirectoryPaths
                )
            }
            return []
        }

        let cutoff = now.addingTimeInterval(-TimeInterval(staleDays) * 86_400)
        var results: [ScannedItem] = []

        for entry in entries {
            if Task.isCancelled { return results }
            let name = entry.lastPathComponent
            if name.lowercased().hasPrefix("com.apple.") { continue }

            let values: URLResourceValues
            do {
                values = try entry.resourceValues(forKeys: Set(keys))
            } catch {
                if FilesystemProbes.isPermissionError(error),
                   FilesystemProbes.isDirectoryPath(entry),
                   (try? safetyGuard.validatePath(entry, excludedFolders: excludedFolders)) != nil {
                    skippedProtectedDirectoryPaths.insert(FilesystemProbes.canonicalPath(for: entry))
                }
                continue
            }

            guard values.isSymbolicLink != true else { continue }
            guard (try? safetyGuard.validatePath(entry, excludedFolders: excludedFolders)) != nil else { continue }

            let isDir = values.isDirectory ?? false
            guard FilesystemProbes.isCleanableByCurrentProcess(entry) else {
                if isDir && FilesystemProbes.isUnreadableProtectedDirectory(entry) {
                    skippedProtectedDirectoryPaths.insert(FilesystemProbes.canonicalPath(for: entry))
                }
                continue
            }

            let size = isDir
                ? FilesystemProbes.directorySize(at: entry, skippedProtectedDirectoryPaths: &skippedProtectedDirectoryPaths)
                : UInt64(max(0, values.fileAllocatedSize ?? values.fileSize ?? 0))
            guard size > 0 else { continue }

            let modified = values.contentModificationDate
            let isStale = modified.map { $0 < cutoff } ?? false
            let isHeavyActive = !isStale && size >= minimumActiveCacheBytes
            guard isStale || isHeavyActive else { continue }

            results.append(ScannedItem(
                url: entry,
                name: name,
                logicalSize: size,
                allocatedSize: size,
                isDirectory: isDir,
                modifiedDate: modified,
                createdDate: values.creationDate,
                accessedDate: nil,
                category: .deadFiles,
                deadKind: .staleCache,
                risk: RiskEvaluator.assess(
                    category: .deadFiles,
                    deadKind: .staleCache,
                    isActiveCache: isHeavyActive
                ),
                inode: FilesystemProbes.inodeIdentity(for: entry),
                linkCount: 1,
                isCloudDataless: false
            ))
        }

        return results
    }

    public static func scanDeveloperCaches(
        homeRoot: URL,
        libraryRoot: URL,
        safetyGuard: SafetyGuard,
        excludedFolders: [String],
        minimumBytes: UInt64 = 10_485_760
    ) -> [ScannedItem] {
        var ignored: Set<String> = []
        return scanDeveloperCaches(
            homeRoot: homeRoot,
            libraryRoot: libraryRoot,
            safetyGuard: safetyGuard,
            excludedFolders: excludedFolders,
            minimumBytes: minimumBytes,
            skippedProtectedDirectoryPaths: &ignored
        )
    }

    static func scanDeveloperCaches(
        homeRoot: URL,
        libraryRoot: URL,
        safetyGuard: SafetyGuard,
        excludedFolders: [String],
        minimumBytes: UInt64 = 10_485_760,
        skippedProtectedDirectoryPaths: inout Set<String>
    ) -> [ScannedItem] {
        var candidates: [(url: URL, displayName: String, isParentOfSubcaches: Bool)] = [
            (homeRoot.appendingPathComponent(".npm/_cacache", isDirectory: true), "npm Package Cache (.npm/_cacache)", false),
            (homeRoot.appendingPathComponent(".npm/_npx", isDirectory: true), "npm npx Cache (.npm/_npx)", false),
            (homeRoot.appendingPathComponent(".gradle/caches", isDirectory: true), "Gradle Build Cache (.gradle/caches)", false),
            (homeRoot.appendingPathComponent(".pnpm-store", isDirectory: true), "pnpm Content Store (.pnpm-store)", false),
            (homeRoot.appendingPathComponent(".bun/install/cache", isDirectory: true), "Bun Package Cache", false),
            (homeRoot.appendingPathComponent(".cache", isDirectory: true), "", true),
            (libraryRoot.appendingPathComponent("Developer/Xcode/DerivedData", isDirectory: true), "Xcode DerivedData", false),
            (libraryRoot.appendingPathComponent("Developer/Xcode/iOS DeviceSupport", isDirectory: true), "Xcode iOS DeviceSupport", false),
            (libraryRoot.appendingPathComponent("Developer/CoreSimulator/Caches", isDirectory: true), "iOS Simulator Caches", false),
        ]

        let boundaries = [homeRoot, libraryRoot]
        let fm = FileManager.default
        var expandedTargets: [(url: URL, label: String)] = []
        for entry in candidates {
            if entry.isParentOfSubcaches {
                guard safetyGuard.isScanDirectoryAllowed(entry.url, excludedFolders: excludedFolders) else { continue }
                do {
                    let subdirs = try fm.contentsOfDirectory(
                        at: entry.url,
                        includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                        options: [.skipsHiddenFiles]
                    )
                    for sub in subdirs {
                        do {
                            let vals = try sub.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                            if vals.isDirectory == true && vals.isSymbolicLink != true {
                                expandedTargets.append((sub, ".cache/\(sub.lastPathComponent)"))
                            }
                        } catch {
                            if FilesystemProbes.isPermissionError(error),
                               FilesystemProbes.isDirectoryPath(sub),
                               (try? safetyGuard.validatePath(sub, excludedFolders: excludedFolders)) != nil {
                                skippedProtectedDirectoryPaths.insert(FilesystemProbes.canonicalPath(for: sub))
                            }
                        }
                    }
                } catch {
                    if FilesystemProbes.isPermissionError(error) {
                        recordProtectedDirectory(
                            entry.url,
                            boundaries: boundaries,
                            safetyGuard: safetyGuard,
                            excludedFolders: excludedFolders,
                            into: &skippedProtectedDirectoryPaths
                        )
                    }
                }
            } else {
                expandedTargets.append((entry.url, entry.displayName))
            }
        }
        candidates.removeAll()

        var results: [ScannedItem] = []
        for target in expandedTargets {
            if Task.isCancelled { return results }
            guard (try? safetyGuard.validatePath(target.url, excludedFolders: excludedFolders)) != nil else {
                continue
            }

            guard fm.fileExists(atPath: target.url.path) else {
                if let unreadableAncestor = FilesystemProbes.nearestUnreadableProtectedDirectory(
                    for: target.url,
                    stoppingAt: boundaries
                ), (try? safetyGuard.validatePath(unreadableAncestor, excludedFolders: excludedFolders)) != nil {
                    skippedProtectedDirectoryPaths.insert(FilesystemProbes.canonicalPath(for: unreadableAncestor))
                }
                continue
            }

            guard FilesystemProbes.isCleanableByCurrentProcess(target.url) else {
                if FilesystemProbes.isUnreadableProtectedDirectory(target.url) {
                    skippedProtectedDirectoryPaths.insert(FilesystemProbes.canonicalPath(for: target.url))
                }
                continue
            }

            let size = FilesystemProbes.directorySize(
                at: target.url,
                skippedProtectedDirectoryPaths: &skippedProtectedDirectoryPaths
            )
            guard size >= minimumBytes else { continue }

            let values = try? target.url.resourceValues(forKeys: [.contentModificationDateKey, .creationDateKey])
            results.append(ScannedItem(
                url: target.url,
                name: target.label,
                logicalSize: size,
                allocatedSize: size,
                isDirectory: true,
                modifiedDate: values?.contentModificationDate,
                createdDate: values?.creationDate,
                accessedDate: nil,
                category: .deadFiles,
                deadKind: .developerCache,
                risk: RiskEvaluator.assess(category: .deadFiles, deadKind: .developerCache),
                inode: FilesystemProbes.inodeIdentity(for: target.url),
                linkCount: 1,
                isCloudDataless: false
            ))
        }
        return results
    }

    public static func scanBrokenDownloads(
        downloadsRoot: URL,
        safetyGuard: SafetyGuard,
        excludedFolders: [String],
        now: Date = Date()
    ) -> [ScannedItem] {
        var ignored: Set<String> = []
        return scanBrokenDownloads(
            downloadsRoot: downloadsRoot,
            safetyGuard: safetyGuard,
            excludedFolders: excludedFolders,
            now: now,
            skippedProtectedDirectoryPaths: &ignored
        )
    }

    static func scanBrokenDownloads(
        downloadsRoot: URL,
        safetyGuard: SafetyGuard,
        excludedFolders: [String],
        now: Date = Date(),
        skippedProtectedDirectoryPaths: inout Set<String>
    ) -> [ScannedItem] {
        guard safetyGuard.isScanDirectoryAllowed(downloadsRoot, excludedFolders: excludedFolders) else { return [] }

        let fm = FileManager.default
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey,
            .isRegularFileKey,
            .fileSizeKey,
            .fileAllocatedSizeKey,
            .contentModificationDateKey,
            .creationDateKey,
            .contentAccessDateKey,
        ]
        let entries: [URL]
        do {
            entries = try fm.contentsOfDirectory(
                at: downloadsRoot,
                includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles]
            )
        } catch {
            if FilesystemProbes.isPermissionError(error) {
                recordProtectedDirectory(
                    downloadsRoot,
                    boundaries: [downloadsRoot],
                    safetyGuard: safetyGuard,
                    excludedFolders: excludedFolders,
                    into: &skippedProtectedDirectoryPaths
                )
            }
            return []
        }

        var items: [ScannedItem] = []
        for entry in entries {
            if Task.isCancelled { return items }
            let values: URLResourceValues
            do {
                values = try entry.resourceValues(forKeys: keys)
            } catch {
                if FilesystemProbes.isPermissionError(error),
                   FilesystemProbes.isDirectoryPath(entry),
                   (try? safetyGuard.validatePath(entry, excludedFolders: excludedFolders)) != nil {
                    skippedProtectedDirectoryPaths.insert(FilesystemProbes.canonicalPath(for: entry))
                }
                continue
            }
            guard values.isRegularFile == true else { continue }
            let size = UInt64(max(0, values.fileSize ?? 0))
            let allocated = UInt64(max(0, values.fileAllocatedSize ?? values.fileSize ?? 0))
            guard BrokenDownloadPolicy.isBrokenDownload(
                fileName: entry.lastPathComponent,
                size: size,
                modifiedAt: values.contentModificationDate,
                now: now
            ) else { continue }

            guard (try? safetyGuard.validatePath(entry, excludedFolders: excludedFolders)) != nil,
                  FilesystemProbes.isCleanableByCurrentProcess(entry) else {
                continue
            }

            items.append(ScannedItem(
                url: entry,
                name: entry.lastPathComponent,
                logicalSize: size,
                allocatedSize: allocated,
                isDirectory: false,
                modifiedDate: values.contentModificationDate,
                createdDate: values.creationDate,
                accessedDate: values.contentAccessDate,
                category: .deadFiles,
                deadKind: .brokenDownload,
                inode: FilesystemProbes.inodeIdentity(for: entry)
            ))
        }
        return items
    }

    public static func isDirectoryEmpty(_ directory: URL) -> Bool {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: []
        ) else {
            return false
        }
        return contents.isEmpty
    }

    private static func recordProtectedDirectory(
        _ candidate: URL,
        boundaries: [URL],
        safetyGuard: SafetyGuard,
        excludedFolders: [String],
        into skippedProtectedDirectoryPaths: inout Set<String>
    ) {
        let resolved = FilesystemProbes.nearestUnreadableProtectedDirectory(
            for: candidate,
            stoppingAt: boundaries
        ) ?? candidate
        guard FilesystemProbes.isDirectoryPath(resolved),
              safetyGuard.isScanDirectoryAllowed(resolved, excludedFolders: excludedFolders),
              (try? safetyGuard.validatePath(resolved, excludedFolders: excludedFolders)) != nil else {
            return
        }
        skippedProtectedDirectoryPaths.insert(FilesystemProbes.canonicalPath(for: resolved))
    }
}
