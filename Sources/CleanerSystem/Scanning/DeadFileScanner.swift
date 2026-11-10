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
        guard !installedBundleIDs.isEmpty else { return [] }

        let fm = FileManager.default
        var results: [ScannedItem] = []

        for (subfolder, isAppSupport) in orphanSubfolders {
            let root = libraryRoot.appendingPathComponent(subfolder, isDirectory: true)
            guard let entries = try? fm.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey, .creationDateKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for entry in entries {
                let candidateName = entry.lastPathComponent
                guard OrphanAppDetector.isOrphan(
                    entryName: candidateName,
                    installedBundleIDs: installedBundleIDs
                ) else { continue }

                guard (try? safetyGuard.validatePath(entry, excludedFolders: excludedFolders)) != nil,
                      FilesystemProbes.isCleanableByCurrentProcess(entry) else {
                    continue
                }

                let values = try? entry.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey, .creationDateKey])
                let isDir = values?.isDirectory ?? true
                let size = isDir ? FilesystemProbes.directorySize(at: entry) : 0
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
                    modifiedDate: values?.contentModificationDate,
                    createdDate: values?.creationDate,
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
        let fm = FileManager.default
        let cachesRoot = libraryRoot.appendingPathComponent("Caches", isDirectory: true)
        let keys: [URLResourceKey] = [
            .isDirectoryKey,
            .isSymbolicLinkKey,
            .contentModificationDateKey,
            .creationDateKey,
            .fileSizeKey,
            .fileAllocatedSizeKey,
        ]
        guard let entries = try? fm.contentsOfDirectory(
            at: cachesRoot,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else { return [] }

        let cutoff = now.addingTimeInterval(-TimeInterval(staleDays) * 86_400)
        var results: [ScannedItem] = []

        for entry in entries {
            let name = entry.lastPathComponent
            if name.lowercased().hasPrefix("com.apple.") { continue }
            guard let values = try? entry.resourceValues(forKeys: Set(keys)),
                  values.isSymbolicLink != true else { continue }
            guard (try? safetyGuard.validatePath(entry, excludedFolders: excludedFolders)) != nil,
                  FilesystemProbes.isCleanableByCurrentProcess(entry) else { continue }

            let isDir = values.isDirectory ?? false
            let size = isDir
                ? FilesystemProbes.directorySize(at: entry)
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

        let fm = FileManager.default
        var expandedTargets: [(url: URL, label: String)] = []
        for entry in candidates {
            if entry.isParentOfSubcaches {
                guard let subdirs = try? fm.contentsOfDirectory(
                    at: entry.url,
                    includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                    options: [.skipsHiddenFiles]
                ) else { continue }
                for sub in subdirs {
                    let vals = try? sub.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                    if vals?.isDirectory == true && vals?.isSymbolicLink != true {
                        expandedTargets.append((sub, ".cache/\(sub.lastPathComponent)"))
                    }
                }
            } else {
                expandedTargets.append((entry.url, entry.displayName))
            }
        }
        candidates.removeAll()

        var results: [ScannedItem] = []
        for target in expandedTargets {
            guard fm.fileExists(atPath: target.url.path),
                  (try? safetyGuard.validatePath(target.url, excludedFolders: excludedFolders)) != nil,
                  FilesystemProbes.isCleanableByCurrentProcess(target.url) else {
                continue
            }

            let size = FilesystemProbes.directorySize(at: target.url)
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
        let fm = FileManager.default
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .fileSizeKey,
            .fileAllocatedSizeKey,
            .contentModificationDateKey,
            .creationDateKey,
            .contentAccessDateKey,
        ]
        guard let entries = try? fm.contentsOfDirectory(
            at: downloadsRoot,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var items: [ScannedItem] = []
        for entry in entries {
            guard let values = try? entry.resourceValues(forKeys: keys),
                  values.isRegularFile == true else { continue }
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
}

