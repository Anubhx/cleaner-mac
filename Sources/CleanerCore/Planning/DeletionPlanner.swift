import Foundation

public enum DeletionMode: Codable, Sendable, Equatable {
    case moveToTrash
    case permanentDelete(confirmed: Bool)

    public var isPermanent: Bool {
        if case .permanentDelete = self { return true }
        return false
    }
}

public enum DeletionPlanError: Error, LocalizedError, Equatable, Sendable {
    case permanentConfirmationRequired

    public var errorDescription: String? {
        switch self {
        case .permanentConfirmationRequired:
            "Permanent deletion requires explicit confirmation before execution."
        }
    }
}

public struct BlockedDeletionItem: Sendable, Equatable {
    public let url: URL
    public let reason: String
    public let verificationStatus: SnapshotVerificationStatus?

    public init(url: URL, reason: String, verificationStatus: SnapshotVerificationStatus? = nil) {
        self.url = url
        self.reason = reason
        self.verificationStatus = verificationStatus
    }
}

public struct PlannedDeletionEntry: Sendable, Equatable {
    public let item: ScannedItem
    public let mode: DeletionMode

    public init(item: ScannedItem, mode: DeletionMode) {
        self.item = item
        self.mode = mode
    }
}

public struct DeletionPlan: Sendable, Equatable {
    public let entries: [PlannedDeletionEntry]
    public let blocked: [BlockedDeletionItem]
    public let mode: DeletionMode
    public let isDryRun: Bool

    public init(
        entries: [PlannedDeletionEntry],
        blocked: [BlockedDeletionItem],
        mode: DeletionMode,
        isDryRun: Bool
    ) {
        self.entries = entries
        self.blocked = blocked
        self.mode = mode
        self.isDryRun = isDryRun
    }

    public var projectedBytes: UInt64 {
        entries.reduce(0) { $0 &+ $1.item.reclaimableDiskBytes }
    }
}

public struct DeletionFailure: Sendable, Equatable {
    public let url: URL
    public let reason: String

    public init(url: URL, reason: String) {
        self.url = url
        self.reason = reason
    }
}

public struct DeletionExecutionReport: Sendable, Equatable {
    public let isDryRun: Bool
    public let mode: DeletionMode
    public let succeededItems: [ScannedItem]
    public let trashHistoryEntries: [TrashHistoryEntry]
    public let blockedItems: [BlockedDeletionItem]
    public let failures: [DeletionFailure]
    public let reclaimedBytes: UInt64

    public init(
        isDryRun: Bool,
        mode: DeletionMode,
        succeededItems: [ScannedItem],
        trashHistoryEntries: [TrashHistoryEntry] = [],
        blockedItems: [BlockedDeletionItem] = [],
        failures: [DeletionFailure] = [],
        reclaimedBytes: UInt64
    ) {
        self.isDryRun = isDryRun
        self.mode = mode
        self.succeededItems = succeededItems
        self.trashHistoryEntries = trashHistoryEntries
        self.blockedItems = blockedItems
        self.failures = failures
        self.reclaimedBytes = reclaimedBytes
    }

    public var succeededCount: Int { succeededItems.count }
}

public enum DeletionPlanner {
    public static func plan(
        items: [ScannedItem],
        mode: DeletionMode,
        dryRun: Bool,
        safetyGuard: SafetyGuard,
        excludedFolders: [String] = [],
        allowAppBundles: Bool = false,
        requireSnapshotVerification: Bool = false,
        liveStatProvider: ((URL) -> LiveFileStat)? = nil
    ) throws -> DeletionPlan {
        if case .permanentDelete(let confirmed) = mode, !confirmed {
            throw DeletionPlanError.permanentConfirmationRequired
        }

        var entries: [PlannedDeletionEntry] = []
        var blocked: [BlockedDeletionItem] = []
        var seenURLs = Set<URL>()

        for item in items {
            guard seenURLs.insert(item.url).inserted else { continue }
            do {
                try safetyGuard.validatePath(
                    item.url,
                    excludedFolders: excludedFolders,
                    allowAppBundles: allowAppBundles
                )
                if requireSnapshotVerification {
                    let live = liveStatProvider?(item.url) ?? .missing
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
                entries.append(PlannedDeletionEntry(item: item, mode: mode))
            } catch {
                blocked.append(BlockedDeletionItem(url: item.url, reason: error.localizedDescription))
            }
        }

        return DeletionPlan(
            entries: entries,
            blocked: blocked,
            mode: mode,
            isDryRun: dryRun
        )
    }
}

