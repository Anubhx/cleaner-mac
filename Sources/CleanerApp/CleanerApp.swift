import SwiftUI
import AppKit
import CleanerCore
import CleanerSystem
import CleanerPreview
import CleanerUI

@main
struct CleanerMacApp: App {
    @State private var store: CleanerWorkspaceStore

    init() {
        InstrumentSerifFontRegistrar.registerBundledFonts()
        let coordinator = ScanCoordinator()
        let executor = DeletionExecutor()
        let historyStore = CleanHistoryStore()
        _store = State(initialValue: CleanerWorkspaceStore(
            scanner: coordinator,
            deleter: executor,
            historyStore: historyStore,
            previewService: PreviewService()
        ))
    }

    var body: some Scene {
        WindowGroup("CleanerMac") {
            CleanerRootView(store: store)
                .task {
                    await store.loadInitialHistory()
                }
        }
        .defaultSize(width: 1240, height: 780)
        .commands {
            CommandGroup(replacing: .newItem) {}

            CommandMenu("Scan") {
                Button(store.isScanning ? "Scanning…" : store.primaryScanActionTitle) {
                    Task { await store.startScan() }
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(store.isScanning)

                if store.isScanning {
                    Button(store.isPaused ? "Resume Scan" : "Pause Scan") {
                        Task {
                            if store.isPaused {
                                await store.resumeScan()
                            } else {
                                await store.pauseScan()
                            }
                        }
                    }
                    .keyboardShortcut("p", modifiers: [.command, .shift])

                    Button("Cancel Scan") {
                        Task { await store.cancelScan() }
                    }
                    .keyboardShortcut(".", modifiers: .command)
                }

                Divider()

                Toggle("Dry-Run Mode", isOn: $store.isDryRunEnabled)
                    .keyboardShortcut("d", modifiers: [.command, .shift])
            }

            CommandMenu("Cleanup") {
                Button("Select All in Category") {
                    store.selectAllInActiveCategory()
                }
                .keyboardShortcut("a", modifiers: [.command, .option])

                Button("Clear Checks in Category") {
                    store.clearChecksInActiveCategory()
                }
                .keyboardShortcut("a", modifiers: [.command, .shift])

                Divider()

                Button("Move Selected to Trash") {
                    store.requestBatchTrash()
                }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(store.checkedItemsInAllCategories.isEmpty)

                Button("Permanently Delete Selected…") {
                    store.requestBatchPermanentDelete()
                }
                .keyboardShortcut(.delete, modifiers: [.command, .shift])
                .disabled(store.checkedItemsInAllCategories.isEmpty)
            }

            CommandGroup(after: .sidebar) {
                Button("Toggle Preview Inspector") {
                    store.isInspectorVisible.toggle()
                }
                .keyboardShortcut("i", modifiers: [.command, .option])
            }
        }
    }
}
