import Foundation
import CoreGraphics

public struct FileMetadataSnapshot: Sendable {
    public let url: URL
    public let utiIdentifier: String
    public let kindDescription: String
    public let logicalSize: UInt64
    public let allocatedSize: UInt64
    public let createdDate: Date?
    public let modifiedDate: Date?
    public let accessedDate: Date?
    public let posixPermissions: String
    public let linkCount: Int
    public let extendedAttributes: [String]
    public let thumbnail: CGImage?

    public init(
        url: URL,
        utiIdentifier: String,
        kindDescription: String,
        logicalSize: UInt64,
        allocatedSize: UInt64,
        createdDate: Date?,
        modifiedDate: Date?,
        accessedDate: Date?,
        posixPermissions: String,
        linkCount: Int,
        extendedAttributes: [String],
        thumbnail: CGImage?
    ) {
        self.url = url
        self.utiIdentifier = utiIdentifier
        self.kindDescription = kindDescription
        self.logicalSize = logicalSize
        self.allocatedSize = allocatedSize
        self.createdDate = createdDate
        self.modifiedDate = modifiedDate
        self.accessedDate = accessedDate
        self.posixPermissions = posixPermissions
        self.linkCount = linkCount
        self.extendedAttributes = extendedAttributes
        self.thumbnail = thumbnail
    }
}

public struct ImagePreviewData: Sendable {
    public let image: CGImage
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let colorModel: String?

    public init(image: CGImage, pixelWidth: Int, pixelHeight: Int, colorModel: String?) {
        self.image = image
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.colorModel = colorModel
    }
}

public struct VideoPreviewData: Sendable {
    public let url: URL
    public let thumbnail: CGImage?
    public let durationSeconds: Double
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let codecName: String?

    public init(
        url: URL,
        thumbnail: CGImage?,
        durationSeconds: Double,
        pixelWidth: Int,
        pixelHeight: Int,
        codecName: String?
    ) {
        self.url = url
        self.thumbnail = thumbnail
        self.durationSeconds = durationSeconds
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.codecName = codecName
    }
}

public struct PDFPreviewData: Sendable {
    public let url: URL
    public let pageCount: Int
    public let title: String?
    public let author: String?

    public init(url: URL, pageCount: Int, title: String?, author: String?) {
        self.url = url
        self.pageCount = pageCount
        self.title = title
        self.author = author
    }
}

public struct TextPreviewData: Sendable {
    public let text: String
    public let lineCount: Int
    public let encodingName: String
    public let isTruncated: Bool
    public let totalFileBytes: UInt64

    public init(
        text: String,
        lineCount: Int,
        encodingName: String,
        isTruncated: Bool,
        totalFileBytes: UInt64
    ) {
        self.text = text
        self.lineCount = lineCount
        self.encodingName = encodingName
        self.isTruncated = isTruncated
        self.totalFileBytes = totalFileBytes
    }
}

public struct AudioPreviewData: Sendable {
    public let url: URL
    public let title: String?
    public let artist: String?
    public let album: String?
    public let durationSeconds: Double
    public let sampleRateHz: Int?
    public let channelCount: Int?

    public init(
        url: URL,
        title: String?,
        artist: String?,
        album: String?,
        durationSeconds: Double,
        sampleRateHz: Int?,
        channelCount: Int?
    ) {
        self.url = url
        self.title = title
        self.artist = artist
        self.album = album
        self.durationSeconds = durationSeconds
        self.sampleRateHz = sampleRateHz
        self.channelCount = channelCount
    }
}

public enum PreviewContent: Sendable {
    case image(ImagePreviewData)
    case video(VideoPreviewData)
    case pdf(PDFPreviewData)
    case text(TextPreviewData)
    case audio(AudioPreviewData)
    case fallback
}

public struct PreviewPayload: Sendable {
    public let content: PreviewContent
    public let metadata: FileMetadataSnapshot

    public init(content: PreviewContent, metadata: FileMetadataSnapshot) {
        self.content = content
        self.metadata = metadata
    }
}
