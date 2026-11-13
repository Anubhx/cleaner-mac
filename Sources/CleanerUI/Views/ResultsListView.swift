import SwiftUI
import CleanerCore

public struct ResultsListView: View {
    @Bindable var store: CleanerWorkspaceStore
    let category: ScanCategory

    @FocusState private var isListFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(store: CleanerWorkspaceStore, category: ScanCategory) {
        self.store = store
        self.category = category
    }

    public var body: some View {
        VStack(spacing: 0) {
            categoryHeader
            Divider()
            actionBar
            Divider()
            resultsBody
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var categoryHeader: some View {
        AdaptiveRowLayout(horizontalSpacing: CleanerSpacing.md, verticalSpacing: CleanerSpacing.xs, stackedTrailingAlignment: .leading) {
            VStack(alignment: .leading, spacing: CleanerSpacing.xxs) {
                Text(category.displayName)
                    .font(CleanerTypography.titleLarge())
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Text(category.subtitle)
                    .font(CleanerTypography.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            categoryMetricsBlock
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, CleanerSpacing.md)
        .padding(.vertical, CleanerSpacing.md)
    }

    private var categoryMetricsBlock: some View {
        VStack(alignment: .trailing, spacing: CleanerSpacing.xxs) {
            Text(ByteFormatting.string(from: store.reclaimableBytes(for: category)))
                .font(CleanerTypography.monoMetric)
                .foregroundStyle(.primary)
                .lineLimit(1)
            Text("\(store.items(for: category).count) items found")
                .font(CleanerTypography.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var actionBar: some View {
        AdaptiveRowLayout(horizontalSpacing: CleanerSpacing.sm, verticalSpacing: CleanerSpacing.xs, stackedTrailingAlignment: .leading) {
            WrappingFlowLayout(horizontalSpacing: CleanerSpacing.xs, verticalSpacing: CleanerSpacing.xs) {
                actionBarFilterControls
            }

            if !store.checkedItemsInAllCategories.isEmpty {
                WrappingFlowLayout(horizontalSpacing: CleanerSpacing.xs, verticalSpacing: CleanerSpacing.xs) {
                    actionBarBatchControls
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, CleanerSpacing.md)
        .padding(.vertical, CleanerSpacing.xs)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    @ViewBuilder
    private var actionBarFilterControls: some View {
        Menu {
            ForEach(ResultSortOrder.allCases, id: \.self) { order in
                Button {
                    store.sortOrder = order
                } label: {
                    if store.sortOrder == order {
                        Label(order.rawValue, systemImage: "checkmark")
                    } else {
                        Text(order.rawValue)
                    }
                }
            }
        } label: {
            Label(store.sortOrder.rawValue, systemImage: "arrow.up.arrow.down")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityLabel("Sort results")

        Button("Select All") {
            store.selectAllInActiveCategory()
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .fixedSize(horizontal: true, vertical: false)
        .disabled(store.visibleItems.isEmpty)

        Button("Clear") {
            store.clearChecksInActiveCategory()
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .fixedSize(horizontal: true, vertical: false)
        .disabled(store.selection.checkedIDs.isEmpty)

        if store.isResultsFromPersistedSnapshot {
            let hasAnySnapshotItems = ScanCategory.allCases.contains { !store.items(for: $0).isEmpty }
            Button {
                Task { await store.reverifyLoadedSnapshot() }
            } label: {
                Label(
                    store.isReverifyingSnapshot ? "Re-verifying…" : "Re-verify",
                    systemImage: "checkmark.shield"
                )
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .fixedSize(horizontal: true, vertical: false)
            .disabled(store.isReverifyingSnapshot || !hasAnySnapshotItems)
            .help("Re-verify every snapshot item against disk using lstat")
            .accessibilityLabel("Re-verify")
            .accessibilityIdentifier("reverifySnapshotButton")
        }
    }

    @ViewBuilder
    private var actionBarBatchControls: some View {
        if !store.checkedItemsInAllCategories.isEmpty {
            let count = store.checkedItemsInAllCategories.count
            let sizeSuffix = ByteFormatting.actionSizeSuffix(bytes: store.checkedUniqueBytes)

            Button(role: .destructive) {
                store.requestBatchPermanentDelete()
            } label: {
                Label("Delete Permanently…", systemImage: "trash.slash")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .fixedSize(horizontal: true, vertical: false)
            .foregroundStyle(CleanerColors.danger)

            Button {
                store.requestBatchTrash()
            } label: {
                Label(
                    store.isDryRunEnabled
                        ? "Simulate (\(count)\(sizeSuffix))"
                        : "Move \(count) to Trash\(sizeSuffix)",
                    systemImage: store.isDryRunEnabled ? "eye" : "trash"
                )
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .fixedSize(horizontal: true, vertical: false)
        }
    }

    @ViewBuilder
    private var resultsBody: some View {
        let items = store.visibleItems
        if items.isEmpty {
            emptyState
        } else if category == .duplicates && !store.filteredDuplicateGroups.isEmpty {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: CleanerSpacing.md) {
                    ForEach(store.filteredDuplicateGroups) { group in
                        duplicateGroupCard(group)
                    }
                }
                .padding(CleanerSpacing.md)
            }
            .focusable()
            .focused($isListFocused)
            .onKeyPress(keys: [.upArrow, .downArrow, .space, "a"], phases: [.down, .repeat]) { press in
                handleKeyPress(press)
            }
        } else {
            ScrollView {
                LazyVStack(spacing: CleanerSpacing.xxs) {
                    ForEach(items) { item in
                        row(for: item)
                    }
                }
                .padding(CleanerSpacing.md)
            }
            .focusable()
            .focused($isListFocused)
            .onKeyPress(keys: [.upArrow, .downArrow, .space, "a"], phases: [.down, .repeat]) { press in
                handleKeyPress(press)
            }
        }
    }

    private func duplicateGroupCard(_ group: DuplicateGroup) -> some View {
        VStack(alignment: .leading, spacing: CleanerSpacing.xxs) {
            AdaptiveRowLayout(horizontalSpacing: CleanerSpacing.sm, verticalSpacing: 2, stackedTrailingAlignment: .leading) {
                Text("Exact Match Group · \(group.duplicates.count) duplicate\(group.duplicates.count == 1 ? "" : "s")")
                    .font(CleanerTypography.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Text("\(ByteFormatting.string(from: group.reclaimableBytes)) reclaimable")
                    .font(CleanerTypography.monoMetric)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .padding(.horizontal, CleanerSpacing.sm)
            .padding(.top, CleanerSpacing.xs)

            ForEach(group.allItems) { item in
                row(for: item)
            }
        }
        .padding(.bottom, CleanerSpacing.xs)
        .background(CleanerColors.cardFill, in: RoundedRectangle(cornerRadius: CleanerRadii.md))
        .overlay(
            RoundedRectangle(cornerRadius: CleanerRadii.md)
                .stroke(CleanerColors.hairline, lineWidth: 1)
        )
    }

    private func row(for item: ScannedItem) -> some View {
        ResultRowView(
            item: item,
            isHighlighted: store.selection.highlightedIDs.contains(item.id),
            isChecked: store.selection.checkedIDs.contains(item.id),
            verificationStatus: store.verificationStatus(for: item),
            onToggleCheck: {
                store.toggleCheck(for: item)
            },
            onClickRow: { modifiers in
                isListFocused = true
                store.clickRow(item, modifiers: modifiers)
            }
        )
        .animation(CleanerMotion.standard(reduceMotion: reduceMotion), value: store.selection.highlightedIDs)
    }

    private var emptyState: some View {
        VStack(spacing: CleanerSpacing.sm) {
            Image(systemName: store.isScanning ? "arrow.triangle.2.circlepath" : category.symbolName)
                .font(.system(size: 38))
                .foregroundStyle(.tertiary)
            Text(store.isScanning ? "Scanning \(category.displayName)…" : "No \(category.displayName) Listed")
                .font(CleanerTypography.titleLarge())
            Text(store.isScanning
                 ? "Results stream in as folders are evaluated at low background priority."
                 : "Run a scan or adjust thresholds in Settings to review items in this category.")
                .font(CleanerTypography.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)

            if !store.isScanning {
                Button {
                    Task { await store.startScan() }
                } label: {
                    Label(store.primaryScanActionTitle, systemImage: store.primaryScanActionSymbol)
                }
                .buttonStyle(.borderedProminent)
                .padding(.top, CleanerSpacing.xs)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(CleanerSpacing.xl)
    }

    private func handleKeyPress(_ press: KeyPress) -> KeyPress.Result {
        switch press.key {
        case .upArrow:
            store.moveSelection(offset: -1, extend: press.modifiers.contains(.shift))
            return .handled
        case .downArrow:
            store.moveSelection(offset: 1, extend: press.modifiers.contains(.shift))
            return .handled
        case .space:
            store.toggleHighlightedChecks()
            return .handled
        case "a" where press.modifiers.contains(.command):
            store.selectAllInActiveCategory()
            return .handled
        default:
            return .ignored
        }
    }
}
