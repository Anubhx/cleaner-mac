import SwiftUI
import CleanerCore

public enum ByteFormatting {
    public static func string(from bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file)
    }

    public static func actionSizeSuffix(bytes: UInt64) -> String {
        bytes > 0 ? " (\(string(from: bytes)))" : ""
    }
}

public struct DiskCapacityHUD: View {
    let snapshot: VolumeStorageSnapshot

    public init(snapshot: VolumeStorageSnapshot) {
        self.snapshot = snapshot
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: CleanerSpacing.xxs) {
            HStack {
                Label(snapshot.volumeName, systemImage: "internaldrive")
                    .font(CleanerTypography.caption)
                    .fontWeight(.medium)
                    .lineLimit(1)
                Spacer()
                Text("\(Int((snapshot.usedFraction * 100).rounded()))% full")
                    .font(CleanerTypography.monoPath)
                    .foregroundStyle(snapshot.usedFraction > 0.85 ? CleanerColors.caution : .secondary)
            }

            ProgressView(value: snapshot.usedFraction)
                .progressViewStyle(.linear)
                .controlSize(.small)
                .tint(snapshot.usedFraction > 0.85 ? CleanerColors.caution : Color.accentColor)

            HStack {
                Text("\(ByteFormatting.string(from: snapshot.usedBytes)) used")
                Spacer()
                Text("\(ByteFormatting.string(from: snapshot.availableBytes)) free")
            }
            .font(CleanerTypography.monoPath)
            .foregroundStyle(.secondary)
        }
        .padding(CleanerSpacing.sm)
        .background(CleanerColors.cardFill, in: RoundedRectangle(cornerRadius: CleanerRadii.md))
        .overlay(
            RoundedRectangle(cornerRadius: CleanerRadii.md)
                .stroke(CleanerColors.hairline, lineWidth: 1)
        )
    }
}

public struct RiskBadge: View {
    let risk: RiskAssessment

    public init(risk: RiskAssessment) {
        self.risk = risk
    }

    public var body: some View {
        let tint = CleanerColors.color(for: risk.level)
        Label(risk.level.label, systemImage: risk.riskSymbol)
            .font(CleanerTypography.caption)
            .fontWeight(.medium)
            .foregroundStyle(tint)
            .padding(.horizontal, CleanerSpacing.xs)
            .padding(.vertical, 2)
            .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: CleanerRadii.xs))
            .help(risk.reason)
            .accessibilityLabel("\(risk.level.label): \(risk.reason)")
    }
}

private extension RiskAssessment {
    var riskSymbol: String { level.symbolName }
}

public struct KeepOriginalBadge: View {
    public init() {}

    public var body: some View {
        Label("Keep Original", systemImage: "pin.fill")
            .font(CleanerTypography.caption)
            .fontWeight(.medium)
            .foregroundStyle(CleanerColors.safe)
            .padding(.horizontal, CleanerSpacing.xs)
            .padding(.vertical, 2)
            .background(CleanerColors.safe.opacity(0.14), in: RoundedRectangle(cornerRadius: CleanerRadii.xs))
            .accessibilityLabel("Recommended original to keep")
    }
}

public struct DryRunRibbon: View {
    public init() {}

    public var body: some View {
        HStack(spacing: CleanerSpacing.xs) {
            Image(systemName: "eye")
                .foregroundStyle(Color.accentColor)
            Text("Dry-Run Mode Active — Simulations report exact savings without modifying any files.")
                .font(CleanerTypography.callout)
                .foregroundStyle(.primary)
            Spacer()
        }
        .padding(.horizontal, CleanerSpacing.md)
        .padding(.vertical, CleanerSpacing.xs)
        .background(.ultraThinMaterial)
        .overlay(alignment: .bottom) {
            Rectangle().fill(CleanerColors.hairline).frame(height: 1)
        }
        .accessibilityElement(children: .combine)
    }
}

public struct BackgroundScanHUD: View {
    let progress: ScanProgress
    let isScanning: Bool
    let isPaused: Bool
    let onPause: () -> Void
    let onResume: () -> Void
    let onCancel: () -> Void

    public init(
        progress: ScanProgress,
        isScanning: Bool,
        isPaused: Bool,
        onPause: @escaping () -> Void,
        onResume: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.progress = progress
        self.isScanning = isScanning
        self.isPaused = isPaused
        self.onPause = onPause
        self.onResume = onResume
        self.onCancel = onCancel
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: CleanerSpacing.xs) {
            HStack(spacing: CleanerSpacing.xs) {
                Image(systemName: phaseIcon)
                    .foregroundStyle(isPaused ? CleanerColors.caution : Color.accentColor)
                    .symbolEffect(.pulse, isActive: isScanning && !isPaused)

                Text(phaseTitle)
                    .font(CleanerTypography.callout)
                    .lineLimit(1)

                Spacer()

                if isScanning {
                    Button(action: isPaused ? onResume : onPause) {
                        Image(systemName: isPaused ? "play.fill" : "pause.fill")
                    }
                    .buttonStyle(.borderless)
                    .help(isPaused ? "Resume background scan" : "Pause background scan")
                    .accessibilityLabel(isPaused ? "Resume scan" : "Pause scan")

                    Button(action: onCancel) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help("Cancel scan")
                    .accessibilityLabel("Cancel scan")
                }
            }

            if isScanning && !isPaused {
                ProgressView()
                    .progressViewStyle(.linear)
                    .controlSize(.small)
            }

            HStack {
                Text("\(progress.scannedFiles) files")
                Spacer()
                Text(ByteFormatting.string(from: progress.bytesEvaluated))
            }
            .font(CleanerTypography.monoMetric)
            .foregroundStyle(.secondary)

            if !progress.currentPath.isEmpty {
                Text(progress.currentPath)
                    .font(CleanerTypography.monoPath)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(CleanerSpacing.sm)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: CleanerRadii.md))
        .overlay(
            RoundedRectangle(cornerRadius: CleanerRadii.md)
                .stroke(CleanerColors.hairline, lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
    }

    private var phaseTitle: String {
        switch progress.phase {
        case .idle: "Ready to scan"
        case .enumerating: "Scanning in background…"
        case .hashingDuplicates: "Verifying SHA-256 hashes…"
        case .paused: "Scan paused"
        case .completed: "Scan complete"
        case .cancelled: "Scan cancelled"
        }
    }

    private var phaseIcon: String {
        switch progress.phase {
        case .idle: "sparkles"
        case .enumerating, .hashingDuplicates: "arrow.triangle.2.circlepath"
        case .paused: "pause.circle"
        case .completed: "checkmark.circle"
        case .cancelled: "xmark.circle"
        }
    }
}
