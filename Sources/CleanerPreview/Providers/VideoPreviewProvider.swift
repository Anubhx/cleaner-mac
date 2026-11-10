import Foundation
@preconcurrency import AVFoundation
import CoreMedia

enum VideoPreviewProvider {
    static func load(url: URL) async -> VideoPreviewData? {
        let asset = AVURLAsset(url: url)
        guard !Task.isCancelled,
              let duration = try? await asset.load(.duration) else { return nil }
        let seconds = CMTimeGetSeconds(duration)
        guard seconds.isFinite, !Task.isCancelled else { return nil }

        let tracks = (try? await asset.loadTracks(withMediaType: .video)) ?? []
        var pixelWidth = 0
        var pixelHeight = 0
        var codecName: String?

        if !Task.isCancelled, let videoTrack = tracks.first {
            if let naturalSize = try? await videoTrack.load(.naturalSize) {
                pixelWidth = Int(abs(naturalSize.width))
                pixelHeight = Int(abs(naturalSize.height))
            }
            if !Task.isCancelled,
               let descriptions = try? await videoTrack.load(.formatDescriptions),
               let firstDesc = descriptions.first {
                let subType = CMFormatDescriptionGetMediaSubType(firstDesc)
                codecName = fourCCString(subType)
            }
        }

        guard !Task.isCancelled else { return nil }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 960, height: 540)
        let targetTime = CMTime(seconds: min(1.0, max(0.0, seconds * 0.15)), preferredTimescale: 600)
        let thumbnail = await withTaskCancellationHandler {
            (try? await generator.image(at: targetTime))?.image
        } onCancel: {
            generator.cancelAllCGImageGeneration()
        }

        return VideoPreviewData(
            url: url,
            thumbnail: thumbnail,
            durationSeconds: max(0, seconds),
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            codecName: codecName
        )
    }

    private static func fourCCString(_ code: FourCharCode) -> String {
        let bytes: [UInt8] = [
            UInt8((code >> 24) & 0xFF),
            UInt8((code >> 16) & 0xFF),
            UInt8((code >> 8) & 0xFF),
            UInt8(code & 0xFF),
        ]
        return String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
