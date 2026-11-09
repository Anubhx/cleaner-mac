import Foundation
import AVFoundation
import CoreMedia

enum AudioPreviewProvider {
    static func load(url: URL) async -> AudioPreviewData? {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration) else { return nil }
        let seconds = CMTimeGetSeconds(duration)
        guard seconds.isFinite else { return nil }

        let metadata = (try? await asset.load(.commonMetadata)) ?? []
        let title = await readStringMetadata(metadata, identifier: .commonIdentifierTitle)
        let artist = await readStringMetadata(metadata, identifier: .commonIdentifierArtist)
        let album = await readStringMetadata(metadata, identifier: .commonIdentifierAlbumName)

        var sampleRate: Int?
        var channels: Int?
        if let audioTrack = (try? await asset.loadTracks(withMediaType: .audio))?.first,
           let descriptions = try? await audioTrack.load(.formatDescriptions),
           let firstDesc = descriptions.first,
           let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(firstDesc)?.pointee {
            sampleRate = Int(asbd.mSampleRate)
            channels = Int(asbd.mChannelsPerFrame)
        }

        return AudioPreviewData(
            url: url,
            title: title,
            artist: artist,
            album: album,
            durationSeconds: max(0, seconds),
            sampleRateHz: sampleRate,
            channelCount: channels
        )
    }

    private static func readStringMetadata(
        _ items: [AVMetadataItem],
        identifier: AVMetadataIdentifier
    ) async -> String? {
        let matched = AVMetadataItem.metadataItems(from: items, filteredByIdentifier: identifier)
        guard let first = matched.first,
              let value = try? await first.load(.stringValue),
              !value.isEmpty else {
            return nil
        }
        return value
    }
}
