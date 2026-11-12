import Foundation
import Darwin

enum AtomicJSONFileError: Error {
    case tempFileCreationFailed(path: String)
}

enum AtomicJSONFile {
    static func applicationSupportDirectory() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return support.appendingPathComponent("CleanerMac", isDirectory: true)
    }

    static func load<T: Decodable>(_ type: T.Type, from fileURL: URL) -> T? {
        let fileManager = FileManager.default
        let path = fileURL.path(percentEncoded: false)
        guard fileManager.fileExists(atPath: path) else {
            return nil
        }

        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(T.self, from: data)
        } catch {
            quarantineCorruptedFile(at: fileURL, fileManager: fileManager)
            return nil
        }
    }

    static func save<T: Encodable>(_ value: T, to fileURL: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(value)
        try saveData(data, to: fileURL)
    }

    static func saveData(_ data: Data, to fileURL: URL) throws {

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
            throw AtomicJSONFileError.tempFileCreationFailed(path: tempPath)
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

    static func quarantineCorruptedFile(at fileURL: URL, fileManager: FileManager = .default) {
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

    static func removeFileAndQuarantinedSiblings(at fileURL: URL, fileManager: FileManager = .default) {
        let targetPath = fileURL.path(percentEncoded: false)
        if fileManager.fileExists(atPath: targetPath) {
            try? fileManager.removeItem(at: fileURL)
        }

        let directoryURL = fileURL.deletingLastPathComponent()
        let corruptPrefix = "\(fileURL.lastPathComponent).corrupt-"
        guard let siblings = try? fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil,
            options: []
        ) else {
            return
        }
        for sibling in siblings where sibling.lastPathComponent.hasPrefix(corruptPrefix) {
            try? fileManager.removeItem(at: sibling)
        }
    }
}

