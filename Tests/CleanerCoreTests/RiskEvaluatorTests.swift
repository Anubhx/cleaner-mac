import Testing
import Foundation
@testable import CleanerCore

@Suite("RiskEvaluator & Auto-Selection Policy")
struct RiskEvaluatorTests {
    @Test("Every risky category and item explains why it is flagged")
    func everyRiskyItemIncludesClearReason() {
        let dupAssessment = RiskEvaluator.assess(
            category: .duplicates,
            deadKind: nil,
            isCloudDataless: false,
            inApplicationSupport: false
        )
        #expect(dupAssessment.level == .moderate)
        #expect(!dupAssessment.reason.isEmpty)

        let supportAssessment = RiskEvaluator.assess(
            category: .deadFiles,
            deadKind: .orphanedAppData,
            isCloudDataless: false,
            inApplicationSupport: true
        )
        #expect(supportAssessment.level == .moderate)
        #expect(supportAssessment.reason.localizedCaseInsensitiveContains("Application Support"))

        let cloudAssessment = RiskEvaluator.assess(
            category: .largeFiles,
            deadKind: nil,
            isCloudDataless: true,
            inApplicationSupport: false
        )
        #expect(cloudAssessment.level == .high)
        #expect(cloudAssessment.reason.localizedCaseInsensitiveContains("iCloud"))
    }

    @Test("Never auto-selects duplicates, large files, old files, or risky items")
    func neverAutoSelectsRiskyCategories() {
        #expect(RiskEvaluator.allowsAutoSelection(for: .duplicates, risk: .low) == false)
        #expect(RiskEvaluator.allowsAutoSelection(for: .largeFiles, risk: .low) == false)
        #expect(RiskEvaluator.allowsAutoSelection(for: .oldFiles, risk: .low) == false)
        #expect(RiskEvaluator.allowsAutoSelection(for: .deadFiles, risk: .moderate) == false)
        #expect(RiskEvaluator.allowsAutoSelection(for: .deadFiles, risk: .high) == false)
        #expect(RiskEvaluator.allowsAutoSelection(for: .deadFiles, risk: .low) == true)
    }

    @Test("Broken download policy respects 24-hour active grace window")
    func brokenDownloadRespectsGracePeriod() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let recent = now.addingTimeInterval(-2 * 3600)
        let stalled = now.addingTimeInterval(-36 * 3600)

        #expect(BrokenDownloadPolicy.isBrokenDownload(
            fileName: "xcode.dmg.crdownload",
            size: 1024,
            modifiedAt: recent,
            now: now
        ) == false)

        #expect(BrokenDownloadPolicy.isBrokenDownload(
            fileName: "xcode.dmg.crdownload",
            size: 1024,
            modifiedAt: stalled,
            now: now
        ) == true)

        #expect(BrokenDownloadPolicy.isBrokenDownload(
            fileName: "notes.txt",
            size: 0,
            modifiedAt: stalled,
            now: now
        ) == false)
    }
}

