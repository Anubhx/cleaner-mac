import Foundation

enum TextPreviewProvider {
    static let maxPreviewBytes = 256 * 1024

    static func load(url: URL, allowHeuristicSniff: Bool) -> TextPreviewData? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        let totalBytes = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: 0)
        let slice = handle.readData(ofLength: maxPreviewBytes)
        let isTruncated = totalBytes > UInt64(maxPreviewBytes)

        if allowHeuristicSniff && slice.contains(0x00) {
            return nil
        }

        let decoded: (String, String)?
        if let utf8 = String(data: slice, encoding: .utf8) {
            decoded = (utf8, "UTF-8")
        } else if let utf16 = String(data: slice, encoding: .utf16) {
            decoded = (utf16, "UTF-16")
        } else if let latin1 = String(data: slice, encoding: .isoLatin1), !allowHeuristicSniff {
            decoded = (latin1, "ISO-8859-1")
        } else {
            decoded = nil
        }

        guard let (text, encodingName) = decoded else { return nil }
        let lineCount = text.split(separator: "\n", omittingEmptySubsequences: false).count

        return TextPreviewData(
            text: text,
            lineCount: lineCount,
            encodingName: encodingName,
            isTruncated: isTruncated,
            totalFileBytes: totalBytes
        )
    }
}
