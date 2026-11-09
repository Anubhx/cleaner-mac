import Foundation
import CleanerCore

public protocol TrashDriver: Sendable {
    var trashRootPath: String { get }
    func moveToTrash(url: URL) throws -> URL
}

public struct SystemTrashDriver: TrashDriver {
    public init() {}

    public var trashRootPath: String {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash").path
    }

    public func moveToTrash(url: URL) throws -> URL {
        var resultingURL: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &resultingURL)
        return (resultingURL as URL?) ?? url
    }
}

public struct DirectoryTrashDriver: TrashDriver {
    public let trashDirectory: URL

    public init(trashDirectory: URL) {
        self.trashDirectory = trashDirectory
    }

    public var trashRootPath: String { trashDirectory.path }

    public func moveToTrash(url: URL) throws -> URL {
        let fm = FileManager.default
        if !fm.fileExists(atPath: trashDirectory.path) {
            try fm.createDirectory(at: trashDirectory, withIntermediateDirectories: true)
        }
        var destination = trashDirectory.appendingPathComponent(url.lastPathComponent)
        if fm.fileExists(atPath: destination.path) {
            let uniqueName = "\(UUID().uuidString)-\(url.lastPathComponent)"
            destination = trashDirectory.appendingPathComponent(uniqueName)
        }
        try fm.moveItem(at: url, to: destination)
        return destination
    }
}

public actor DeletionExecutor {
    private let safetyGuard: SafetyGuard
    private let trashDriver: any TrashDriver

    public init(
        safetyGuard: SafetyGuard = SafetyGuard(),
        trashDriver: any TrashDriver = SystemTrashDriver()
    ) {
        self.safetyGuard = safetyGuard
        self.trashDriver = trashDriver
    }

    public func execute(
        items: [ScannedItem],
        mode: DeletionMode,
        dryRun: Bool,
        excludedFolders: [String] = [],
        allowAppBundles: Bool = false
    ) throws -> DeletionExecutionReport {
        let plan = try DeletionPlanner.plan(
            items: items,
            mode: mode,
            dryRun: dryRun,
            safetyGuard: safetyGuard,
            excludedFolders: excludedFolders,
            allowAppBundles: allowAppBundles
        )

        if dryRun {
            return DeletionExecutionReport(
                isDryRun: true,
                mode: mode,
                succeededItems: plan.entries.map(\.item),
                trashHistoryEntries: [],
                blockedItems: plan.blocked,
                failures: [],
                reclaimedBytes: plan.projectedBytes
            )
        }

        var succeeded: [ScannedItem] = []
        var historyEntries: [TrashHistoryEntry] = []
        var failures: [DeletionFailure] = []
        var reclaimed: UInt64 = 0

        for entry in plan.entries {
            let item = entry.item
            let resolved = FilesystemProbes.resolveRealPath(item.url)

            do {
                try safetyGuard.validateResolvedTarget(
                    original: item.url,
                    resolved: resolved,
                    excludedFolders: excludedFolders,
                    allowAppBundles: allowAppBundles
                )
            } catch {
                failures.append(DeletionFailure(url: item.url, reason: error.localizedDescription))
                continue
            }

            guard FilesystemProbes.isCleanableByCurrentProcess(item.url) else {
                failures.append(DeletionFailure(url: item.url, reason: "Permission denied or protected by macOS flags"))
                continue
            }

            do {
                switch mode {
                case .moveToTrash:
                    let destination = try trashDriver.moveToTrash(url: item.url)
                    let trashInode = FilesystemProbes.inodeIdentity(for: destination)?.inode
                    historyEntries.append(TrashHistoryEntry(
                        originalPath: item.url.path,
                        trashPath: destination.path,
                        bytes: item.logicalSize,
                        trashInode: trashInode
                    ))
                case .permanentDelete:
                    try FileManager.default.removeItem(at: item.url)
                }
                succeeded.append(item)
                reclaimed &+= item.logicalSize
            } catch {
                failures.append(DeletionFailure(url: item.url, reason: error.localizedDescription))
            }
        }

        return DeletionExecutionReport(
            isDryRun: false,
            mode: mode,
            succeededItems: succeeded,
            trashHistoryEntries: historyEntries,
            blockedItems: plan.blocked,
            failures: failures,
            reclaimedBytes: reclaimed
        )
    }

    public func restore(entries: [TrashHistoryEntry]) -> (restoredIDs: Set<UUID>, failures: [DeletionFailure]) {
        let fm = FileManager.default
        var restoredIDs = Set<UUID>()
        var failures: [DeletionFailure] = []

        for entry in entries {
            let trashURL = URL(fileURLWithPath: entry.trashPath)
            let originalURL = URL(fileURLWithPath: entry.originalPath)
            let trashExists = fm.fileExists(atPath: trashURL.path)
            let originalExists = fm.fileExists(atPath: originalURL.path)
            let currentInode = FilesystemProbes.inodeIdentity(for: trashURL)?.inode

            let decision = TrashReceiptPolicy.planRestore(
                entry: entry,
                trashExists: trashExists,
                currentTrashInode: currentInode,
                originalExists: originalExists,
                userTrashRoot: trashDriver.trashRootPath
            )

            switch decision {
            case .restore(let fromTrash, let toOriginal):
                do {
                    let parent = URL(fileURLWithPath: toOriginal).deletingLastPathComponent()
                    try fm.createDirectory(at: parent, withIntermediateDirectories: true)
                    try fm.moveItem(at: URL(fileURLWithPath: fromTrash), to: URL(fileURLWithPath: toOriginal))
                    restoredIDs.insert(entry.id)
                } catch {
                    failures.append(DeletionFailure(url: originalURL, reason: error.localizedDescription))
                }
            case .skippedMissingFromTrash:
                failures.append(DeletionFailure(url: originalURL, reason: "Item is no longer in Trash"))
            case .skippedOriginalExists:
                failures.append(DeletionFailure(url: originalURL, reason: "An item already exists at the original path"))
            case .skippedUnsafe:
                failures.append(DeletionFailure(url: originalURL, reason: "Trash receipt verification failed"))
            }
        }
        return (restoredIDs, failures)
    }
}

