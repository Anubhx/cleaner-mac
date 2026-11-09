import Foundation

public enum OrphanAppDetector {
    private static let helperSuffixes = [
        ".savedstate",
        ".helper",
        ".agent",
        ".daemon",
        ".launcher",
        ".updater",
        ".framework",
        ".xpc",
        ".findersync",
        ".quicklook",
        ".shareextension",
        ".widget",
        ".loginitem",
        ".service",
        ".webkit",
    ]

    private static let protectedPrefixes = [
        "com.apple.",
        "org.chromium.",
        "com.google.keystone",
        "org.qt-project.",
        "io.qt.",
        "com.github.electron",
        "com.electron.",
    ]

    public static func isOrphan(entryName: String, installedBundleIDs: Set<String>) -> Bool {
        guard !installedBundleIDs.isEmpty else { return false }

        let normalized = entryName.lowercased()
        let stripped = stripHelperSuffixes(normalized)
        guard isBundleIDLike(stripped) else { return false }

        if protectedPrefixes.contains(where: { stripped == $0 || stripped.hasPrefix($0) }) {
            return false
        }

        let lowerInstalled = Set(installedBundleIDs.map { $0.lowercased() })
        for installedID in lowerInstalled {
            if sharesDottedLineage(installedID, normalized) || sharesDottedLineage(installedID, stripped) {
                return false
            }
        }
        return true
    }

    static func sharesDottedLineage(_ lhs: String, _ rhs: String) -> Bool {
        lhs == rhs || lhs.hasPrefix(rhs + ".") || rhs.hasPrefix(lhs + ".")
    }

    static func isBundleIDLike(_ candidate: String) -> Bool {
        let parts = candidate.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 3, parts.allSatisfy({ !$0.isEmpty }) else { return false }
        return candidate.allSatisfy { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_" }
    }

    static func stripHelperSuffixes(_ identifier: String) -> String {
        var current = identifier
        var changed = true
        while changed {
            changed = false
            for suffix in helperSuffixes where current.hasSuffix(suffix) && current.count > suffix.count {
                current = String(current.dropLast(suffix.count))
                changed = true
            }
        }
        return current
    }
}

