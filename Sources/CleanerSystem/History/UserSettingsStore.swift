import Foundation
import CleanerCore

public enum UserSettingsStoreError: Error, LocalizedError, Equatable, Sendable {
    case tempFileCreationFailed(path: String)

    public var errorDescription: String? {
        switch self {
        case .tempFileCreationFailed(let path):
            "Failed to create temporary settings file at \(path)."
        }
    }
}

public actor UserSettingsStore {
    public nonisolated let fileURL: URL

    public static var defaultFileURL: URL {
        AtomicJSONFile.applicationSupportDirectory()
            .appendingPathComponent("settings.json", isDirectory: false)
    }

    public init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.defaultFileURL
    }

    public func load() -> UserSettings? {
        AtomicJSONFile.load(UserSettings.self, from: fileURL)
    }

    public func save(_ settings: UserSettings) throws {
        do {
            try AtomicJSONFile.save(settings, to: fileURL)
        } catch AtomicJSONFileError.tempFileCreationFailed(let path) {
            throw UserSettingsStoreError.tempFileCreationFailed(path: path)
        }
    }

    public func clear() {
        AtomicJSONFile.removeFileAndQuarantinedSiblings(at: fileURL)
    }
}

