import Foundation
import CryptoKit

public enum StreamingHasher {
    public static func partialDigest(for url: URL, sampleBytes: Int = 4096) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        let fileSize = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: 0)

        var hasher = SHA256()
        let head = handle.readData(ofLength: sampleBytes)
        guard !head.isEmpty else { return nil }
        hasher.update(data: head)

        if fileSize > UInt64(sampleBytes * 2) {
            try? handle.seek(toOffset: fileSize - UInt64(sampleBytes))
            let tail = handle.readData(ofLength: sampleBytes)
            hasher.update(data: tail)
        }

        return hexString(hasher.finalize())
    }

    public static func fullDigest(for url: URL, chunkSize: Int = 65_536) async -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        var hasher = SHA256()
        while !Task.isCancelled {
            let chunk = handle.readData(ofLength: chunkSize)
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
            await Task.yield()
        }

        guard !Task.isCancelled else { return nil }
        return hexString(hasher.finalize())
    }

    private static func hexString(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}

