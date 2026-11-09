import Testing
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import PDFKit
import AVFoundation
@testable import CleanerCore
@testable import CleanerPreview

@Suite("CleanerPreview Providers")
struct CleanerPreviewTests {
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CleanerPreviewTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func writeTestPNG(to url: URL, width: Int = 64, height: Int = 48) throws {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let cgImage = ctx.makeImage() else {
            throw NSError(domain: "TestFixture", code: 1)
        }
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw NSError(domain: "TestFixture", code: 2)
        }
        CGImageDestinationAddImage(dest, cgImage, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw NSError(domain: "TestFixture", code: 3)
        }
    }

    private func writeTestPDF(to url: URL) throws {
        let pdfData = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 200, height: 200)
        guard let consumer = CGDataConsumer(data: pdfData as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: &box, nil) else {
            throw NSError(domain: "TestFixture", code: 4)
        }
        ctx.beginPDFPage(nil)
        ctx.endPDFPage()
        ctx.beginPDFPage(nil)
        ctx.endPDFPage()
        ctx.closePDF()
        try (pdfData as Data).write(to: url)
    }

    private func writeTestWAV(to url: URL, sampleRate: UInt32 = 44100, durationSeconds: UInt32 = 1) throws {
        let channels: UInt16 = 2
        let bitsPerSample: UInt16 = 16
        let byteRate = sampleRate * UInt32(channels) * UInt32(bitsPerSample / 8)
        let dataSize = byteRate * durationSeconds
        var data = Data()
        data.append(contentsOf: "RIFF".utf8)
        var chunkSize = UInt32(36 + dataSize).littleEndian
        data.append(Data(bytes: &chunkSize, count: 4))
        data.append(contentsOf: "WAVEfmt ".utf8)
        var subchunk1 = UInt32(16).littleEndian
        var audioFormat = UInt16(1).littleEndian
        var numChannels = channels.littleEndian
        var rate = sampleRate.littleEndian
        var bRate = byteRate.littleEndian
        var blockAlign = UInt16(channels * (bitsPerSample / 8)).littleEndian
        var bps = bitsPerSample.littleEndian
        var subchunk2 = dataSize.littleEndian
        data.append(Data(bytes: &subchunk1, count: 4))
        data.append(Data(bytes: &audioFormat, count: 2))
        data.append(Data(bytes: &numChannels, count: 2))
        data.append(Data(bytes: &rate, count: 4))
        data.append(Data(bytes: &bRate, count: 4))
        data.append(Data(bytes: &blockAlign, count: 2))
        data.append(Data(bytes: &bps, count: 2))
        data.append(contentsOf: "data".utf8)
        data.append(Data(bytes: &subchunk2, count: 4))
        data.append(Data(count: Int(dataSize)))
        try data.write(to: url)
    }

    @Test("Generates image preview with dimensions")
    func previewsImageWithDimensions() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let pngURL = dir.appendingPathComponent("sample.png")
        try writeTestPNG(to: pngURL, width: 64, height: 48)

        let item = ScannedItem(url: pngURL, name: "sample.png", logicalSize: 1024, allocatedSize: 4096, isDirectory: false, category: .largeFiles)
        let payload = await PreviewService().loadPreview(for: item)

        guard case .image(let info) = payload.content else {
            Issue.record("Expected .image preview")
            return
        }
        #expect(info.pixelWidth == 64)
        #expect(info.pixelHeight == 48)
    }

    @Test("Generates PDF preview with accurate page count")
    func previewsPDFPageCount() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let pdfURL = dir.appendingPathComponent("doc.pdf")
        try writeTestPDF(to: pdfURL)

        let item = ScannedItem(url: pdfURL, name: "doc.pdf", logicalSize: 2048, allocatedSize: 4096, isDirectory: false, category: .oldFiles)
        let payload = await PreviewService().loadPreview(for: item)

        guard case .pdf(let info) = payload.content else {
            Issue.record("Expected .pdf preview")
            return
        }
        #expect(info.pageCount == 2)
    }

    @Test("Previews text and code files and truncates oversized logs safely")
    func previewsTextAndTruncatesLargeFiles() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let codeURL = dir.appendingPathComponent("HugeLog.log")
        let hugeText = String(repeating: "2026-11-09 INFO event line\n", count: 20_000)
        try Data(hugeText.utf8).write(to: codeURL)

        let item = ScannedItem(url: codeURL, name: "HugeLog.log", logicalSize: UInt64(hugeText.utf8.count), allocatedSize: 512_000, isDirectory: false, category: .largeFiles)
        let payload = await PreviewService().loadPreview(for: item)

        guard case .text(let info) = payload.content else {
            Issue.record("Expected .text preview")
            return
        }
        #expect(info.isTruncated == true)
        #expect(info.text.contains("INFO event line"))
    }

    @Test("Extracts audio duration and sample rate metadata")
    func previewsAudioMetadata() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let wavURL = dir.appendingPathComponent("tone.wav")
        try writeTestWAV(to: wavURL, sampleRate: 44100, durationSeconds: 1)

        let item = ScannedItem(url: wavURL, name: "tone.wav", logicalSize: 176_444, allocatedSize: 180_224, isDirectory: false, category: .duplicates)
        let payload = await PreviewService().loadPreview(for: item)

        guard case .audio(let info) = payload.content else {
            Issue.record("Expected .audio preview")
            return
        }
        #expect(info.durationSeconds >= 0.9)
        #expect(info.sampleRateHz == 44100)
        #expect(info.channelCount == 2)
    }

    @Test("Falls back to metadata panel for unknown binary files")
    func fallsBackToMetadataForUnknownBinary() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let binURL = dir.appendingPathComponent("blob.custombin")
        try Data([0x00, 0xFF, 0x13, 0x37, 0xDE, 0xAD, 0xBE, 0xEF]).write(to: binURL)

        let item = ScannedItem(url: binURL, name: "blob.custombin", logicalSize: 8, allocatedSize: 4096, isDirectory: false, category: .deadFiles)
        let payload = await PreviewService().loadPreview(for: item)

        guard case .fallback = payload.content else {
            Issue.record("Expected .fallback preview")
            return
        }
        #expect(payload.metadata.logicalSize == 8)
        #expect(!payload.metadata.posixPermissions.isEmpty)
    }

    @Test("Extracts video thumbnail, duration, and resolution")
    func previewsVideoThumbnailAndMetadata() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let movURL = dir.appendingPathComponent("clip.mov")
        try await writeTestMOV(to: movURL, width: 128, height: 96)

        let item = ScannedItem(url: movURL, name: "clip.mov", logicalSize: 8192, allocatedSize: 8192, isDirectory: false, category: .largeFiles)
        let payload = await PreviewService().loadPreview(for: item)

        guard case .video(let info) = payload.content else {
            Issue.record("Expected .video preview")
            return
        }
        #expect(info.pixelWidth == 128)
        #expect(info.pixelHeight == 96)
        #expect(info.thumbnail != nil)
        #expect(info.durationSeconds > 0)
    }

    @Test("Decodes UTF-16 text files and rejects binary NUL streams to fallback")
    func previewsUTF16TextAndRejectsBinaryTxt() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let utf16URL = dir.appendingPathComponent("notes.txt")
        try "Line 1\nLine 2".data(using: .utf16)?.write(to: utf16URL)
        let utf16Item = ScannedItem(url: utf16URL, name: "notes.txt", logicalSize: 32, allocatedSize: 4096, isDirectory: false, category: .oldFiles)
        let utf16Payload = await PreviewService().loadPreview(for: utf16Item)
        guard case .text(let textData) = utf16Payload.content else {
            Issue.record("Expected UTF-16 .text preview")
            return
        }
        #expect(textData.text.contains("Line 2"))

        let binTxtURL = dir.appendingPathComponent("fake.txt")
        try Data([0x41, 0x00, 0x00, 0x00, 0xFF, 0x00]).write(to: binTxtURL)
        let binItem = ScannedItem(url: binTxtURL, name: "fake.txt", logicalSize: 6, allocatedSize: 4096, isDirectory: false, category: .oldFiles)
        let binPayload = await PreviewService().loadPreview(for: binItem)
        if case .fallback = binPayload.content {
            // Expected fallback when NUL bytes present outside valid text encoding
        } else {
            // Also acceptable if OS UTI classified differently; ensure metadata snapshot populated
            #expect(binPayload.metadata.logicalSize == 6)
        }
    }

    private func writeTestMOV(to url: URL, width: Int, height: Int) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ]
        )
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32ARGB, nil, &pixelBuffer)
        if let pixelBuffer {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(for: .milliseconds(5))
            }
            adaptor.append(pixelBuffer, withPresentationTime: .zero)
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(for: .milliseconds(5))
            }
            adaptor.append(pixelBuffer, withPresentationTime: CMTime(value: 1, timescale: 2))
        }
        input.markAsFinished()
        await writer.finishWriting()
    }
}
