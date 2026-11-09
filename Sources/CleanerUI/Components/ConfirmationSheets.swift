import SwiftUI
import CleanerCore

public struct MoveToTrashConfirmationSheet: View {
    let items: [ScannedItem]
    let totalBytes: UInt64
    let isDryRun: Bool
    let onConfirm: () -> Void
    let onCancel: () -> Void

    public init(
        items: [ScannedItem],
        totalBytes: UInt64,
        isDryRun: Bool,
        onConfirm: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.items = items
        self.totalBytes = totalBytes
        self.isDryRun = isDryRun
        self.onConfirm = onConfirm
        self.onCancel = onCancel
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: CleanerSpacing.md) {
            HStack(spacing: CleanerSpacing.sm) {
                Image(systemName: isDryRun ? "eye" : "trash")
                    .font(.title)
                    .foregroundStyle(isDryRun ? Color.accentColor : CleanerColors.safe)
                Text(isDryRun ? "Simulate Move to Trash" : "Move Selected Items to Trash")
                    .font(CleanerTypography.titleLarge())
            }

            Text(isDryRun
                 ? "Dry-Run is active. CleanerMac will verify permissions and protected-path rules for \(items.count) items (\(ByteFormatting.string(from: totalBytes))) without modifying disk."
                 : "\(items.count) items totaling \(ByteFormatting.string(from: totalBytes)) will be moved to your macOS Trash. You can restore them from Trash or Restore History.")
                .font(CleanerTypography.body)
                .foregroundStyle(.secondary)

            List(items.prefix(50)) { item in
                HStack {
                    Text(item.name)
                        .font(CleanerTypography.body)
                    Spacer()
                    Text(ByteFormatting.string(from: item.logicalSize))
                        .font(CleanerTypography.monoMetric)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(minHeight: 140, maxHeight: 220)
            .clipShape(RoundedRectangle(cornerRadius: CleanerRadii.sm))

            HStack {
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.escape, modifiers: [])
                Spacer()
                Button(isDryRun ? "Run Dry Simulation" : "Move to Trash", action: onConfirm)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: [])
            }
        }
        .padding(CleanerSpacing.lg)
        .frame(width: 520)
        .background(.regularMaterial)
    }
}

public struct PermanentDeleteConfirmationSheet: View {
    let items: [ScannedItem]
    let totalBytes: UInt64
    let isDryRun: Bool
    let onConfirm: () -> Void
    let onCancel: () -> Void

    @State private var acknowledgedIrreversible = false

    public init(
        items: [ScannedItem],
        totalBytes: UInt64,
        isDryRun: Bool,
        onConfirm: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.items = items
        self.totalBytes = totalBytes
        self.isDryRun = isDryRun
        self.onConfirm = onConfirm
        self.onCancel = onCancel
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: CleanerSpacing.md) {
            HStack(spacing: CleanerSpacing.sm) {
                Image(systemName: "exclamationmark.octagon.fill")
                    .font(.title)
                    .foregroundStyle(CleanerColors.danger)
                Text(isDryRun ? "Simulate Permanent Deletion" : "Permanently Delete Files")
                    .font(CleanerTypography.titleLarge())
            }

            Text(isDryRun
                 ? "Dry-Run is active. No files will be erased, even after confirming."
                 : "This bypasses the Trash and permanently erases \(items.count) items (\(ByteFormatting.string(from: totalBytes))). Erased files cannot be restored.")
                .font(CleanerTypography.body)
                .foregroundStyle(.secondary)

            List(items.prefix(50)) { item in
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name)
                        .font(CleanerTypography.body)
                    Text(item.url.path)
                        .font(CleanerTypography.monoPath)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .frame(minHeight: 130, maxHeight: 200)
            .clipShape(RoundedRectangle(cornerRadius: CleanerRadii.sm))

            Toggle(isOn: $acknowledgedIrreversible) {
                Text("I understand permanent deletion bypasses the Trash and cannot be undone.")
                    .font(CleanerTypography.callout)
            }
            .toggleStyle(.checkbox)

            HStack {
                Button("Cancel", role: .cancel, action: onCancel)
                Spacer()
                Button(role: .destructive, action: onConfirm) {
                    Label(isDryRun ? "Simulate Permanent Delete" : "Permanently Delete", systemImage: "trash.slash")
                }
                .buttonStyle(.borderedProminent)
                .tint(CleanerColors.danger)
                .disabled(!acknowledgedIrreversible)
            }
        }
        .padding(CleanerSpacing.lg)
        .frame(width: 540)
        .background(.regularMaterial)
    }
}

public struct ExecutionReportSheet: View {
    let report: DeletionExecutionReport
    let onDismiss: () -> Void

    public init(report: DeletionExecutionReport, onDismiss: @escaping () -> Void) {
        self.report = report
        self.onDismiss = onDismiss
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: CleanerSpacing.md) {
            HStack(spacing: CleanerSpacing.sm) {
                Image(systemName: report.isDryRun ? "eye.circle.fill" : "checkmark.seal.fill")
                    .font(.title)
                    .foregroundStyle(report.isDryRun ? Color.accentColor : CleanerColors.safe)
                Text(report.isDryRun ? "Dry-Run Simulation Report" : "Cleanup Complete")
                    .font(CleanerTypography.titleLarge())
            }

            HStack(spacing: CleanerSpacing.lg) {
                summaryMetric(
                    label: report.isDryRun ? "Would Process" : "Processed",
                    value: "\(report.succeededCount) items"
                )
                summaryMetric(
                    label: report.isDryRun ? "Projected Savings" : "Space Freed",
                    value: ByteFormatting.string(from: report.reclaimedBytes)
                )
                summaryMetric(
                    label: "Blocked / Failed",
                    value: "\(report.blockedItems.count + report.failures.count)"
                )
            }
            .padding(CleanerSpacing.sm)
            .background(CleanerColors.cardFill, in: RoundedRectangle(cornerRadius: CleanerRadii.md))

            if !report.blockedItems.isEmpty || !report.failures.isEmpty {
                Text("Safety Blocks & Skipped Items")
                    .font(CleanerTypography.headline)
                List {
                    ForEach(report.blockedItems, id: \.url) { blocked in
                        VStack(alignment: .leading) {
                            Text(blocked.url.path).font(CleanerTypography.monoPath)
                            Text(blocked.reason).font(CleanerTypography.caption).foregroundStyle(CleanerColors.caution)
                        }
                    }
                    ForEach(report.failures, id: \.url) { fail in
                        VStack(alignment: .leading) {
                            Text(fail.url.path).font(CleanerTypography.monoPath)
                            Text(fail.reason).font(CleanerTypography.caption).foregroundStyle(CleanerColors.danger)
                        }
                    }
                }
                .frame(height: 140)
            }

            HStack {
                Spacer()
                Button("Done", action: onDismiss)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: [])
            }
        }
        .padding(CleanerSpacing.lg)
        .frame(width: 520)
        .background(.regularMaterial)
    }

    private func summaryMetric(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(CleanerTypography.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(CleanerTypography.monoMetric)
        }
    }
}
