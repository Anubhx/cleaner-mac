import SwiftUI
import AppKit
import PDFKit
import AVFoundation
import CleanerCore
import CleanerPreview

public struct PreviewPaneView: View {
    let item: ScannedItem?
    let payload: PreviewPayload?
    let isLoading: Bool
    let isChecked: Bool
    let onToggleCheck: () -> Void
    let onTrashFocused: () -> Void
    let onPermanentDeleteFocused: () -> Void

    public init(
        item: ScannedItem?,
        payload: PreviewPayload?,
        isLoading: Bool,
        isChecked: Bool,
        onToggleCheck: @escaping () -> Void,
        onTrashFocused: @escaping () -> Void,
        onPermanentDeleteFocused: @escaping () -> Void
    ) {
        self.item = item
        self.payload = payload
        self.isLoading = isLoading
        self.isChecked = isChecked
        self.onToggleCheck = onToggleCheck
        self.onTrashFocused = onTrashFocused
        self.onPermanentDeleteFocused = onPermanentDeleteFocused
    }

    public var body: some View {
        Group {
            if let item {
                VStack(spacing: 0) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: CleanerSpacing.md) {
                            headerSection(item: item)
                            previewStage(item: item)
                            safetySection(item: item)
                            metadataSection(item: item)
                        }
                        .padding(CleanerSpacing.md)
                    }

                    Divider()

                    actionFooter(item: item)
                        .padding(CleanerSpacing.md)
                }
            } else {
                emptyPreviewState
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .cleanerMaterial(.thinMaterial, fallback: Color(nsColor: .controlBackgroundColor))
    }

    @ViewBuilder
    private func headerSection(item: ScannedItem) -> some View {
        VStack(alignment: .leading, spacing: CleanerSpacing.xs) {
            HStack(alignment: .top) {
                Text(item.name)
                    .font(CleanerTypography.titleLarge())
                    .lineLimit(2)
                    .textSelection(.enabled)

                Spacer()

                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([item.url])
                } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Reveal in Finder")
                .accessibilityLabel("Reveal \(item.name) in Finder")
            }

            Text(item.url.path)
                .font(CleanerTypography.monoPath)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private func previewStage(item: ScannedItem) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: CleanerRadii.md)
                .fill(CleanerColors.cardFill)

            if isLoading {
                ProgressView("Loading preview…")
                    .font(CleanerTypography.callout)
            } else if let payload {
                renderContent(payload.content, metadata: payload.metadata)
            } else {
                Label("Preview unavailable", systemImage: "doc.questionmark")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(minHeight: 200, maxHeight: 280)
        .overlay(
            RoundedRectangle(cornerRadius: CleanerRadii.md)
                .stroke(CleanerColors.hairline, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: CleanerRadii.md))
    }

    @ViewBuilder
    private func renderContent(_ content: PreviewContent, metadata: FileMetadataSnapshot) -> some View {
        switch content {
        case .image(let data):
            VStack(spacing: CleanerSpacing.xs) {
                Image(nsImage: NSImage(cgImage: data.image, size: .zero))
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 230)
                    .padding(CleanerSpacing.xs)

                Text("\(data.pixelWidth) × \(data.pixelHeight) px\(data.colorModel.map { " · \($0)" } ?? "")")
                    .font(CleanerTypography.monoPath)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, CleanerSpacing.xs)
            }

        case .video(let data):
            VStack(spacing: CleanerSpacing.xs) {
                if let cgImage = data.thumbnail {
                    Image(nsImage: NSImage(cgImage: cgImage, size: .zero))
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 220)
                } else {
                    Image(systemName: "film")
                        .font(.system(size: 42))
                        .foregroundStyle(.secondary)
                }
                Text(videoSubtitle(data))
                    .font(CleanerTypography.monoPath)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, CleanerSpacing.xs)
            }

        case .pdf(let data):
            VStack(spacing: 0) {
                PDFKitRepresentable(url: data.url)
                    .frame(height: 240)
                HStack {
                    Text("\(data.pageCount) \(data.pageCount == 1 ? "page" : "pages")")
                    if let title = data.title {
                        Text("· \(title)")
                            .lineLimit(1)
                    }
                    Spacer()
                }
                .font(CleanerTypography.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, CleanerSpacing.sm)
                .padding(.vertical, CleanerSpacing.xxs)
            }

        case .text(let data):
            VStack(alignment: .leading, spacing: 0) {
                if data.isTruncated {
                    HStack(spacing: CleanerSpacing.xs) {
                        Image(systemName: "info.circle")
                        Text("Showing first 256 KB of \(ByteFormatting.string(from: data.totalFileBytes)) (\(data.encodingName))")
                    }
                    .font(CleanerTypography.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, CleanerSpacing.sm)
                    .padding(.vertical, CleanerSpacing.xxs)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.05))
                }
                ScrollView([.vertical, .horizontal]) {
                    Text(data.text)
                        .font(CleanerTypography.monoPath)
                        .textSelection(.enabled)
                        .padding(CleanerSpacing.sm)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

        case .audio(let data):
            AudioMetadataCardView(data: data)

        case .fallback:
            VStack(spacing: CleanerSpacing.sm) {
                if let thumb = metadata.thumbnail {
                    Image(nsImage: NSImage(cgImage: thumb, size: .zero))
                        .resizable()
                        .scaledToFit()
                        .frame(width: 96, height: 96)
                } else {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                }
                Text(metadata.kindDescription)
                    .font(CleanerTypography.callout)
                Text(metadata.utiIdentifier)
                    .font(CleanerTypography.monoPath)
                    .foregroundStyle(.secondary)
            }
            .padding(CleanerSpacing.md)
        }
    }

    @ViewBuilder
    private func safetySection(item: ScannedItem) -> some View {
        VStack(alignment: .leading, spacing: CleanerSpacing.xs) {
            HStack {
                RiskBadge(risk: item.risk)
                Spacer()
                if item.isRecommendedKeep {
                    KeepOriginalBadge()
                }
            }
            Text(item.risk.reason)
                .font(CleanerTypography.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(CleanerSpacing.sm)
        .background(CleanerColors.cardFill, in: RoundedRectangle(cornerRadius: CleanerRadii.md))
        .overlay(
            RoundedRectangle(cornerRadius: CleanerRadii.md)
                .stroke(CleanerColors.hairline, lineWidth: 1)
        )
    }

    @ViewBuilder
    private func metadataSection(item: ScannedItem) -> some View {
        let meta = payload?.metadata
        VStack(alignment: .leading, spacing: CleanerSpacing.xs) {
            Text("File Metadata")
                .font(CleanerTypography.titleSection())

            Grid(alignment: .leading, horizontalSpacing: CleanerSpacing.md, verticalSpacing: 6) {
                metadataRow("Logical Size", ByteFormatting.string(from: meta?.logicalSize ?? item.logicalSize))
                metadataRow("Allocated on Disk", ByteFormatting.string(from: meta?.allocatedSize ?? item.allocatedSize))
                metadataRow("Kind", meta?.kindDescription ?? (item.isDirectory ? "Folder" : "File"))
                metadataRow("Type Identifier", meta?.utiIdentifier ?? item.contentTypeIdentifier ?? "Unknown")
                if let created = meta?.createdDate ?? item.createdDate {
                    metadataRow("Created", created.formatted(date: .abbreviated, time: .shortened))
                }
                if let modified = meta?.modifiedDate ?? item.modifiedDate {
                    metadataRow("Modified", modified.formatted(date: .abbreviated, time: .shortened))
                }
                if let accessed = meta?.accessedDate ?? item.accessedDate {
                    metadataRow("Last Accessed", accessed.formatted(date: .abbreviated, time: .shortened))
                }
                metadataRow("Permissions", meta?.posixPermissions ?? "—")
                metadataRow("Hard Links", "\(meta?.linkCount ?? item.linkCount)")
                if let xattrs = meta?.extendedAttributes, !xattrs.isEmpty {
                    metadataRow("Extended Attrs", xattrs.joined(separator: ", "))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(CleanerSpacing.sm)
        .background(CleanerColors.cardFill, in: RoundedRectangle(cornerRadius: CleanerRadii.md))
        .overlay(
            RoundedRectangle(cornerRadius: CleanerRadii.md)
                .stroke(CleanerColors.hairline, lineWidth: 1)
        )
    }

    @ViewBuilder
    private func metadataRow(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label)
                .font(CleanerTypography.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(CleanerTypography.monoPath)
                .textSelection(.enabled)
                .lineLimit(2)
        }
    }

    @ViewBuilder
    private func actionFooter(item: ScannedItem) -> some View {
        VStack(spacing: CleanerSpacing.xs) {
            Button(action: onTrashFocused) {
                Label("Move to Trash", systemImage: "trash")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(item.isRecommendedKeep)

            HStack(spacing: CleanerSpacing.xs) {
                Button(action: onToggleCheck) {
                    Label(isChecked ? "In Batch" : "Add to Batch", systemImage: isChecked ? "checkmark.circle.fill" : "plus.circle")
                        .lineLimit(1)
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .fixedSize(horizontal: true, vertical: false)
                .disabled(item.isRecommendedKeep)

                Spacer(minLength: CleanerSpacing.xs)

                Button(role: .destructive, action: onPermanentDeleteFocused) {
                    Label("Permanently Delete…", systemImage: "trash.slash")
                        .lineLimit(1)
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .fixedSize(horizontal: true, vertical: false)
                .foregroundStyle(item.isRecommendedKeep ? Color.secondary.opacity(0.6) : CleanerColors.danger)
                .disabled(item.isRecommendedKeep)
            }
        }
    }

    private var emptyPreviewState: some View {
        VStack(spacing: CleanerSpacing.sm) {
            Image(systemName: "sidebar.right")
                .font(.system(size: 34))
                .foregroundStyle(.tertiary)
            Text("Select an Item to Preview")
                .font(CleanerTypography.titleSection())
            Text("Images, videos, PDFs, text, audio metadata, and safety reasons appear here.")
                .font(CleanerTypography.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 240)
        }
        .padding(CleanerSpacing.lg)
    }

    private func videoSubtitle(_ data: VideoPreviewData) -> String {
        let dur = String(format: "%.1fs", data.durationSeconds)
        let dims = data.pixelWidth > 0 ? "\(data.pixelWidth)×\(data.pixelHeight)" : "Video"
        let codec = data.codecName.map { " · \($0)" } ?? ""
        return "\(dims) · \(dur)\(codec)"
    }
}

private struct PDFKitRepresentable: NSViewRepresentable {
    let url: URL

    final class Coordinator {
        var loadedURL: URL?
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.backgroundColor = .clear
        let normalized = url.standardizedFileURL
        view.document = PDFDocument(url: normalized)
        context.coordinator.loadedURL = normalized
        return view
    }

    func updateNSView(_ nsView: PDFView, context: Context) {
        let normalized = url.standardizedFileURL
        if context.coordinator.loadedURL != normalized {
            nsView.document = PDFDocument(url: normalized)
            context.coordinator.loadedURL = normalized
        }
    }
}

private struct AudioMetadataCardView: View {
    let data: AudioPreviewData
    @State private var player: AVPlayer?
    @State private var playbackSessionID: UUID?
    @State private var isPlaying = false

    var body: some View {
        VStack(spacing: CleanerSpacing.sm) {
            Image(systemName: "waveform")
                .font(.system(size: 36))
                .foregroundStyle(Color.accentColor)

            Text(data.title ?? data.url.lastPathComponent)
                .font(CleanerTypography.titleSection())
                .lineLimit(1)

            if (data.artist ?? data.album) != nil {
                Text([data.artist, data.album].compactMap { $0 }.joined(separator: " — "))
                    .font(CleanerTypography.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            HStack(spacing: CleanerSpacing.md) {
                Text(String(format: "%.1fs", data.durationSeconds))
                if let rate = data.sampleRateHz {
                    Text("\(rate) Hz")
                }
                if let channels = data.channelCount {
                    Text("\(channels) ch")
                }
            }
            .font(CleanerTypography.monoMetric)
            .foregroundStyle(.secondary)

            Button {
                togglePlayback()
            } label: {
                Label(isPlaying ? "Stop Preview" : "Play Audio Preview", systemImage: isPlaying ? "stop.fill" : "play.fill")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(CleanerSpacing.md)
        .onChange(of: data.url) { _, _ in
            stopPlayback()
        }
        .onDisappear {
            stopPlayback()
        }
        .task(id: playbackSessionID) {
            guard playbackSessionID != nil,
                  let playerItem = player?.currentItem else { return }
            let notifications = NotificationCenter.default.notifications(
                named: .AVPlayerItemDidPlayToEndTime,
                object: playerItem
            )
            for await _ in notifications {
                guard !Task.isCancelled else { break }
                stopPlayback()
                break
            }
        }
    }

    private func togglePlayback() {
        if isPlaying {
            stopPlayback()
        } else {
            stopPlayback()
            let p = AVPlayer(url: data.url)
            player = p
            playbackSessionID = UUID()
            p.play()
            isPlaying = true
        }
    }

    private func stopPlayback() {
        player?.pause()
        player = nil
        playbackSessionID = nil
        isPlaying = false
    }
}
