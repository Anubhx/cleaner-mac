import Testing
import Foundation
@testable import CleanerCore

@Suite("OrphanAppDetector Lineage & Safety")
struct OrphanAppDetectorTests {
    @Test("Fail-safe refuses to flag anything when installed bundle set is empty")
    func emptyInstalledSetNeverFlagsOrphans() {
        #expect(OrphanAppDetector.isOrphan(
            entryName: "com.acme.RemovedApp",
            installedBundleIDs: []
        ) == false)
    }

    @Test("Never flags Apple system or shared runtime bundle identifiers")
    func ignoresProtectedAndSharedPrefixes() {
        let installed: Set<String> = ["com.example.installed"]
        let protected = [
            "com.apple.Safari",
            "org.chromium.Chromium",
            "com.google.Keystone",
            "com.electron.helper",
            "org.qt-project.Qt",
        ]
        for id in protected {
            #expect(OrphanAppDetector.isOrphan(entryName: id, installedBundleIDs: installed) == false)
        }
    }

    @Test("Strips helper suffixes and honors dotted lineage without company-wide collisions")
    func stripsHelperSuffixesAndChecksLineage() {
        let installed: Set<String> = ["com.adobe.photoshop", "com.acme.notes"]

        #expect(OrphanAppDetector.isOrphan(
            entryName: "com.acme.notes.helper",
            installedBundleIDs: installed
        ) == false)

        #expect(OrphanAppDetector.isOrphan(
            entryName: "com.acme.notes.savedState",
            installedBundleIDs: installed
        ) == false)

        #expect(OrphanAppDetector.isOrphan(
            entryName: "com.adobe.illustrator",
            installedBundleIDs: installed
        ) == true)

        #expect(OrphanAppDetector.isOrphan(
            entryName: "cache.db",
            installedBundleIDs: installed
        ) == false)
    }
}

