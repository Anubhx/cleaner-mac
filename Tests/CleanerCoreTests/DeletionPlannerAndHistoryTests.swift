import Testing
import Foundation
@testable import CleanerCore

@Suite("DeletionPlanner, DryRun & Restore Receipt Policy")
struct DeletionPlannerAndHistoryTests {
    private let guardPolicy = SafetyGuard(currentUserHome: URL(fileURLWithPath: "/Users/alice"))

    @Test("Requires explicit extra confirmation for permanent deletion")
    func requiresExtraConfirmationForPermanentDelete() {
        let item = ScannedItem(
            url: URL(fileURLWithPath: "/Users/alice/Downloads/old.dmg"),
            name: "old.dmg",
            logicalSize: 500_000,
            allocatedSize: 500_000,
            isDirectory: false,
            category: .largeFiles
        )

        #expect(throws: DeletionPlanError.permanentConfirmationRequired) {
            try DeletionPlanner.plan(
                items: [item],
                mode: .permanentDelete(confirmed: false),
                dryRun: false,
                safetyGuard: guardPolicy
            )
        }

        let confirmed = try? DeletionPlanner.plan(
            items: [item],
            mode: .permanentDelete(confirmed: true),
            dryRun: false,
            safetyGuard: guardPolicy
        )
        #expect(confirmed?.entries.count == 1)
    }

    @Test("Blocks protected paths from entering execution plan and records reason")
    func blocksProtectedItemsInPlan() throws {
        let safeItem = ScannedItem(
            url: URL(fileURLWithPath: "/Users/alice/Downloads/junk.tmp"),
            name: "junk.tmp",
            logicalSize: 1024,
            allocatedSize: 1024,
            isDirectory: false,
            category: .deadFiles
        )
        let sysItem = ScannedItem(
            url: URL(fileURLWithPath: "/System/Library/CoreServices/boot.efi"),
            name: "boot.efi",
            logicalSize: 4096,
            allocatedSize: 4096,
            isDirectory: false,
            category: .largeFiles
        )

        let plan = try DeletionPlanner.plan(
            items: [safeItem, sysItem],
            mode: .moveToTrash,
            dryRun: true,
            safetyGuard: guardPolicy
        )

        #expect(plan.isDryRun == true)
        #expect(plan.entries.map(\.item.url) == [safeItem.url])
        #expect(plan.blocked.count == 1)
        #expect(plan.blocked[0].url == sysItem.url)
        #expect(plan.projectedBytes == 1024)
    }

    @Test("Validates Trash receipts and prevents unsafe or mismatched-inode restores")
    func validatesTrashRestoreReceipts() {
        let trashRoot = "/Users/alice/.Trash"
        let validItem = TrashHistoryEntry(
            id: UUID(),
            originalPath: "/Users/alice/Downloads/report.pdf",
            trashPath: "/Users/alice/.Trash/report.pdf",
            bytes: 2048,
            trashInode: 4455,
            trashedAt: Date()
        )

        #expect(TrashReceiptPolicy.isInsideTrash(validItem.trashPath, userTrashRoot: trashRoot) == true)
        #expect(TrashReceiptPolicy.isInsideTrash("/Users/alice/.Trash/../Documents/file", userTrashRoot: trashRoot) == false)

        let decisionMismatch = TrashReceiptPolicy.planRestore(
            entry: validItem,
            trashExists: true,
            currentTrashInode: 9999,
            originalExists: false,
            userTrashRoot: trashRoot
        )
        #expect(decisionMismatch == .skippedUnsafe(originalPath: validItem.originalPath))

        let decisionValid = TrashReceiptPolicy.planRestore(
            entry: validItem,
            trashExists: true,
            currentTrashInode: 4455,
            originalExists: false,
            userTrashRoot: trashRoot
        )
        #expect(decisionValid == .restore(fromTrash: validItem.trashPath, to: validItem.originalPath))

        let missing = TrashReceiptPolicy.planRestore(
            entry: validItem,
            trashExists: false,
            currentTrashInode: nil,
            originalExists: false,
            userTrashRoot: trashRoot
        )
        #expect(missing == .skippedMissingFromTrash(originalPath: validItem.originalPath))

        let exists = TrashReceiptPolicy.planRestore(
            entry: validItem,
            trashExists: true,
            currentTrashInode: 4455,
            originalExists: true,
            userTrashRoot: trashRoot
        )
        #expect(exists == .skippedOriginalExists(originalPath: validItem.originalPath))
    }

    @Test("Computes deduplicated reclaimable bytes, model labels, and safety error messages")
    func outcomeMetricsAndModelMetadata() {
        let sharedURL = URL(fileURLWithPath: "/Users/alice/Downloads/movie.mkv")
        let keepOrig = ScannedItem(url: URL(fileURLWithPath: "/Users/alice/Downloads/orig.mkv"), name: "orig.mkv", logicalSize: 2000, allocatedSize: 2000, isDirectory: false, category: .duplicates, isRecommendedKeep: true)
        let dupCopy = ScannedItem(url: sharedURL, name: "movie.mkv", logicalSize: 2000, allocatedSize: 2000, isDirectory: false, category: .duplicates, isRecommendedKeep: false)
        let largeCopy = ScannedItem(url: sharedURL, name: "movie.mkv", logicalSize: 2000, allocatedSize: 2000, isDirectory: false, category: .largeFiles)

        let outcome = ScanOutcome(itemsByCategory: [.duplicates: [keepOrig, dupCopy], .largeFiles: [largeCopy]])
        #expect(outcome.totalReclaimableBytes == 2000)

        for cat in ScanCategory.allCases {
            #expect(!cat.displayName.isEmpty)
            #expect(!cat.symbolName.isEmpty)
            #expect(!cat.subtitle.isEmpty)
        }
        #expect(DeletionMode.permanentDelete(confirmed: false).isPermanent == true)
        #expect(DeletionMode.moveToTrash.isPermanent == false)
        #expect(SafetyError.protectedPath("/System").errorDescription?.isEmpty == false)
        #expect(SafetyError.tooManyFiles(10_001).errorDescription?.contains("10000") == true)
    }
}

