import Foundation
import Darwin
import os
import CleanerCore

public enum FilesystemProbes {
    static func canonicalPath(for url: URL) -> String {
        SafetyGuard.canonicalizeFirmlink(url.standardizedFileURL.path(percentEncoded: false))
    }

    static func isPermissionError(_ error: any Error) -> Bool {
        if let cocoaError = error as? CocoaError, cocoaError.code == .fileReadNoPermission {
            return true
        }
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileReadNoPermissionError {
            return true
        }
        if nsError.domain == NSPOSIXErrorDomain && (nsError.code == Int(EPERM) || nsError.code == Int(EACCES)) {
            return true
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
            return isPermissionError(underlying)
        }
        return false
    }

    static func isDirectoryPath(_ url: URL) -> Bool {
        var info = stat()
        guard lstat(url.path(percentEncoded: false), &info) == 0 else {
            return false
        }
        return (info.st_mode & S_IFMT) == S_IFDIR
    }

    static func isUnreadableProtectedDirectory(_ url: URL) -> Bool {
        let path = url.path(percentEncoded: false)
        var info = stat()
        guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else {
            return false
        }
        if (info.st_flags & UInt32(UF_DATAVAULT)) != 0 {
            return true
        }
        if let dir = opendir(path) {
            closedir(dir)
            return false
        }
        return errno == EACCES || errno == EPERM
    }

    static func nearestUnreadableProtectedDirectory(
        for url: URL,
        stoppingAt boundaries: [URL]
    ) -> URL? {
        let canonicalBoundaries = boundaries.map { canonicalPath(for: $0) }
        func isWithinBoundaries(_ path: String) -> Bool {
            canonicalBoundaries.contains { boundary in
                path == boundary || path.hasPrefix(boundary + "/")
            }
        }

        var current = url.standardizedFileURL
        var info = stat()
        while true {
            let path = current.path(percentEncoded: false)
            if lstat(path, &info) == 0 {
                return isUnreadableProtectedDirectory(current) ? current : nil
            }
            guard errno == EACCES || errno == EPERM else {
                return nil
            }
            let parent = current.deletingLastPathComponent().standardizedFileURL
            let parentCanonical = canonicalPath(for: parent)
            guard parent.path != current.path, isWithinBoundaries(parentCanonical) else {
                return nil
            }
            current = parent
        }
    }
    public static func inodeIdentity(for url: URL) -> InodeIdentity? {
        var info = stat()
        guard lstat(url.path(percentEncoded: false), &info) == 0 else {
            return nil
        }
        return InodeIdentity(
            device: UInt64(UInt32(bitPattern: info.st_dev)),
            inode: UInt64(info.st_ino)
        )
    }

    public static func resolveRealPath(_ url: URL) -> URL {
        url.resolvingSymlinksInPath().standardizedFileURL
    }

    public static func isCleanableByCurrentProcess(_ url: URL) -> Bool {
        let path = url.path(percentEncoded: false)
        let parent = (path as NSString).deletingLastPathComponent
        guard access(parent, W_OK) == 0 else { return false }

        var info = stat()
        guard lstat(path, &info) == 0 else { return false }

        let immutableFlags = UInt32(UF_IMMUTABLE | SF_IMMUTABLE) | UInt32(UF_DATAVAULT)
        if (info.st_flags & immutableFlags) != 0 {
            return false
        }

        if (info.st_mode & S_IFMT) == S_IFDIR {
            guard access(path, R_OK | W_OK | X_OK) == 0 else { return false }
        }
        return true
    }

    public static func isCloudDataless(values: URLResourceValues) -> Bool {
        guard values.isUbiquitousItem == true else { return false }
        return values.ubiquitousItemDownloadingStatus == .notDownloaded
    }

    public static func directorySize(at url: URL) -> UInt64 {
        var ignored: Set<String> = []
        return directorySize(at: url, skippedProtectedDirectoryPaths: &ignored)
    }

    static func directorySize(
        at url: URL,
        skippedProtectedDirectoryPaths: inout Set<String>
    ) -> UInt64 {
        if isUnreadableProtectedDirectory(url) {
            skippedProtectedDirectoryPaths.insert(canonicalPath(for: url))
            return 0
        }

        let permissionFailures = OSAllocatedUnfairLock(initialState: Set<String>())
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .fileSizeKey, .fileAllocatedSizeKey]
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: keys,
            options: [],
            errorHandler: { failedURL, error in
                if isPermissionError(error), isDirectoryPath(failedURL) {
                    let canonical = canonicalPath(for: failedURL)
                    permissionFailures.withLock { _ = $0.insert(canonical) }
                }
                return true
            }
        ) else {
            return 0
        }

        var total: UInt64 = 0
        var tracker = HardLinkTracker()
        for case let child as URL in enumerator {
            if Task.isCancelled { break }
            do {
                let values = try child.resourceValues(forKeys: Set(keys))
                guard values.isRegularFile == true else { continue }
                let identity = inodeIdentity(for: child)
                guard tracker.registerIfFirstSighting(of: identity) else { continue }
                let size = UInt64(max(0, values.fileAllocatedSize ?? values.fileSize ?? 0))
                total &+= size
            } catch {
                if isPermissionError(error), isDirectoryPath(child) {
                    let canonical = canonicalPath(for: child)
                    permissionFailures.withLock { _ = $0.insert(canonical) }
                }
            }
        }
        skippedProtectedDirectoryPaths.formUnion(permissionFailures.withLock { $0 })
        return total
    }

    public static func volumeStorageSnapshot(for url: URL) -> VolumeStorageSnapshot? {
        let probeURL = FileManager.default.fileExists(atPath: url.path) ? url : URL(fileURLWithPath: "/")
        let keys: Set<URLResourceKey> = [
            .volumeNameKey,
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
        ]
        guard let values = try? probeURL.resourceValues(forKeys: keys),
              let total = values.volumeTotalCapacity,
              total > 0 else {
            return nil
        }
        let avail = values.volumeAvailableCapacity ?? Int(clamping: values.volumeAvailableCapacityForImportantUsage ?? 0)
        return VolumeStorageSnapshot(
            volumeName: values.volumeName ?? "Macintosh HD",
            totalBytes: UInt64(max(0, total)),
            availableBytes: UInt64(max(0, avail))
        )
    }
}

