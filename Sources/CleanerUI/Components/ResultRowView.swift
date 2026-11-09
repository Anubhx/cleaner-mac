import SwiftUI
import AppKit
import CleanerCore

public struct ResultRowView: View {
    let item: ScannedItem
    let isHighlighted: Bool
    let isChecked: Bool
    let onToggleCheck: () -> Void
    let onClickRow: (EventModifiers) -> Void

    public init(
        item: ScannedItem,
        isHighlighted: Bool,
        isChecked: Bool,
        onToggleCheck: @escaping () -> Void,
        onClickRow: @escaping (EventModifiers) -> Void
    ) {
        self.item = item
        self.isHighlighted = isHighlighted
        self.isChecked = isChecked
        self.onToggleCheck = onToggleCheck
        self.onClickRow = onClickRow
    }

    public var body: some View {
        HStack(spacing: CleanerSpacing.sm) {
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
                HStack(spacing: CleanerSpacing.xs) {
                    Text(item.name)
                        .font(CleanerTypography.body)
                        .fontWeight(isHighlighted ? .semibold : .regular)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    if item.isRecommendedKeep {
                        KeepOriginalBadge()
                    } else {
                        RiskBadge(risk: item.risk)
                    }

                    if let deadKind = item.deadKind {
                        Text(deadKind.displayLabel)
                            .font(CleanerTypography.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(CleanerColors.cardFill, in: RoundedRectangle(cornerRadius: CleanerRadii.xs))
                    }
                }

                HStack(spacing: CleanerSpacing.xs) {
                    Text(item.url.deletingLastPathComponent().path)
                        .font(CleanerTypography.monoPath)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)

                    if let modified = item.modifiedDate {
                        Text("Modified \(modified.formatted(date: .abbreviated, time: .omitted))")
                            .font(CleanerTypography.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            Spacer(minLength: CleanerSpacing.sm)

            Text(ByteFormatting.string(from: item.logicalSize))
                .font(CleanerTypography.monoMetric)
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, CleanerSpacing.sm)
        .padding(.vertical, CleanerSpacing.xs)
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
        .accessibilityLabel("\(item.name), \(ByteFormatting.string(from: item.logicalSize)), \(item.risk.level.label)")
        .accessibilityValue(isChecked ? "Selected for cleanup" : "Not selected")
        .accessibilityHint("Click to preview. Command-click or Shift-click to multi-select. Press Space to toggle selection.")
        .accessibilityAddTraits(isHighlighted ? .isSelected : [])
        .accessibilityAction(named: isChecked ? "Deselect from cleanup" : "Select for cleanup") {
            if !item.isRecommendedKeep {
                onToggleCheck()
            }
        }
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
