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
                verificationStatus: store.focusedItem.flatMap { store.verificationStatus(for: $0) },
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
            .inspectorColumnWidth(min: 340, ideal: 380, max: 460)
            .toolbar { inspectorToolbarItems }
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
        .focusedSceneValue(\.workspaceStore, store)
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
                    lastScannedAt: store.loadedSnapshotFinishedAt,
                    onPause: { Task { await store.pauseScan() } },
                    onResume: { Task { await store.resumeScan() } },
                    onCancel: { Task { await store.cancelScan() } },
                    onRescan: { Task { await store.startScan() } }
                )
            }
            .padding(CleanerSpacing.sm)
        }
        .background(Color(nsColor: .windowBackgroundColor))
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
                let isLimitedBanner = store.isLimitedScanBannerVisible
                WorkspaceBannerBar(
                    tone: isLimitedBanner ? .subtleCaution : .info,
                    symbolName: isLimitedBanner ? "exclamationmark.triangle.fill" : "info.circle",
                    primaryText: banner,
                    actionTitle: isLimitedBanner ? "Open Full Disk Access Settings…" : nil,
                    actionAccessibilityLabel: isLimitedBanner ? "Open Full Disk Access Settings" : nil,
                    actionIdentifier: isLimitedBanner ? "bannerOpenFullDiskAccessButton" : nil,
                    actionHelp: isLimitedBanner ? "Open Privacy & Security > Full Disk Access in System Settings" : nil,
                    onAction: isLimitedBanner ? { store.openFullDiskAccessSettings() } : nil,
                    dismissAccessibilityLabel: "Dismiss status banner",
                    accessibilityIdentifier: "workspaceStatusBanner",
                    onDismiss: { store.statusBannerMessage = nil }
                )
            }

            if let checkpointBanner = store.interruptedCheckpointPresentation {
                interruptedCheckpointBannerView(for: checkpointBanner)
            }

            if let snapshotBanner = store.snapshotBannerPresentation {
                snapshotBannerView(for: snapshotBanner)
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
        }
    }

    private func interruptedCheckpointBannerView(for presentation: InterruptedCheckpointPresentation) -> some View {
        WorkspaceBannerBar(
            tone: .info,
            symbolName: "clock.arrow.circlepath",
            primaryText: presentation.primaryText,
            secondaryText: presentation.secondaryText,
            actionTitle: "Resume",
            actionAccessibilityLabel: "Resume interrupted scan",
            actionIdentifier: "checkpointResumeButton",
            actionHelp: "Resume the interrupted scan from where it stopped",
            onAction: { Task { await store.resumeInterruptedScan() } },
            secondaryActionTitle: "Start Fresh",
            secondaryActionAccessibilityLabel: "Start fresh scan",
            secondaryActionIdentifier: "checkpointStartFreshButton",
            secondaryActionHelp: "Discard the saved checkpoint and run a new scan",
            onSecondaryAction: { Task { await store.startFreshFromInterruptedCheckpoint() } },
            dismissAccessibilityLabel: "Dismiss interrupted scan prompt",
            accessibilityIdentifier: "interruptedCheckpointBanner",
            onDismiss: { Task { await store.discardInterruptedCheckpoint() } }
        )
    }

    private func snapshotBannerView(for presentation: SnapshotBannerPresentation) -> some View {
        let tone: WorkspaceBannerBar.Tone
        let symbolName: String
        let actionTitle: String?
        let onAction: (() -> Void)?
        let secondaryActionTitle: String?
        let onSecondaryAction: (() -> Void)?

        switch presentation.staleness {
        case .fresh:
            tone = .plainNote
            symbolName = "clock"
            actionTitle = nil
            onAction = nil
            secondaryActionTitle = nil
            onSecondaryAction = nil
        case .subtle:
            tone = .subtleStale
            symbolName = "clock.arrow.circlepath"
            actionTitle = "Scan Again"
            onAction = { Task { await store.startScan() } }
            secondaryActionTitle = nil
            onSecondaryAction = nil
        case .stale:
            tone = .prominentWarning
            symbolName = "exclamationmark.triangle.fill"
            actionTitle = "Scan Again"
            onAction = { Task { await store.startScan() } }
            secondaryActionTitle = "Re-verify"
            onSecondaryAction = { Task { await store.reverifyLoadedSnapshot() } }
        }

        return WorkspaceBannerBar(
            tone: tone,
            symbolName: symbolName,
            primaryText: presentation.primaryText,
            secondaryText: presentation.secondaryText,
            actionTitle: actionTitle,
            actionAccessibilityLabel: actionTitle,
            actionIdentifier: "snapshotBannerRescanButton",
            actionHelp: actionTitle != nil ? "Run a fresh scan before deleting files (Cmd+R)" : nil,
            onAction: onAction,
            secondaryActionTitle: secondaryActionTitle,
            secondaryActionAccessibilityLabel: secondaryActionTitle,
            secondaryActionIdentifier: "snapshotBannerReverifyButton",
            secondaryActionHelp: secondaryActionTitle != nil ? "Re-verify saved snapshot items against disk using lstat" : nil,
            onSecondaryAction: onSecondaryAction,
            dismissAccessibilityLabel: "Dismiss last scan banner",
            accessibilityIdentifier: "snapshotStatusBanner",
            onDismiss: { store.dismissSnapshotBanner() }
        )
    }

    @ToolbarContentBuilder
    private var inspectorToolbarItems: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button {
                store.isInspectorVisible.toggle()
            } label: {
                Label("Preview Inspector", systemImage: "sidebar.right")
            }
            .help("Toggle Preview Pane (Cmd+Option+I)")
            .accessibilityLabel("Preview Inspector")
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
