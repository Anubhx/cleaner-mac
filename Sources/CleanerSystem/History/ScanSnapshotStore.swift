import Foundation
import Darwin
import CleanerCore

public enum ScanSnapshotStoreError: Error, LocalizedError, Equatable, Sendable {
    case tempFileCreationFailed(path: String)

    public var errorDescription: String? {
        switch self {
        case .tempFileCreationFailed(let path):
            "Failed to create temporary snapshot file at \(path)."
        }
    }
}

public actor ScanSnapshotStore {
    public nonisolated let fileURL: URL

    public static var defaultFileURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return support
            .appendingPathComponent("CleanerMac", isDirectory: true)
            .appendingPathComponent("session", isDirectory: true)
            .appendingPathComponent("last-scan.json", isDirectory: false)
    }

    public init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.defaultFileURL
    }

    public func load() -> ScanSnapshot? {
        let fileManager = FileManager.default
        let path = fileURL.path(percentEncoded: false)
        guard fileManager.fileExists(atPath: path) else {
            return nil
        }

        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(ScanSnapshot.self, from: data)
        } catch {
            quarantineCorruptedFile(fileManager: fileManager)
            return nil
        }
    }

    public func save(_ snapshot: ScanSnapshot) throws {
        guard snapshot.progress.phase == .completed else {
            return
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(snapshot)

        let fileManager = FileManager.default
        let directoryURL = fileURL.deletingLastPathComponent()
        let directoryPath = directoryURL.path(percentEncoded: false)

        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directoryPath
        )

        let tempURL = directoryURL.appendingPathComponent(
            ".\(fileURL.lastPathComponent).tmp-\(UUID().uuidString)",
            isDirectory: false
        )
        let tempPath = tempURL.path(percentEncoded: false)

        var movedIntoPlace = false
        defer {
            if !movedIntoPlace {
                try? fileManager.removeItem(at: tempURL)
            }
        }

        guard fileManager.createFile(
            atPath: tempPath,
            contents: nil,
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw ScanSnapshotStoreError.tempFileCreationFailed(path: tempPath)
        }
        try fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: tempPath
        )

        let handle = try FileHandle(forWritingTo: tempURL)
        do {
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }

        let renameResult = tempURL.withUnsafeFileSystemRepresentation { sourcePath in
            fileURL.withUnsafeFileSystemRepresentation { destinationPath in
                guard let sourcePath, let destinationPath else {
                    errno = EINVAL
                    return Int32(-1)
                }
                return Darwin.rename(sourcePath, destinationPath)
            }
        }
        guard renameResult == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        movedIntoPlace = true
    }

    private func quarantineCorruptedFile(fileManager: FileManager) {
        let directoryURL = fileURL.deletingLastPathComponent()
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let timestamp = formatter.string(from: Date())
        let baseName = "\(fileURL.lastPathComponent).corrupt-\(timestamp)"
        var destinationURL = directoryURL.appendingPathComponent(baseName, isDirectory: false)

        if fileManager.fileExists(atPath: destinationURL.path(percentEncoded: false)) {
            let uniqueName = "\(baseName)-\(UUID().uuidString.prefix(8))"
            destinationURL = directoryURL.appendingPathComponent(uniqueName, isDirectory: false)
        }

        try? fileManager.moveItem(at: fileURL, to: destinationURL)
    }
}
