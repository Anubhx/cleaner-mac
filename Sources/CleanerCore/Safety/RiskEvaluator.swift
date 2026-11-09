import Foundation

public enum RiskEvaluator {
    public static func assess(
        category: ScanCategory,
        deadKind: DeadFileKind? = nil,
        isCloudDataless: Bool = false,
        inApplicationSupport: Bool = false
    ) -> RiskAssessment {
        if isCloudDataless {
            return RiskAssessment(
                level: .high,
                reason: "File is an iCloud dataless placeholder; removing it may affect synced cloud copies across devices."
            )
        }

        switch category {
        case .duplicates:
            return RiskAssessment(
                level: .moderate,
                reason: "Exact SHA-256 content duplicate; verify external references or project links before removing this copy."
            )
        case .largeFiles:
            return RiskAssessment(
                level: .moderate,
                reason: "Large user file exceeding size threshold; may contain media, archives, or virtual machines you still need."
            )
        case .oldFiles:
            return RiskAssessment(
                level: .moderate,
                reason: "File has not been accessed or modified recently; confirm it is no longer needed as an archive."
            )
        case .deadFiles:
            return assessDeadFile(kind: deadKind, inApplicationSupport: inApplicationSupport)
        }
    }

    public static func allowsAutoSelection(for category: ScanCategory, risk: RiskLevel) -> Bool {
        guard category == .deadFiles else { return false }
        return risk == .low
    }

    private static func assessDeadFile(
        kind: DeadFileKind?,
        inApplicationSupport: Bool
    ) -> RiskAssessment {
        switch kind {
        case .orphanedAppData:
            if inApplicationSupport {
                return RiskAssessment(
                    level: .moderate,
                    reason: "Orphaned Application Support folder; may hold presets, databases, or license files if you reinstall."
                )
            }
            return RiskAssessment(
                level: .low,
                reason: "Orphaned cache or state directory whose owning application bundle ID is no longer installed."
            )
        case .staleCache:
            return RiskAssessment(
                level: .low,
                reason: "Regenerable application cache file that apps safely recreate on next launch."
            )
        case .brokenDownload:
            return RiskAssessment(
                level: .low,
                reason: "Incomplete browser or transfer file untouched past the 24-hour active download grace period."
            )
        case .emptyDirectory, .none:
            return RiskAssessment(
                level: .low,
                reason: "Empty directory containing no files or subdirectories outside application bundles."
            )
        }
    }
}

public enum BrokenDownloadPolicy {
    private static let partialExtensions: Set<String> = [
        "download",
        "crdownload",
        "part",
        "partial",
        "opdownload",
    ]

    public static func isBrokenDownload(
        fileName: String,
        size: UInt64,
        modifiedAt: Date?,
        now: Date = Date(),
        graceHours: TimeInterval = 24
    ) -> Bool {
        let ext = (fileName as NSString).pathExtension.lowercased()
        guard partialExtensions.contains(ext) else { return false }
        guard let modifiedAt else { return false }
        let age = now.timeIntervalSince(modifiedAt)
        return age >= graceHours * 3600 && size >= 0
    }
}

public enum EmptyDirectoryPolicy {
    private static let protectedDirectoryNames: Set<String> = [
        ".git",
        ".svn",
        ".hg",
        ".Trash",
        ".Spotlight-V100",
        ".fseventsd",
    ]

    private static let bundleExtensions: Set<String> = [
        "app",
        "bundle",
        "framework",
        "kext",
        "plugin",
        "appex",
        "xcodeproj",
        "xcworkspace",
        "playground",
        "photoslibrary",
        "musiclibrary",
        "fcpbundle",
        "imovielibrary",
        "tvlibrary",
        "sparsebundle",
        "sparseimage",
    ]

    public static func shouldInspectDirectory(
        name: String,
        isPackage: Bool,
        isHidden: Bool
    ) -> Bool {
        if isPackage || isHidden { return false }
        if protectedDirectoryNames.contains(name) { return false }
        let ext = (name as NSString).pathExtension.lowercased()
        return !bundleExtensions.contains(ext)
    }
}

