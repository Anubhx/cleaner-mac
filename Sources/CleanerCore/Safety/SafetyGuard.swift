import Foundation

public struct SafetyGuard: Sendable {
    public static let maxFilesPerOperation = 10_000

    private static let protectedPrefixes: [String] = [
        "/System",
        "/Library",
        "/usr",
        "/bin",
        "/sbin",
        "/etc",
        "/var/db",
        "/var/root",
        "/var/vm",
        "/dev",
        "/Network",
        "/cores",
    ]

    public let currentUserHome: URL

    public init(currentUserHome: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.currentUserHome = currentUserHome.standardizedFileURL
    }

    public static func canonicalizeFirmlink(_ path: String) -> String {
        let trimmed = stripTrailingSlash(path)
        for firmlink in ["/private/var", "/private/tmp", "/private/etc"] {
            if trimmed == firmlink || trimmed.hasPrefix(firmlink + "/") {
                return String(trimmed.dropFirst("/private".count))
            }
        }
        return trimmed
    }

    public func validateRawPath(
        _ rawPath: String,
        excludedFolders: [String] = [],
        allowAppBundles: Bool = false
    ) throws {
        guard !rawPath.isEmpty else { throw SafetyError.invalidPath("(empty)") }
        guard !rawPath.contains("\0") else { throw SafetyError.invalidPath(rawPath) }
        try validatePath(
            URL(fileURLWithPath: rawPath),
            excludedFolders: excludedFolders,
            allowAppBundles: allowAppBundles
        )
    }

    public func validatePath(
        _ url: URL,
        excludedFolders: [String] = [],
        allowAppBundles: Bool = false
    ) throws {
        if url.relativePath == "." || url.relativePath.isEmpty {
            throw SafetyError.invalidPath("(empty)")
        }

        let raw = Self.stripTrailingSlash(url.path(percentEncoded: false))
        guard !raw.isEmpty else { throw SafetyError.invalidPath("(empty)") }
        guard !raw.contains("\0") else { throw SafetyError.invalidPath(raw) }

        let canonical = Self.canonicalizeFirmlink(
            Self.stripTrailingSlash(url.standardizedFileURL.path(percentEncoded: false))
        )
        guard !canonical.isEmpty else { throw SafetyError.invalidPath("(empty)") }

        try validateProtectedPrefixes(canonical, displayPath: raw)
        try validateUserScope(canonical, displayPath: raw)
        try validateAppBundle(url: url, allowAppBundles: allowAppBundles, displayPath: raw)
        try validateExclusions(canonical, excludedFolders: excludedFolders, displayPath: raw)
    }

    public func validateResolvedTarget(
        original: URL,
        resolved: URL,
        excludedFolders: [String] = [],
        allowAppBundles: Bool = false
    ) throws {
        try validatePath(original, excludedFolders: excludedFolders, allowAppBundles: allowAppBundles)
        let resolvedDisplay = Self.stripTrailingSlash(resolved.path(percentEncoded: false))
        let resolvedCanonical = Self.canonicalizeFirmlink(
            Self.stripTrailingSlash(resolved.standardizedFileURL.path(percentEncoded: false))
        )

        do {
            try validateProtectedPrefixes(resolvedCanonical, displayPath: resolvedDisplay)
            try validateUserScope(resolvedCanonical, displayPath: resolvedDisplay)
        } catch {
            throw SafetyError.symlinkEscape(resolvedDisplay)
        }

        try validateAppBundle(url: resolved, allowAppBundles: allowAppBundles, displayPath: resolvedDisplay)
        try validateExclusions(resolvedCanonical, excludedFolders: excludedFolders, displayPath: resolvedDisplay)
    }

    public func validateBatch(
        _ urls: [URL],
        excludedFolders: [String] = [],
        allowAppBundles: Bool = false
    ) throws {
        if urls.count > Self.maxFilesPerOperation {
            throw SafetyError.tooManyFiles(urls.count)
        }
        for url in urls {
            try validatePath(url, excludedFolders: excludedFolders, allowAppBundles: allowAppBundles)
        }
    }

    public func isScanDirectoryAllowed(_ url: URL, excludedFolders: [String] = []) -> Bool {
        let canonical = Self.canonicalizeFirmlink(url.standardizedFileURL.path(percentEncoded: false))
        for prefix in Self.protectedPrefixes where Self.matchesBoundary(canonical, prefix: prefix) {
            return false
        }
        if canonical.hasPrefix("/Users/") {
            let homeCanonical = Self.canonicalizeFirmlink(currentUserHome.path(percentEncoded: false))
            if homeCanonical.hasPrefix("/Users/") && !Self.matchesBoundary(canonical, prefix: homeCanonical) {
                return false
            }
        }
        for excluded in excludedFolders {
            let excludedCanonical = Self.canonicalizeFirmlink(
                URL(fileURLWithPath: excluded).standardizedFileURL.path(percentEncoded: false)
            )
            if Self.matchesBoundary(canonical, prefix: excludedCanonical) {
                return false
            }
        }
        return true
    }

    private func validateProtectedPrefixes(_ canonical: String, displayPath: String) throws {
        if canonical == "/" { throw SafetyError.protectedPath(displayPath) }
        for prefix in Self.protectedPrefixes where Self.matchesBoundary(canonical, prefix: prefix) {
            throw SafetyError.protectedPath(displayPath)
        }
    }

    private func validateUserScope(_ canonical: String, displayPath: String) throws {
        let homeCanonical = Self.canonicalizeFirmlink(currentUserHome.path(percentEncoded: false))
        if canonical == "/Users" { throw SafetyError.outsideUserScope(displayPath) }
        if canonical.hasPrefix("/Users/") {
            let allowedPrefix = homeCanonical.hasPrefix("/Users/") ? homeCanonical : "/Users/\(NSUserName())"
            if !Self.matchesBoundary(canonical, prefix: allowedPrefix) {
                throw SafetyError.outsideUserScope(displayPath)
            }
        }
    }

    private func validateAppBundle(url: URL, allowAppBundles: Bool, displayPath: String) throws {
        guard !allowAppBundles else { return }
        let isInBundle = url.pathComponents.contains { $0.lowercased().hasSuffix(".app") }
        if isInBundle { throw SafetyError.appBundleProtected(displayPath) }
    }

    private func validateExclusions(_ canonical: String, excludedFolders: [String], displayPath: String) throws {
        for folder in excludedFolders where !folder.isEmpty {
            let excludedCanonical = Self.canonicalizeFirmlink(
                URL(fileURLWithPath: folder).standardizedFileURL.path(percentEncoded: false)
            )
            if Self.matchesBoundary(canonical, prefix: excludedCanonical) {
                throw SafetyError.userExcluded(displayPath)
            }
        }
    }

    private static func stripTrailingSlash(_ path: String) -> String {
        path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }

    private static func matchesBoundary(_ path: String, prefix: String) -> Bool {
        path == prefix || path.hasPrefix(prefix + "/")
    }
}
