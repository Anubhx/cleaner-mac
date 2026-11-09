import Foundation

public struct TrashHistoryEntry: Identifiable, Codable, Sendable, Equatable {
    public let id: UUID
    public let originalPath: String
    public let trashPath: String
    public let bytes: UInt64
    public let trashInode: UInt64?
    public let trashedAt: Date

    public init(
        id: UUID = UUID(),
        originalPath: String,
        trashPath: String,
        bytes: UInt64,
        trashInode: UInt64?,
        trashedAt: Date = Date()
    ) {
        self.id = id
        self.originalPath = originalPath
        self.trashPath = trashPath
        self.bytes = bytes
        self.trashInode = trashInode
        self.trashedAt = trashedAt
    }
}

public enum TrashRestoreDecision: Sendable, Equatable {
    case restore(fromTrash: String, to: String)
    case skippedMissingFromTrash(originalPath: String)
    case skippedOriginalExists(originalPath: String)
    case skippedUnsafe(originalPath: String)
}

public enum TrashReceiptPolicy {
    public static func isInsideTrash(_ rawPath: String, userTrashRoot: String) -> Bool {
        guard !rawPath.isEmpty, !rawPath.contains("\0") else { return false }
        let components = rawPath.split(separator: "/", omittingEmptySubsequences: true)
        guard !components.contains("..") else { return false }

        let normalizedTrash = normalize(userTrashRoot)
        let normalizedPath = normalize(rawPath)
        return normalizedPath.hasPrefix(normalizedTrash + "/")
    }

    public static func planRestore(
        entry: TrashHistoryEntry,
        trashExists: Bool,
        currentTrashInode: UInt64?,
        originalExists: Bool,
        userTrashRoot: String
    ) -> TrashRestoreDecision {
        guard trashExists else {
            return .skippedMissingFromTrash(originalPath: entry.originalPath)
        }
        guard isInsideTrash(entry.trashPath, userTrashRoot: userTrashRoot),
              let expectedInode = entry.trashInode,
              let actualInode = currentTrashInode,
              expectedInode == actualInode else {
            return .skippedUnsafe(originalPath: entry.originalPath)
        }
        guard !originalExists else {
            return .skippedOriginalExists(originalPath: entry.originalPath)
        }
        return .restore(fromTrash: entry.trashPath, to: entry.originalPath)
    }

    private static func normalize(_ path: String) -> String {
        let trimmed = path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
        return SafetyGuard.canonicalizeFirmlink(trimmed)
    }
}

