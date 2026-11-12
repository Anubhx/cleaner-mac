import SwiftUI
import AppKit
import CleanerCore

public struct ResultRowView: View {
    let item: ScannedItem
    let isHighlighted: Bool
    let isChecked: Bool
    let verificationStatus: SnapshotVerificationStatus?
    let onToggleCheck: () -> Void
    let onClickRow: (EventModifiers) -> Void

    public init(
        item: ScannedItem,
        isHighlighted: Bool,
        isChecked: Bool,
        verificationStatus: SnapshotVerificationStatus? = nil,
        onToggleCheck: @escaping () -> Void,
        onClickRow: @escaping (EventModifiers) -> Void
    ) {
        self.item = item
        self.isHighlighted = isHighlighted
        self.isChecked = isChecked
        self.verificationStatus = verificationStatus
        self.onToggleCheck = onToggleCheck
        self.onClickRow = onClickRow
    }

    public var body: some View {
        HStack(spacing: CleanerSpacing.sm) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(leftBarColor)
                .frame(width: 3, height: 32)
                .accessibilityHidden(true)

            Toggle(isOn: Binding(
                get: { isChecked },
                set: { _ in onToggleCheck() }
            )) {
                EmptyView()
            }
            .toggleStyle(.checkbox)
            .labelsHidden()
            .disabled(item.isRecommendedKeep)
            .accessibilityLabel("Include \(item.name) for cleanup")

            Image(systemName: itemSymbol)
                .font(.title3)
                .foregroundStyle(item.isRecommendedKeep ? CleanerColors.safe : .secondary)
                .frame(width: 26, height: 26)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: CleanerSpacing.xxs) {
                Text(item.name)
                    .font(CleanerTypography.body)
                    .fontWeight(isHighlighted ? .semibold : .regular)
                    .lineLimit(1)
                    .truncationMode(.middle)

                HStack(spacing: CleanerSpacing.xs) {
                    Text(item.url.deletingLastPathComponent().path)
                        .font(CleanerTypography.monoPath)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)

                    if item.isRecommendedKeep {
                        Text("· Keep Original")
                            .font(CleanerTypography.caption)
                            .foregroundStyle(CleanerColors.safe)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    } else if let deadKind = item.deadKind {
                        Text("· \(deadKind.displayLabel)")
                            .font(CleanerTypography.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }

                    if let modified = item.modifiedDate {
                        Text("· Modified \(modified.formatted(date: .abbreviated, time: .omitted))")
                            .font(CleanerTypography.caption)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                }
            }

            Spacer(minLength: CleanerSpacing.sm)

            if let verificationStatus {
                SnapshotVerificationBadge(status: verificationStatus)
                    .fixedSize(horizontal: true, vertical: false)
            }

            Text(ByteFormatting.string(from: item.reclaimableDiskBytes))
                .font(CleanerTypography.monoMetric)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, CleanerSpacing.sm)
        .padding(.vertical, CleanerSpacing.xs)
        .help(rowHelpText)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: CleanerRadii.sm)
                .fill(isHighlighted ? Color.accentColor.opacity(0.14) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: CleanerRadii.sm)
                .stroke(isHighlighted ? Color.accentColor.opacity(0.45) : Color.clear, lineWidth: 1)
        )
        .onTapGesture {
            onClickRow(currentEventModifiers())
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(rowAccessibilityLabel)
        .accessibilityValue(isChecked ? "Selected for cleanup" : "Not selected")
        .accessibilityHint("Click to preview. Command-click or Shift-click to multi-select. Press Space to toggle selection.")
        .accessibilityAddTraits(isHighlighted ? .isSelected : [])
        .accessibilityAction(named: isChecked ? "Deselect from cleanup" : "Select for cleanup") {
            if !item.isRecommendedKeep {
                onToggleCheck()
            }
        }
    }

    private var leftBarColor: Color {
        if item.isRecommendedKeep {
            return CleanerColors.safe
        }
        switch item.risk.level {
        case .low:
            return CleanerColors.safe.opacity(0.55)
        case .moderate:
            return CleanerColors.caution
        case .high:
            return CleanerColors.danger
        }
    }

    private var rowAccessibilityLabel: String {
        var parts = [item.name, ByteFormatting.string(from: item.reclaimableDiskBytes), item.risk.level.label]
        if let verificationStatus {
            parts.append(verificationStatus.displayLabel)
        }
        return parts.joined(separator: ", ")
    }

    private var rowHelpText: String {
        if let verificationStatus, verificationStatus != .unchanged,
           let blockedReason = SnapshotVerificationPolicy.blockedReason(for: verificationStatus) {
            return blockedReason
        }
        return item.isRecommendedKeep
            ? "Keep Original — \(item.risk.reason)"
            : "\(item.risk.level.label) — \(item.risk.reason)"
    }

    private var itemSymbol: String {
        if item.isDirectory { return "folder" }
        if item.isCloudDataless { return "icloud" }
        return "doc"
    }

    private func currentEventModifiers() -> EventModifiers {
        guard let flags = NSApp.currentEvent?.modifierFlags else { return [] }
        var modifiers: EventModifiers = []
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.option) { modifiers.insert(.option) }
        return modifiers
    }
}
