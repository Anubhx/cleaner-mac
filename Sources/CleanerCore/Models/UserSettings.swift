import Foundation

public enum ResultSortOrder: String, CaseIterable, Codable, Sendable {
    case sizeDescending = "Largest First"
    case dateOldest = "Oldest First"
    case nameAscending = "Name (A–Z)"
    case riskHighest = "Highest Risk"
}

public enum UserSettingsError: Error, LocalizedError, Equatable, Sendable {
    case unsupportedSchemaVersion(found: Int, supported: Int)

    public var errorDescription: String? {
        switch self {
        case .unsupportedSchemaVersion(let found, let supported):
            "Unsupported settings schema version \(found); expected \(supported)."
        }
    }
}

public struct UserSettings: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1
    public static let defaultConfiguration = ScanConfiguration()

    public var schemaVersion: Int
    public var scanRoots: [URL]
    public var excludedFolders: [String]
    public var largeFileThresholdBytes: UInt64
    public var minDuplicateBytes: UInt64
    public var oldFileThresholdDays: Int
    public var minimumActiveCacheBytes: UInt64
    public var ageBasis: AgeBasis
    public var selectedCategories: [ScanCategory]
    public var skipHiddenFiles: Bool
    public var allowAppBundles: Bool
    public var lastSelectedCategory: ScanCategory
    public var sortOrder: ResultSortOrder
    public var isInspectorVisible: Bool

    public init(
        schemaVersion: Int = UserSettings.currentSchemaVersion,
        scanRoots: [URL] = [FileManager.default.homeDirectoryForCurrentUser],
        excludedFolders: [String] = UserSettings.defaultConfiguration.excludedFolders,
        largeFileThresholdBytes: UInt64 = UserSettings.defaultConfiguration.largeFileThresholdBytes,
        minDuplicateBytes: UInt64 = UserSettings.defaultConfiguration.minDuplicateBytes,
        oldFileThresholdDays: Int = UserSettings.defaultConfiguration.oldFileThresholdDays,
        minimumActiveCacheBytes: UInt64 = UserSettings.defaultConfiguration.minimumActiveCacheBytes,
        ageBasis: AgeBasis = UserSettings.defaultConfiguration.ageBasis,
        selectedCategories: [ScanCategory] = ScanCategory.allCases,
        skipHiddenFiles: Bool = UserSettings.defaultConfiguration.skipHiddenFiles,
        allowAppBundles: Bool = UserSettings.defaultConfiguration.allowAppBundles,
        lastSelectedCategory: ScanCategory = .duplicates,
        sortOrder: ResultSortOrder = .sizeDescending,
        isInspectorVisible: Bool = true
    ) {
        self.schemaVersion = schemaVersion
        self.scanRoots = scanRoots
        self.excludedFolders = excludedFolders
        self.largeFileThresholdBytes = largeFileThresholdBytes
        self.minDuplicateBytes = minDuplicateBytes
        self.oldFileThresholdDays = oldFileThresholdDays
        self.minimumActiveCacheBytes = minimumActiveCacheBytes
        self.ageBasis = ageBasis
        self.selectedCategories = Self.canonicalCategories(from: selectedCategories)
        self.skipHiddenFiles = skipHiddenFiles
        self.allowAppBundles = allowAppBundles
        self.lastSelectedCategory = lastSelectedCategory
        self.sortOrder = sortOrder
        self.isInspectorVisible = isInspectorVisible
    }

    public init(
        configuration: ScanConfiguration,
        lastSelectedCategory: ScanCategory = .duplicates,
        sortOrder: ResultSortOrder = .sizeDescending,
        isInspectorVisible: Bool = true
    ) {
        self.init(
            schemaVersion: Self.currentSchemaVersion,
            scanRoots: configuration.roots,
            excludedFolders: configuration.excludedFolders,
            largeFileThresholdBytes: configuration.largeFileThresholdBytes,
            minDuplicateBytes: configuration.minDuplicateBytes,
            oldFileThresholdDays: configuration.oldFileThresholdDays,
            minimumActiveCacheBytes: configuration.minimumActiveCacheBytes,
            ageBasis: configuration.ageBasis,
            selectedCategories: Self.canonicalCategories(from: configuration.categories),
            skipHiddenFiles: configuration.skipHiddenFiles,
            allowAppBundles: configuration.allowAppBundles,
            lastSelectedCategory: lastSelectedCategory,
            sortOrder: sortOrder,
            isInspectorVisible: isInspectorVisible
        )
    }

    public func applying(to existing: ScanConfiguration) -> ScanConfiguration {
        var updated = existing
        updated.roots = scanRoots.isEmpty ? existing.roots : scanRoots
        updated.excludedFolders = excludedFolders
        updated.largeFileThresholdBytes = largeFileThresholdBytes
        updated.minDuplicateBytes = minDuplicateBytes
        updated.oldFileThresholdDays = oldFileThresholdDays
        updated.minimumActiveCacheBytes = minimumActiveCacheBytes
        updated.ageBasis = ageBasis
        updated.categories = selectedCategories.isEmpty
            ? Set(ScanCategory.allCases)
            : Set(selectedCategories)
        updated.skipHiddenFiles = skipHiddenFiles
        updated.allowAppBundles = allowAppBundles
        return updated
    }

    public static func canonicalCategories(from categories: some Sequence<ScanCategory>) -> [ScanCategory] {
        let selectedSet = Set(categories)
        return ScanCategory.allCases.filter { selectedSet.contains($0) }
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case scanRoots
        case excludedFolders
        case largeFileThresholdBytes
        case minDuplicateBytes
        case oldFileThresholdDays
        case minimumActiveCacheBytes
        case ageBasis
        case selectedCategories
        case skipHiddenFiles
        case allowAppBundles
        case lastSelectedCategory
        case sortOrder
        case isInspectorVisible
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .schemaVersion)
        guard version == Self.currentSchemaVersion else {
            throw UserSettingsError.unsupportedSchemaVersion(
                found: version,
                supported: Self.currentSchemaVersion
            )
        }

        self.schemaVersion = version
        self.scanRoots = try container.decode([URL].self, forKey: .scanRoots)
        self.excludedFolders = try container.decode([String].self, forKey: .excludedFolders)
        self.largeFileThresholdBytes = try container.decode(UInt64.self, forKey: .largeFileThresholdBytes)
        self.minDuplicateBytes = try container.decode(UInt64.self, forKey: .minDuplicateBytes)
        self.oldFileThresholdDays = try container.decode(Int.self, forKey: .oldFileThresholdDays)
        self.minimumActiveCacheBytes = try container.decode(UInt64.self, forKey: .minimumActiveCacheBytes)
        self.ageBasis = try container.decode(AgeBasis.self, forKey: .ageBasis)
        let decodedCategories = try container.decode([ScanCategory].self, forKey: .selectedCategories)
        self.selectedCategories = Self.canonicalCategories(from: decodedCategories)
        self.skipHiddenFiles = try container.decode(Bool.self, forKey: .skipHiddenFiles)
        self.allowAppBundles = try container.decode(Bool.self, forKey: .allowAppBundles)
        self.lastSelectedCategory = try container.decode(ScanCategory.self, forKey: .lastSelectedCategory)
        self.sortOrder = try container.decode(ResultSortOrder.self, forKey: .sortOrder)
        self.isInspectorVisible = try container.decode(Bool.self, forKey: .isInspectorVisible)
    }
}
