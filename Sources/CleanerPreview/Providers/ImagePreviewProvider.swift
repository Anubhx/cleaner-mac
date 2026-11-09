import Foundation
import ImageIO
import CoreGraphics

enum ImagePreviewProvider {
    static func load(url: URL, maxPixelDimension: Int = 1200) -> ImagePreviewData? {
        let options: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options as CFDictionary) else {
            return nil
        }

        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = properties?[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = properties?[kCGImagePropertyPixelHeight] as? Int ?? 0
        let colorModel = properties?[kCGImagePropertyColorModel] as? String

        let thumbOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelDimension,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions as CFDictionary) else {
            return nil
        }

        return ImagePreviewData(
            image: cgImage,
            pixelWidth: width > 0 ? width : cgImage.width,
            pixelHeight: height > 0 ? height : cgImage.height,
            colorModel: colorModel
        )
    }
}
