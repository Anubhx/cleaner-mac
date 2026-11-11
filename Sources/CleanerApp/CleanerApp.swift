import SwiftUI
import AppKit
import CleanerCore
import CleanerSystem
import CleanerPreview
import CleanerUI

final class CleanerAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            let mainWindow = NSApp.windows.first(where: {
                $0.canBecomeMain
                    && !$0.isSheet
                    && $0.identifier?.rawValue != "com_apple_SwiftUI_Settings_window"
                    && $0.identifier != WelcomeOnboardingPolicy.windowIdentifier
            }) ?? NSApp.windows.first(where: {
                $0.canBecomeMain
                    && !$0.isSheet
                    && $0.identifier != WelcomeOnboardingPolicy.windowIdentifier
            })
            mainWindow?.makeKeyAndOrderFront(nil)
        }
        return true
    }
}

@main
struct CleanerMacApp: App {
    @NSApplicationDelegateAdaptor(CleanerAppDelegate.self) private var appDelegate
    @State private var store: CleanerWorkspaceStore
    @State private var welcomeController: WelcomeWindowController
    @State private var didEvaluateFirstLaunchWelcome = false

    init() {
        InstrumentSerifFontRegistrar.registerBundledFonts()
        let coordinator = ScanCoordinator()
        let executor = DeletionExecutor()
        let historyStore = CleanHistoryStore()
        let snapshotStore = ScanSnapshotStore()
        let permissionChecker = SystemFullDiskAccessChecker()
        let workspaceStore = CleanerWorkspaceStore(
            scanner: coordinator,
            deleter: executor,
            historyStore: historyStore,
            snapshotStore: snapshotStore,
            previewService: PreviewService(),
            permissionChecker: permissionChecker
        )
        let controller = WelcomeWindowController(
            permissionChecker: permissionChecker,
            initialPermissionStatus: workspaceStore.permissionStatus,
            observesApplicationActivation: false,
            onDismissedWithoutCompletion: { [weak workspaceStore] status in
                workspaceStore?.handleWelcomeDismissed(completed: false, permissionStatus: status)
            },
            onCompleted: { [weak workspaceStore] status in
                workspaceStore?.handleWelcomeDismissed(completed: true, permissionStatus: status)
            },
            onPermissionStatusChanged: { [weak workspaceStore] status in
                workspaceStore?.applyPermissionStatus(status)
            }
        )
        workspaceStore.onPermissionStatusDidChange = { [weak controller] status in
            controller?.model.syncPermissionStatus(status)
        }
        _store = State(initialValue: workspaceStore)
        _welcomeController = State(initialValue: controller)
    }

    var body: some Scene {
        WindowGroup("CleanerMac") {
            CleanerRootView(store: store)
                .task {
                    await store.loadInitialHistory()
                    await store.loadInitialSnapshot()
                }
                .onAppear {
                    guard !didEvaluateFirstLaunchWelcome else { return }
                    didEvaluateFirstLaunchWelcome = true
                    Task { @MainActor in
                        welcomeController.showIfNeededOnLaunch()
                    }
                }
        }
        .defaultSize(width: 1240, height: 780)
        .commands {
            CleanerAppCommands(store: store, welcomeController: welcomeController)
        }

        Settings {
            ScanSettingsView(store: store, showsHeader: false)
                .frame(minWidth: 580, minHeight: 520)
        }
    }
}

private struct CleanerAppCommands: Commands {
    @Bindable var store: CleanerWorkspaceStore
    let welcomeController: WelcomeWindowController
    @FocusedValue(\.workspaceStore) private var focusedWorkspace

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Divider()
            Button("Show Welcome") {
                welcomeController.show(isFirstLaunch: false)
            }
        }

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
            Button("Toggle Selection Check") {
                focusedWorkspace?.toggleHighlightedChecks()
            }
            .keyboardShortcut("t", modifiers: [.command, .shift])
            .disabled(focusedWorkspace?.canToggleHighlightedChecks != true)

            Button("Select All in Category") {
                focusedWorkspace?.selectAllInActiveCategory()
            }
            .keyboardShortcut("a", modifiers: [.command, .option])
            .disabled(focusedWorkspace?.visibleItems.isEmpty ?? true)

            Button("Clear Checks in Category") {
                focusedWorkspace?.clearChecksInActiveCategory()
            }
            .keyboardShortcut("a", modifiers: [.command, .shift])
            .disabled(focusedWorkspace?.selection.checkedIDs.isEmpty ?? true)

            Divider()

            Button("Reveal in Finder") {
                focusedWorkspace?.revealFocusedInFinder()
            }
            .keyboardShortcut("r", modifiers: [.command, .option])
            .disabled(focusedWorkspace?.focusedItem == nil)

            Button("Copy Path") {
                focusedWorkspace?.copyFocusedPath()
            }
            .keyboardShortcut("c", modifiers: [.command, .option])
            .disabled(focusedWorkspace?.focusedItem == nil)

            Divider()

            Button("Move Selected to Trash") {
                focusedWorkspace?.requestTrashSelectionOrFocused()
            }
            .keyboardShortcut(.delete, modifiers: .command)
            .disabled(!canTrashFocusedOrChecked)

            Button("Permanently Delete Selected…") {
                focusedWorkspace?.requestBatchPermanentDelete()
            }
            .keyboardShortcut(.delete, modifiers: [.command, .shift])
            .disabled((focusedWorkspace?.checkedItemsInAllCategories.isEmpty ?? true))
        }

        CommandGroup(after: .sidebar) {
            Button("Toggle Preview Inspector") {
                (focusedWorkspace ?? store).isInspectorVisible.toggle()
            }
            .keyboardShortcut("i", modifiers: [.command, .option])
        }
    }

    private var canTrashFocusedOrChecked: Bool {
        guard let workspace = focusedWorkspace else { return false }
        if !workspace.checkedItemsInAllCategories.isEmpty {
            return true
        }
        if let focused = workspace.focusedItem, !focused.isRecommendedKeep {
            return true
        }
        return false
    }
}
