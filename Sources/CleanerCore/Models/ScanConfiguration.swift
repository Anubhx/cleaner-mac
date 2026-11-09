import Foundation

public enum AgeBasis: String, CaseIterable, Codable, Sendable {
    case lastAccessedOrModified
    case lastModifiedOnly

    public var displayName: String {
        switch self {
        case .lastAccessedOrModified: "Last Accessed or Modified"
        case .lastModifiedOnly: "Last Modified Only"
        }
    }
}

public struct ScanConfiguration: Codable, Sendable, Equatable {
    public var roots: [URL]
    public var downloadsOverride: URL?
    public var libraryOverride: URL?
    public var appSearchRootsOverride: [URL]?
    public var homeOverride: URL?
    public var categories: Set<ScanCategory>
    public var minDuplicateBytes: UInt64
    public var largeFileThresholdBytes: UInt64
    public var oldFileThresholdDays: Int
    public var minimumActiveCacheBytes: UInt64
    public var ageBasis: AgeBasis
    public var excludedFolders: [String]
    public var allowAppBundles: Bool
    public var skipHiddenFiles: Bool

    public init(
        roots: [URL] = [FileManager.default.homeDirectoryForCurrentUser],
        downloadsOverride: URL? = nil,
        libraryOverride: URL? = nil,
        appSearchRootsOverride: [URL]? = nil,
        homeOverride: URL? = nil,
        categories: Set<ScanCategory> = Set(ScanCategory.allCases),
        minDuplicateBytes: UInt64 = 1_048_576,
        largeFileThresholdBytes: UInt64 = 104_857_600,
        oldFileThresholdDays: Int = 180,
        minimumActiveCacheBytes: UInt64 = 52_428_800,
        ageBasis: AgeBasis = .lastAccessedOrModified,
        excludedFolders: [String] = [],
        allowAppBundles: Bool = false,
        skipHiddenFiles: Bool = true
    ) {
        self.roots = roots
        self.downloadsOverride = downloadsOverride
        self.libraryOverride = libraryOverride
        self.appSearchRootsOverride = appSearchRootsOverride
        self.homeOverride = homeOverride
        self.categories = categories
        self.minDuplicateBytes = minDuplicateBytes
        self.largeFileThresholdBytes = largeFileThresholdBytes
        self.oldFileThresholdDays = oldFileThresholdDays
        self.minimumActiveCacheBytes = minimumActiveCacheBytes
        self.ageBasis = ageBasis
        self.excludedFolders = excludedFolders
        self.allowAppBundles = allowAppBundles
        self.skipHiddenFiles = skipHiddenFiles
    }
}
