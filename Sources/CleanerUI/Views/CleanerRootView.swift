import SwiftUI
import CleanerCore

public struct CleanerRootView: View {
    @Bindable var store: CleanerWorkspaceStore

    public init(store: CleanerWorkspaceStore) {
        self.store = store
    }

    public var body: some View {
        NavigationSplitView {
            sidebarContent
                .navigationSplitViewColumnWidth(min: 220, ideal: 256, max: 300)
        } detail: {
            detailContent
        }
        .inspector(isPresented: $store.isInspectorVisible) {
            PreviewPaneView(
                item: store.focusedItem,
                payload: store.previewPayload,
                isLoading: store.isLoadingPreview,
                isChecked: store.focusedItem.map { store.selection.checkedIDs.contains($0.id) } ?? false,
                onToggleCheck: {
                    if let item = store.focusedItem {
                        store.toggleCheck(for: item)
                    }
                },
                onTrashFocused: {
                    if let item = store.focusedItem {
                        store.requestSingleTrash(item: item)
                    }
                },
                onPermanentDeleteFocused: {
                    if let item = store.focusedItem {
                        store.requestSinglePermanentDelete(item: item)
                    }
                }
            )
            .inspectorColumnWidth(min: 310, ideal: 360, max: 440)
        }
        .searchable(text: $store.searchQuery, placement: .toolbar, prompt: "Filter filename or path")
        .toolbar { toolbarItems }
        .onChange(of: store.selectedSidebarDestination) { _, _ in
            if store.focusedItem == nil, let first = store.visibleItems.first {
                store.clickRow(first, modifiers: [])
            } else {
                store.refreshPreviewForFocus()
            }
        }
        .sheet(isPresented: $store.showingTrashConfirmation) {
            MoveToTrashConfirmationSheet(
                items: store.pendingDeletionItems,
                totalBytes: store.pendingDeletionBytes,
                isDryRun: store.isDryRunEnabled,
                onConfirm: {
                    store.showingTrashConfirmation = false
                    Task { await store.executePendingCleanup(mode: .moveToTrash) }
                },
                onCancel: {
                    store.showingTrashConfirmation = false
                    store.pendingDeletionItems = []
                }
            )
        }
        .sheet(isPresented: $store.showingPermanentConfirmation) {
            PermanentDeleteConfirmationSheet(
                items: store.pendingDeletionItems,
                totalBytes: store.pendingDeletionBytes,
                isDryRun: store.isDryRunEnabled,
                onConfirm: {
                    store.showingPermanentConfirmation = false
                    Task { await store.executePendingCleanup(mode: .permanentDelete(confirmed: true)) }
                },
                onCancel: {
                    store.showingPermanentConfirmation = false
                    store.pendingDeletionItems = []
                }
            )
        }
        .sheet(item: reportBinding) { report in
            ExecutionReportSheet(report: report) {
                store.lastExecutionReport = nil
            }
        }
        .frame(minWidth: 980, minHeight: 640)
    }

    private var sidebarContent: some View {
        VStack(spacing: 0) {
            List(selection: $store.selectedSidebarDestination) {
                Section("Scan Categories") {
                    ForEach(ScanCategory.allCases) { category in
                        sidebarCategoryRow(category)
                            .tag(SidebarDestination.category(category))
                    }
                }

                Section("Reversibility & Rules") {
                    Label {
                        HStack {
                            Text("Restore History")
                            Spacer()
                            if !store.historyEntries.isEmpty {
                                Text("\(store.historyEntries.count)")
                                    .font(CleanerTypography.monoMetric)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    } icon: {
                        Image(systemName: "arrow.uturn.backward.circle")
                    }
                    .tag(SidebarDestination.history)

                    Label("Scan & Safety Settings", systemImage: "lock.shield")
                        .tag(SidebarDestination.settings)
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)

            Divider()

            VStack(spacing: CleanerSpacing.xs) {
                if let snapshot = store.volumeStorage {
                    DiskCapacityHUD(snapshot: snapshot)
                }

                BackgroundScanHUD(
                    progress: store.progress,
                    isScanning: store.isScanning,
                    isPaused: store.isPaused,
                    onPause: { Task { await store.pauseScan() } },
                    onResume: { Task { await store.resumeScan() } },
                    onCancel: { Task { await store.cancelScan() } },
                    onRescan: { Task { await store.startScan() } }
                )
            }
            .padding(CleanerSpacing.sm)
        }
        .background(.ultraThinMaterial)
    }

    private func sidebarCategoryRow(_ category: ScanCategory) -> some View {
        let count = store.items(for: category).count
        let bytes = store.reclaimableBytes(for: category)
        return Label {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(category.displayName)
                        .font(CleanerTypography.callout)
                    if bytes > 0 {
                        Text(ByteFormatting.string(from: bytes))
                            .font(CleanerTypography.monoPath)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if count > 0 {
                    Text("\(count)")
                        .font(CleanerTypography.monoMetric)
                        .foregroundStyle(.secondary)
                }
            }
        } icon: {
            Image(systemName: category.symbolName)
        }
    }

    @ViewBuilder
    private var detailContent: some View {
        VStack(spacing: 0) {
            if store.isDryRunEnabled {
                DryRunRibbon()
            }

            if let banner = store.statusBannerMessage {
                HStack(spacing: CleanerSpacing.xs) {
                    Image(systemName: "info.circle")
                        .foregroundStyle(Color.accentColor)
                    Text(banner)
                        .font(CleanerTypography.callout)
                    Spacer()
                    Button {
                        store.statusBannerMessage = nil
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.borderless)
                }
                .padding(.horizontal, CleanerSpacing.md)
                .padding(.vertical, CleanerSpacing.xs)
                .background(.regularMaterial)
                Divider()
            }

            switch store.selectedSidebarDestination {
            case .category(let category):
                ResultsListView(store: store, category: category)
            case .history:
                HistoryView(store: store)
            case .settings:
                ScanSettingsView(store: store)
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Toggle(isOn: $store.isDryRunEnabled) {
                HStack(spacing: CleanerSpacing.xxs + 2) {
                    Image(systemName: "eye")
                    Text("Dry Run")
                }
            }
            .toggleStyle(.button)
            .help("Simulate deletions without changing files on disk (Cmd+Shift+D)")
            .accessibilityLabel("Dry Run")

            if store.isScanning {
                Button {
                    Task {
                        if store.isPaused {
                            await store.resumeScan()
                        } else {
                            await store.pauseScan()
                        }
                    }
                } label: {
                    Label(store.isPaused ? "Resume" : "Pause", systemImage: store.isPaused ? "play.fill" : "pause.fill")
                }

                Button {
                    Task { await store.cancelScan() }
                } label: {
                    Label("Cancel", systemImage: "xmark.circle")
                }
            } else {
                Button {
                    Task { await store.startScan() }
                } label: {
                    HStack(spacing: CleanerSpacing.xxs + 2) {
                        Image(systemName: store.primaryScanActionSymbol)
                        Text(store.primaryScanActionTitle)
                    }
                }
                .buttonStyle(.borderedProminent)
                .help(store.hasCompletedOrCancelledScan
                      ? "Run a fresh scan across your selected folders (Cmd+R)"
                      : "Scan your Mac for duplicates, large files, old files, and leftovers (Cmd+R)")
                .accessibilityLabel(store.primaryScanActionTitle)
            }

            Button {
                store.isInspectorVisible.toggle()
            } label: {
                Label("Preview Inspector", systemImage: "sidebar.right")
            }
            .help("Toggle Preview Pane")
        }
    }

    private var reportBinding: Binding<IdentifiableExecutionReport?> {
        Binding(
            get: { store.lastExecutionReport.map(IdentifiableExecutionReport.init) },
            set: { newValue in
                if newValue == nil { store.lastExecutionReport = nil }
            }
        )
    }
}

private struct IdentifiableExecutionReport: Identifiable {
    let id = UUID()
    let report: DeletionExecutionReport

    init(_ report: DeletionExecutionReport) {
        self.report = report
    }
}

private extension ExecutionReportSheet {
    init(report wrapper: IdentifiableExecutionReport, onDismiss: @escaping () -> Void) {
        self.init(report: wrapper.report, onDismiss: onDismiss)
    }
}
