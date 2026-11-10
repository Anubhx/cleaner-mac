import Foundation
import UniformTypeIdentifiers
import CleanerCore

public struct PreviewService: Sendable {
    public init() {}

    public func loadPreview(for item: ScannedItem) async -> PreviewPayload {
        let metadata = await MetadataSnapshotProvider.capture(for: item)
        if item.isDirectory || Task.isCancelled {
            return PreviewPayload(content: .fallback, metadata: metadata)
        }

        let utType = UTType(metadata.utiIdentifier) ?? UTType(filenameExtension: item.url.pathExtension)
        let content = await resolveContent(url: item.url, utType: utType)
        return PreviewPayload(content: content, metadata: metadata)
    }

    private func resolveContent(url: URL, utType: UTType?) async -> PreviewContent {
        if let utType {
            if utType.conforms(to: .image), let image = ImagePreviewProvider.load(url: url) {
                return .image(image)
            }
            if utType.conforms(to: .pdf), let pdf = PDFPreviewProvider.load(url: url) {
                return .pdf(pdf)
            }
            if utType.conforms(to: .movie) || utType.conforms(to: .video),
               let video = await VideoPreviewProvider.load(url: url) {
                return .video(video)
            }
            if utType.conforms(to: .audio), let audio = await AudioPreviewProvider.load(url: url) {
                return .audio(audio)
            }
            if utType.conforms(to: .text) || utType.conforms(to: .sourceCode) || utType.conforms(to: .json) || utType.conforms(to: .xml),
               let text = TextPreviewProvider.load(url: url, allowHeuristicSniff: false) {
                return .text(text)
            }
        }

        if isKnownTextExtension(url.pathExtension),
           let text = TextPreviewProvider.load(url: url, allowHeuristicSniff: true) {
            return .text(text)
        }

        return .fallback
    }

    private func isKnownTextExtension(_ ext: String) -> Bool {
        let textExtensions: Set<String> = [
            "log", "md", "markdown", "txt", "swift", "ts", "tsx", "js", "jsx",
            "json", "yaml", "yml", "toml", "xml", "plist", "csv", "sh", "zsh",
            "py", "rb", "go", "rs", "c", "h", "cpp", "hpp", "css", "html",
        ]
        return textExtensions.contains(ext.lowercased())
    }
}
