import Foundation
import Compression
import os
import CleanerCore

public enum ScanCheckpointStoreError: Error, LocalizedError, Equatable, Sendable {
    case tempFileCreationFailed(path: String)
    case compressionFailed(reason: String)

    public var errorDescription: String? {
        switch self {
        case .tempFileCreationFailed(let path):
            "Failed to create temporary checkpoint file at \(path)."
        case .compressionFailed(let reason):
            "Checkpoint compression error: \(reason)"
        }
    }
}

public actor ScanCheckpointStore {
    public nonisolated let fileURL: URL
    private nonisolated let nowProvider: @Sendable () -> Date
    private nonisolated let ioLock = OSAllocatedUnfairLock<Void>(initialState: ())

    private nonisolated static let maxUncompressedBytes = 256 * 1_048_576
    private nonisolated static let compressionChunkSize = 65_536

    public static var defaultFileURL: URL {
        AtomicJSONFile.applicationSupportDirectory()
            .appendingPathComponent("session", isDirectory: true)
            .appendingPathComponent("checkpoint.json", isDirectory: false)
    }

    public init(
        fileURL: URL? = nil,
        nowProvider: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.fileURL = fileURL ?? Self.defaultFileURL
        self.nowProvider = nowProvider
    }

    public func load() -> ScanCheckpointLoadResult {
        ioLock.withLock {
            loadSynchronouslyLocked()
        }
    }

    public func save(_ checkpoint: ScanCheckpoint) throws {
        try saveSynchronously(checkpoint)
    }

    public nonisolated func saveSynchronously(_ checkpoint: ScanCheckpoint) throws {
        try ioLock.withLock {
            try saveSynchronouslyLocked(checkpoint)
        }
    }

    public func clear() {
        ioLock.withLock {
            try? FileManager.default.removeItem(at: fileURL)
        }
    }

    private nonisolated func loadSynchronouslyLocked() -> ScanCheckpointLoadResult {
        let fileManager = FileManager.default
        let path = fileURL.path(percentEncoded: false)
        guard fileManager.fileExists(atPath: path) else {
            return .none
        }

        let rawFileData: Data
        do {
            rawFileData = try Data(contentsOf: fileURL)
        } catch {
            AtomicJSONFile.quarantineCorruptedFile(at: fileURL, fileManager: fileManager)
            return .corrupted
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let envelope: ScanCheckpointEnvelope
        do {
            envelope = try decoder.decode(ScanCheckpointEnvelope.self, from: rawFileData)
        } catch ScanCheckpointError.unsupportedSchemaVersion(let found, let supported) {
            // Incompatible checkpoint schema cannot safely resume; quarantine the unreadable file
            // so future launches start clean and let the UI inform the user once.
            AtomicJSONFile.quarantineCorruptedFile(at: fileURL, fileManager: fileManager)
            return .schemaMismatch(found: found, supported: supported)
        } catch {
            AtomicJSONFile.quarantineCorruptedFile(at: fileURL, fileManager: fileManager)
            return .corrupted
        }

        if ScanCheckpointPolicy.isExpired(savedAt: envelope.savedAt, now: nowProvider()) {
            try? fileManager.removeItem(at: fileURL)
            return .expired
        }

        guard let algorithm = compressionAlgorithm(for: envelope.compressionAlgorithm),
              envelope.uncompressedByteCount >= 0,
              envelope.uncompressedByteCount <= Self.maxUncompressedBytes else {
            AtomicJSONFile.quarantineCorruptedFile(at: fileURL, fileManager: fileManager)
            return .corrupted
        }

        do {
            let jsonData = try Self.decompress(envelope.compressedPayload, algorithm: algorithm)
            let checkpoint = try decoder.decode(ScanCheckpoint.self, from: jsonData)
            return .loaded(
                checkpoint: checkpoint,
                savedAt: envelope.savedAt,
                compressedFileBytes: rawFileData.count,
                uncompressedBytes: jsonData.count
            )
        } catch {
            AtomicJSONFile.quarantineCorruptedFile(at: fileURL, fileManager: fileManager)
            return .corrupted
        }
    }

    private nonisolated func saveSynchronouslyLocked(_ checkpoint: ScanCheckpoint) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        let payloadData = try encoder.encode(checkpoint)
        let compressed = try Self.compress(payloadData, algorithm: .zlib)
        let envelope = ScanCheckpointEnvelope(
            savedAt: nowProvider(),
            compressionAlgorithm: "zlib",
            uncompressedByteCount: payloadData.count,
            compressedPayload: compressed
        )

        do {
            try AtomicJSONFile.save(envelope, to: fileURL)
        } catch AtomicJSONFileError.tempFileCreationFailed(let path) {
            throw ScanCheckpointStoreError.tempFileCreationFailed(path: path)
        }
    }

    private nonisolated func compressionAlgorithm(for identifier: String) -> Algorithm? {
        switch identifier {
        case "zlib": .zlib
        case "lzfse": .lzfse
        default: nil
        }
    }

    private nonisolated static func compress(_ input: Data, algorithm: Algorithm) throws -> Data {
        var compressed = Data()
        let filter = try OutputFilter(.compress, using: algorithm) { chunk in
            if let chunk {
                compressed.append(chunk)
            }
        }
        var offset = input.startIndex
        while offset < input.endIndex {
            let next = input.index(offset, offsetBy: compressionChunkSize, limitedBy: input.endIndex) ?? input.endIndex
            try filter.write(input[offset..<next])
            offset = next
        }
        try filter.finalize()
        return compressed
    }

    private nonisolated static func decompress(_ input: Data, algorithm: Algorithm) throws -> Data {
        var decompressed = Data()
        var cursor = input.startIndex
        let filter = try InputFilter(.decompress, using: algorithm) { requestedLength -> Data? in
            guard cursor < input.endIndex else { return nil }
            let remaining = input.distance(from: cursor, to: input.endIndex)
            let count = min(requestedLength, min(compressionChunkSize, remaining))
            let next = input.index(cursor, offsetBy: count)
            let slice = input[cursor..<next]
            cursor = next
            return slice
        }
        while let chunk = try filter.readData(ofLength: compressionChunkSize) {
            guard decompressed.count + chunk.count <= maxUncompressedBytes else {
                throw ScanCheckpointStoreError.compressionFailed(reason: "Decompressed payload exceeds safety limit.")
            }
            decompressed.append(chunk)
        }
        return decompressed
    }
}

