import Testing
import Foundation
@testable import CleanerCore

@Suite("ScanCheckpoint Envelope & Policy")
struct ScanCheckpointEnvelopeTests {
    @Test("Envelope round-trip preserves schemaVersion, savedAt, metadata, and compressed payload")
    func envelopeRoundTripPreservesMetadata() throws {
        let savedAt = Date(timeIntervalSince1970: 1_731_300_000)
        let payload = Data([0x78, 0x9C, 0x01, 0x02, 0x03, 0x04])
        let envelope = ScanCheckpointEnvelope(
            savedAt: savedAt,
            compressionAlgorithm: "zlib",
            uncompressedByteCount: 4096,
            compressedPayload: payload
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let encoded = try encoder.encode(envelope)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(ScanCheckpointEnvelope.self, from: encoded)
        #expect(decoded == envelope)
        #expect(decoded.schemaVersion == ScanCheckpointEnvelope.currentSchemaVersion)
    }

    @Test("Schema version mismatch throws unsupportedSchemaVersion before decoding payload")
    func schemaMismatchThrowsTypedError() throws {
        let futureJSON = Data(#"{"schemaVersion": 999}"#.utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        do {
            _ = try decoder.decode(ScanCheckpointEnvelope.self, from: futureJSON)
            Issue.record("Expected ScanCheckpointError.unsupportedSchemaVersion")
        } catch let error as ScanCheckpointError {
            #expect(error == .unsupportedSchemaVersion(found: 999, supported: ScanCheckpointEnvelope.currentSchemaVersion))
        }
    }

    @Test("24-hour expiration boundary and relative interrupted descriptions")
    func expiryPolicyAndRelativeTimeFormatting() {
        let now = Date(timeIntervalSince1970: 1_731_400_000)

        let justUnder24Hours = now.addingTimeInterval(-86_399)
        let exactly24Hours = now.addingTimeInterval(-86_400)
        let over24Hours = now.addingTimeInterval(-86_401)

        #expect(!ScanCheckpointPolicy.isExpired(savedAt: justUnder24Hours, now: now))
        #expect(!ScanCheckpointPolicy.isExpired(savedAt: exactly24Hours, now: now))
        #expect(ScanCheckpointPolicy.isExpired(savedAt: over24Hours, now: now))

        #expect(ScanCheckpointPolicy.relativeInterruptedDescription(savedAt: now.addingTimeInterval(-2), relativeTo: now) == "just now")
        let fiveMinutesAgo = ScanCheckpointPolicy.relativeInterruptedDescription(savedAt: now.addingTimeInterval(-300), relativeTo: now)
        #expect(!fiveMinutesAgo.isEmpty)
        #expect(fiveMinutesAgo != "just now")
    }
}

