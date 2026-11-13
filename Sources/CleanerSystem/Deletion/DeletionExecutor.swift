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
        allowAppBundles: Bool = false,
        verifySnapshotItems: Bool = false
    ) async throws -> DeletionExecutionReport {
        let guardPolicy = safetyGuard
        let driver = trashDriver

        return try await Task.detached(priority: .userInitiated) {
            try Self.performExecution(
                items: items,
                mode: mode,
                dryRun: dryRun,
                excludedFolders: excludedFolders,
                allowAppBundles: allowAppBundles,
                verifySnapshotItems: verifySnapshotItems,
                safetyGuard: guardPolicy,
                trashDriver: driver
            )
        }.value
    }

    public nonisolated func verifySnapshotItems(_ items: [ScannedItem]) async -> [UUID: SnapshotVerificationStatus] {
        await Task.detached(priority: .userInitiated) {
            var statuses: [UUID: SnapshotVerificationStatus] = [:]
            statuses.reserveCapacity(items.count)
            for item in items {
                if Task.isCancelled { break }
                let live = FilesystemProbes.liveFileStat(for: item.url)
                statuses[item.id] = SnapshotVerificationPolicy.verify(item: item, against: live)
            }
            return statuses
        }.value
    }

    public func restore(entries: [TrashHistoryEntry]) async -> (restoredIDs: Set<UUID>, failures: [DeletionFailure]) {
        let driver = trashDriver
        return await Task.detached(priority: .userInitiated) {
            Self.performRestore(entries: entries, trashDriver: driver)
        }.value
    }

    private nonisolated static func performExecution(
        items: [ScannedItem],
        mode: DeletionMode,
        dryRun: Bool,
        excludedFolders: [String],
        allowAppBundles: Bool,
        verifySnapshotItems: Bool,
        safetyGuard: SafetyGuard,
        trashDriver: any TrashDriver
    ) throws -> DeletionExecutionReport {
        let plan = try DeletionPlanner.plan(
            items: items,
            mode: mode,
            dryRun: dryRun,
            safetyGuard: safetyGuard,
            excludedFolders: excludedFolders,
            allowAppBundles: allowAppBundles,
            requireSnapshotVerification: verifySnapshotItems,
            liveStatProvider: verifySnapshotItems ? { FilesystemProbes.liveFileStat(for: $0) } : nil
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
        var blocked = plan.blocked
        var failures: [DeletionFailure] = []
        var reclaimed: UInt64 = 0

        for entry in plan.entries {
            if Task.isCancelled { break }
            let item = entry.item

            if verifySnapshotItems {
                let live = FilesystemProbes.liveFileStat(for: item.url)
                let verification = SnapshotVerificationPolicy.verify(item: item, against: live)
                if let reason = SnapshotVerificationPolicy.blockedReason(for: verification) {
                    blocked.append(BlockedDeletionItem(
                        url: item.url,
                        reason: reason,
                        verificationStatus: verification
                    ))
                    continue
                }
            }

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
                        bytes: item.reclaimableDiskBytes,
                        trashInode: trashInode
                    ))
                case .permanentDelete:
                    try FileManager.default.removeItem(at: item.url)
                }
                succeeded.append(item)
                reclaimed &+= item.reclaimableDiskBytes
            } catch {
                failures.append(DeletionFailure(url: item.url, reason: error.localizedDescription))
            }
        }

        return DeletionExecutionReport(
            isDryRun: false,
            mode: mode,
            succeededItems: succeeded,
            trashHistoryEntries: historyEntries,
            blockedItems: blocked,
            failures: failures,
            reclaimedBytes: reclaimed
        )
    }

    private nonisolated static func performRestore(
        entries: [TrashHistoryEntry],
        trashDriver: any TrashDriver
    ) -> (restoredIDs: Set<UUID>, failures: [DeletionFailure]) {
        let fm = FileManager.default
        var restoredIDs = Set<UUID>()
        var failures: [DeletionFailure] = []

        for entry in entries {
            if Task.isCancelled { break }
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

