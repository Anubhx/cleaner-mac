import Foundation
import Darwin
import CleanerCore

public enum FilesystemProbes {
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
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .fileAllocatedSizeKey]
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: keys,
            options: []
        ) else {
            return 0
        }

        var total: UInt64 = 0
        var tracker = HardLinkTracker()
        for case let child as URL in enumerator {
            guard let values = try? child.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true else {
                continue
            }
            let identity = inodeIdentity(for: child)
            guard tracker.registerIfFirstSighting(of: identity) else { continue }
            let size = UInt64(max(0, values.fileAllocatedSize ?? values.fileSize ?? 0))
            total &+= size
        }
        return total
    }
}

