import Foundation

public enum ScanCheckpointError: Error, LocalizedError, Equatable, Sendable {
    case unsupportedSchemaVersion(found: Int, supported: Int)
    case corruptedPayload(reason: String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedSchemaVersion(let found, let supported):
            "Unsupported scan checkpoint schema version \(found); expected \(supported)."
        case .corruptedPayload(let reason):
            "Corrupted scan checkpoint payload: \(reason)"
        }
    }
}

public enum ScanCheckpointPolicy {
    public static let maxAgeSeconds: TimeInterval = 86_400 // 24 hours

    public static func isExpired(savedAt: Date, now: Date = Date()) -> Bool {
        max(0, now.timeIntervalSince(savedAt)) > maxAgeSeconds
    }

    public static func relativeInterruptedDescription(savedAt: Date, relativeTo now: Date = Date()) -> String {
        let elapsed = max(0, now.timeIntervalSince(savedAt))
        if elapsed < 5 {
            return "just now"
        }
        let clampedSavedAt = min(savedAt, now)
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: clampedSavedAt, relativeTo: now)
    }
}

public struct ScanCheckpointEnvelope: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var savedAt: Date
    public var compressionAlgorithm: String
    public var uncompressedByteCount: Int
    public var compressedPayload: Data

    public init(
        schemaVersion: Int = ScanCheckpointEnvelope.currentSchemaVersion,
        savedAt: Date,
        compressionAlgorithm: String,
        uncompressedByteCount: Int,
        compressedPayload: Data
    ) {
        self.schemaVersion = schemaVersion
        self.savedAt = savedAt
        self.compressionAlgorithm = compressionAlgorithm
        self.uncompressedByteCount = uncompressedByteCount
        self.compressedPayload = compressedPayload
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case savedAt
        case compressionAlgorithm
        case uncompressedByteCount
        case compressedPayload
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .schemaVersion)
        guard version == Self.currentSchemaVersion else {
            throw ScanCheckpointError.unsupportedSchemaVersion(
                found: version,
                supported: Self.currentSchemaVersion
            )
        }

        self.schemaVersion = version
        self.savedAt = try container.decode(Date.self, forKey: .savedAt)
        self.compressionAlgorithm = try container.decode(String.self, forKey: .compressionAlgorithm)
        self.uncompressedByteCount = try container.decode(Int.self, forKey: .uncompressedByteCount)
        self.compressedPayload = try container.decode(Data.self, forKey: .compressedPayload)
    }
}

public enum ScanCheckpointLoadResult: Sendable, Equatable {
    case none
    case loaded(
        checkpoint: ScanCheckpoint,
        savedAt: Date,
        compressedFileBytes: Int,
        uncompressedBytes: Int
    )
    case expired
    case schemaMismatch(found: Int, supported: Int)
    case corrupted
}

