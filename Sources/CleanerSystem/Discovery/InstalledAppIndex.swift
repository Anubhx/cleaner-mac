import Foundation

public enum InstalledAppIndex {
    public static let defaultSearchRoots: [URL] = [
        URL(fileURLWithPath: "/Applications"),
        URL(fileURLWithPath: "/Applications/Utilities"),
        URL(fileURLWithPath: "/System/Applications"),
        URL(fileURLWithPath: "/System/Applications/Utilities"),
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications"),
    ]

    public static func installedBundleIDs(in roots: [URL] = defaultSearchRoots) -> Set<String> {
        var ids = Set<String>()
        let fm = FileManager.default

        for root in roots {
            if Task.isCancelled { break }
            guard fm.fileExists(atPath: root.path) else { continue }
            guard let enumerator = fm.enumerator(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for case let candidate as URL in enumerator {
                if Task.isCancelled { break }
                guard candidate.pathExtension.lowercased() == "app" else { continue }
                enumerator.skipDescendants()

                if let bundleID = readBundleIdentifier(appBundle: candidate) {
                    ids.insert(bundleID.lowercased())
                }
            }
        }
        return ids
    }

    private static func readBundleIdentifier(appBundle: URL) -> String? {
        let plistURL = appBundle.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plistURL),
              let object = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dict = object as? [String: Any],
              let bundleID = dict["CFBundleIdentifier"] as? String,
              !bundleID.isEmpty else {
            return nil
        }
        return bundleID
    }
}

