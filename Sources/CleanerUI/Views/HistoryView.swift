import SwiftUI
import AppKit
import CleanerCore

public struct HistoryView: View {
    @Bindable var store: CleanerWorkspaceStore

    public init(store: CleanerWorkspaceStore) {
        self.store = store
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if store.historyEntries.isEmpty {
                emptyHistory
            } else {
                ScrollView {
                    LazyVStack(spacing: CleanerSpacing.xs) {
                        ForEach(store.historyEntries) { entry in
                            historyRow(entry)
                        }
                    }
                    .padding(CleanerSpacing.lg)
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .task {
            await store.loadInitialHistory()
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: CleanerSpacing.xxs) {
                Text("Restore History")
                    .font(CleanerTypography.titleLarge())
                Text("Items moved to Trash carry verified inode receipts for one-click restoration.")
                    .font(CleanerTypography.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text("\(store.historyEntries.count) entries")
                .font(CleanerTypography.monoMetric)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, CleanerSpacing.lg)
        .padding(.vertical, CleanerSpacing.md)
    }

    private func historyRow(_ entry: TrashHistoryEntry) -> some View {
        HStack(spacing: CleanerSpacing.md) {
            Image(systemName: "arrow.uturn.backward.circle")
                .font(.title2)
                .foregroundStyle(CleanerColors.safe)

            VStack(alignment: .leading, spacing: CleanerSpacing.xxs) {
                Text(URL(fileURLWithPath: entry.originalPath).lastPathComponent)
                    .font(CleanerTypography.body)
                    .fontWeight(.medium)
                Text(entry.originalPath)
                    .font(CleanerTypography.monoPath)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("Trashed \(entry.trashedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(CleanerTypography.caption)
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            Text(ByteFormatting.string(from: entry.bytes))
                .font(CleanerTypography.monoMetric)
                .foregroundStyle(.secondary)

            Button {
                Task { await store.restoreHistoryEntry(entry) }
            } label: {
                Label("Restore", systemImage: "arrow.uturn.backward")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(CleanerSpacing.sm)
        .background(CleanerColors.cardFill, in: RoundedRectangle(cornerRadius: CleanerRadii.md))
        .overlay(
            RoundedRectangle(cornerRadius: CleanerRadii.md)
                .stroke(CleanerColors.hairline, lineWidth: 1)
        )
    }

    private var emptyHistory: some View {
        VStack(spacing: CleanerSpacing.sm) {
            Image(systemName: "arrow.uturn.backward.circle")
                .font(.system(size: 38))
                .foregroundStyle(.tertiary)
            Text("No Restorable History Yet")
                .font(CleanerTypography.titleLarge())
            Text("Files you move to the Trash from CleanerMac will appear here with restore receipts.")
                .font(CleanerTypography.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(CleanerSpacing.xl)
    }
}
