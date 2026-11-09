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
            guard let modified = values.contentModificationDate, modified < cutoff else { continue }

            let isDir = values.isDirectory ?? false
            let size = isDir
                ? FilesystemProbes.directorySize(at: entry)
                : UInt64(max(0, values.fileAllocatedSize ?? values.fileSize ?? 0))
            guard size > 0 else { continue }

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
                risk: RiskEvaluator.assess(category: .deadFiles, deadKind: .staleCache),
                inode: FilesystemProbes.inodeIdentity(for: entry),
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

