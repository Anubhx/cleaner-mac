import Foundation
import Darwin

public enum FullDiskAccessStatus: String, Sendable, Equatable {
    case granted
    case notGranted
    case unknown

    public var isGranted: Bool {
        self == .granted
    }

    public var summaryLabel: String {
        switch self {
        case .granted:
            "Full Disk Access Granted"
        case .notGranted:
            "Full Disk Access Not Granted"
        case .unknown:
            "Access Status Unverified"
        }
    }
}

public protocol FullDiskAccessChecking: Sendable {
    var settingsURL: URL { get }
    func checkStatus() -> FullDiskAccessStatus
}

public struct SystemFullDiskAccessChecker: FullDiskAccessChecking {
    public static let fullDiskAccessSettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
    )!

    public let homeDirectory: URL

    public init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.homeDirectory = homeDirectory.standardizedFileURL
    }

    public var settingsURL: URL {
        Self.fullDiskAccessSettingsURL
    }

    public func checkStatus() -> FullDiskAccessStatus {
        let fileProbes = [
            homeDirectory.appendingPathComponent("Library/Application Support/com.apple.TCC/TCC.db").path,
            homeDirectory.appendingPathComponent("Library/Safari/Bookmarks.plist").path,
            homeDirectory.appendingPathComponent("Library/Messages/chat.db").path,
        ]

        var sawPermissionDenied = false

        for path in fileProbes {
            let fd = open(path, O_RDONLY)
            if fd >= 0 {
                close(fd)
                return .granted
            }
            if errno == EPERM || errno == EACCES {
                sawPermissionDenied = true
            }
        }

        let directoryProbes = [
            homeDirectory.appendingPathComponent("Library/Mail", isDirectory: true).path,
            homeDirectory.appendingPathComponent("Library/Safari", isDirectory: true).path,
            homeDirectory.appendingPathComponent("Library/Application Support/com.apple.TCC", isDirectory: true).path,
        ]

        for path in directoryProbes {
            if let dir = opendir(path) {
                closedir(dir)
                return .granted
            }
            if errno == EPERM || errno == EACCES {
                sawPermissionDenied = true
            }
        }

        return sawPermissionDenied ? .notGranted : .unknown
    }
}

