import SwiftUI
import AppKit
import CleanerCore

public struct ScanSettingsView: View {
    @Bindable var store: CleanerWorkspaceStore
    let showsHeader: Bool

    public init(store: CleanerWorkspaceStore, showsHeader: Bool = true) {
        self.store = store
        self.showsHeader = showsHeader
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: CleanerSpacing.lg) {
                if showsHeader {
                    VStack(alignment: .leading, spacing: CleanerSpacing.xxs) {
                        Text("Scan & Safety Settings")
                            .font(CleanerTypography.titleLarge())
                        Text("All scanning runs locally on this Mac with zero network requests or telemetry.")
                            .font(CleanerTypography.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                permissionsCard

                folderSection(
                    title: "Scan Roots",
                    subtitle: "Folders included when starting a background scan.",
                    paths: store.configuration.roots.map(\.path),
                    onAdd: addScanRoot,
                    onRemove: removeScanRoot
                )

                folderSection(
                    title: "Excluded Folders",
                    subtitle: "Paths skipped during scanning and blocked during deletion.",
                    paths: store.configuration.excludedFolders,
                    onAdd: addExcludedFolder,
                    onRemove: removeExcludedFolder
                )

                thresholdsCard
                categoriesCard
                safetyPolicyCard
                storedDataCard
            }
            .padding(CleanerSpacing.lg)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            store.refreshPermissionStatus()
        }
        .sheet(isPresented: $store.showingClearStoredScanDataConfirmation) {
            ClearStoredScanDataConfirmationSheet(
                onConfirm: {
                    Task { await store.clearStoredScanData() }
                },
                onCancel: {
                    store.showingClearStoredScanDataConfirmation = false
                }
            )
        }
        .sheet(isPresented: $store.showingResetSettingsConfirmation) {
            ResetSettingsConfirmationSheet(
                onConfirm: {
                    Task { await store.resetSettingsToDefaults() }
                },
                onCancel: {
                    store.showingResetSettingsConfirmation = false
                }
            )
        }
    }

    private var permissionsCard: some View {
        let isGranted = store.permissionStatus.isGranted
        let statusTint = isGranted ? CleanerColors.safe : CleanerColors.caution
        let statusSymbol = isGranted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"

        return VStack(alignment: .leading, spacing: CleanerSpacing.sm) {
            HStack(spacing: CleanerSpacing.xs) {
                Image(systemName: statusSymbol)
                    .font(CleanerTypography.headline)
                    .foregroundStyle(statusTint)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Full Disk Access")
                        .font(CleanerTypography.headline)
                    Text(store.permissionStatus.summaryLabel)
                        .font(CleanerTypography.callout)
                        .foregroundStyle(statusTint)
                        .accessibilityIdentifier("settingsPermissionStatusLabel")
                }

                Spacer()
            }

            Text(
                isGranted
                    ? "CleanerMac can inspect protected user containers, app caches, Downloads, Documents, and Desktop."
                    : "Without Full Disk Access, protected folders are skipped safely during scans. Grant access in System Settings > Privacy & Security > Full Disk Access."
            )
            .font(CleanerTypography.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: CleanerSpacing.xs) {
                if isGranted {
                    Button {
                        store.openFullDiskAccessSettings()
                    } label: {
                        Label("Open Full Disk Access Settings…", systemImage: "gear")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityIdentifier("settingsOpenFullDiskAccessButton")
                    .help("Open Privacy & Security > Full Disk Access in System Settings")
                } else {
                    Button {
                        store.openFullDiskAccessSettings()
                    } label: {
                        Label("Open Full Disk Access Settings…", systemImage: "gear")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .accessibilityIdentifier("settingsOpenFullDiskAccessButton")
                    .help("Open Privacy & Security > Full Disk Access in System Settings")
                }

                Button("Check Status") {
                    store.refreshPermissionStatus()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityIdentifier("settingsCheckPermissionButton")
                .help("Re-check Full Disk Access status")
            }
        }
        .padding(CleanerSpacing.md)
        .background(CleanerColors.cardFill, in: RoundedRectangle(cornerRadius: CleanerRadii.md))
        .overlay(
            RoundedRectangle(cornerRadius: CleanerRadii.md)
                .stroke(CleanerColors.hairline, lineWidth: 1)
        )
        .accessibilityIdentifier("settingsFullDiskAccessCard")
    }

    private func folderSection(
        title: String,
        subtitle: String,
        paths: [String],
        onAdd: @escaping () -> Void,
        onRemove: @escaping (String) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: CleanerSpacing.sm) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(CleanerTypography.headline)
                    Text(subtitle)
                        .font(CleanerTypography.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button(action: onAdd) {
                    Label("Add Folder…", systemImage: "folder.badge.plus")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            if paths.isEmpty {
                Text("None configured")
                    .font(CleanerTypography.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, CleanerSpacing.xs)
            } else {
                ForEach(paths, id: \.self) { path in
                    HStack {
                        Image(systemName: "folder")
                            .foregroundStyle(.secondary)
                        Text(path)
                            .font(CleanerTypography.monoPath)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button {
                            onRemove(path)
                        } label: {
                            Image(systemName: "minus.circle")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                        .help("Remove folder")
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .padding(CleanerSpacing.md)
        .background(CleanerColors.cardFill, in: RoundedRectangle(cornerRadius: CleanerRadii.md))
        .overlay(
            RoundedRectangle(cornerRadius: CleanerRadii.md)
                .stroke(CleanerColors.hairline, lineWidth: 1)
        )
    }

    private var thresholdsCard: some View {
        VStack(alignment: .leading, spacing: CleanerSpacing.md) {
            Text("Analysis Thresholds")
                .font(CleanerTypography.headline)

            HStack {
                Text("Large File Minimum")
                    .font(CleanerTypography.body)
                Spacer()
                Stepper(
                    value: largeFileMBBinding,
                    in: 10...10_240,
                    step: 50
                ) {
                    Text("\(largeFileMBBinding.wrappedValue) MB")
                        .font(CleanerTypography.monoMetric)
                }
            }

            HStack {
                Text("Duplicate Minimum")
                    .font(CleanerTypography.body)
                Spacer()
                Stepper(
                    value: minDuplicateKBBinding,
                    in: 64...51_200,
                    step: 256
                ) {
                    Text("\(minDuplicateKBBinding.wrappedValue) KB")
                        .font(CleanerTypography.monoMetric)
                }
            }

            HStack {
                Text("Old File Age Threshold")
                    .font(CleanerTypography.body)
                Spacer()
                Stepper(
                    value: $store.configuration.oldFileThresholdDays,
                    in: 7...1_825,
                    step: 15
                ) {
                    Text("\(store.configuration.oldFileThresholdDays) days")
                        .font(CleanerTypography.monoMetric)
                }
            }

            HStack {
                Text("Age Basis")
                    .font(CleanerTypography.body)
                Spacer()
                Picker("Age Basis", selection: $store.configuration.ageBasis) {
                    ForEach(AgeBasis.allCases, id: \.self) { basis in
                        Text(basis.displayName).tag(basis)
                    }
                }
                .labelsHidden()
                .frame(width: 240)
            }
        }
        .padding(CleanerSpacing.md)
        .background(CleanerColors.cardFill, in: RoundedRectangle(cornerRadius: CleanerRadii.md))
        .overlay(
            RoundedRectangle(cornerRadius: CleanerRadii.md)
                .stroke(CleanerColors.hairline, lineWidth: 1)
        )
    }

    private var categoriesCard: some View {
        VStack(alignment: .leading, spacing: CleanerSpacing.sm) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Scan Categories")
                    .font(CleanerTypography.headline)
                Text("Choose which categories to include when scanning. At least one category must remain enabled.")
                    .font(CleanerTypography.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ForEach(ScanCategory.allCases) { category in
                let isEnabled = store.configuration.categories.contains(category)
                let isLastEnabled = isEnabled && store.configuration.categories.count <= 1

                HStack(alignment: .center, spacing: CleanerSpacing.sm) {
                    Image(systemName: category.symbolName)
                        .foregroundStyle(.secondary)
                        .frame(width: 18)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(category.displayName)
                            .font(CleanerTypography.body)
                        Text(category.subtitle)
                            .font(CleanerTypography.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: CleanerSpacing.sm)

                    Toggle(category.displayName, isOn: categoryBinding(for: category))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .disabled(isLastEnabled)
                        .accessibilityLabel(category.displayName)
                        .accessibilityIdentifier("settingsCategoryToggle_\(category.rawValue)")
                        .help(
                            isLastEnabled
                                ? "At least one scan category must stay enabled."
                                : "Include \(category.displayName) when scanning"
                        )
                }
                .padding(.vertical, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(CleanerSpacing.md)
        .background(CleanerColors.cardFill, in: RoundedRectangle(cornerRadius: CleanerRadii.md))
        .overlay(
            RoundedRectangle(cornerRadius: CleanerRadii.md)
                .stroke(CleanerColors.hairline, lineWidth: 1)
        )
    }

    private var safetyPolicyCard: some View {
        VStack(alignment: .leading, spacing: CleanerSpacing.sm) {
            Text("Protected-Path Rules")
                .font(CleanerTypography.headline)

            Toggle("Allow App Bundles (*.app) When Explicitly Selected", isOn: $store.configuration.allowAppBundles)
            Text("Disabled by default. System roots (/System, /Library, /usr, /bin) and other users' home folders are always hard-blocked and cannot be overridden.")
                .font(CleanerTypography.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle("Skip Hidden Files During Scan", isOn: $store.configuration.skipHiddenFiles)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(CleanerSpacing.md)
        .background(CleanerColors.cardFill, in: RoundedRectangle(cornerRadius: CleanerRadii.md))
        .overlay(
            RoundedRectangle(cornerRadius: CleanerRadii.md)
                .stroke(CleanerColors.hairline, lineWidth: 1)
        )
    }

    private var storedDataCard: some View {
        VStack(alignment: .leading, spacing: CleanerSpacing.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Stored Data & Reset")
                    .font(CleanerTypography.headline)
                Text("Manage local persistence files under ~/Library/Application Support/CleanerMac/.")
                    .font(CleanerTypography.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(alignment: .center, spacing: CleanerSpacing.sm) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Stored Scan Data")
                        .font(CleanerTypography.body)
                    Text("Deletes session/last-scan.json and session/checkpoint.json while keeping settings.json and Trash history.")
                        .font(CleanerTypography.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: CleanerSpacing.sm)

                Button("Clear Stored Scan Data…", role: .destructive) {
                    store.requestClearStoredScanData()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(store.isScanning)
                .accessibilityIdentifier("settingsClearStoredScanDataButton")
                .help("Delete stored scan snapshot and checkpoint from disk")
            }

            Divider()

            HStack(alignment: .center, spacing: CleanerSpacing.sm) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Settings & Preferences")
                        .font(CleanerTypography.body)
                    Text("Deletes settings.json and restores default folders, thresholds, categories, and view options.")
                        .font(CleanerTypography.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: CleanerSpacing.sm)

                Button("Reset Settings to Defaults…", role: .destructive) {
                    store.requestResetSettings()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityIdentifier("settingsResetDefaultsButton")
                .help("Reset configuration and UI preferences to defaults")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(CleanerSpacing.md)
        .background(CleanerColors.cardFill, in: RoundedRectangle(cornerRadius: CleanerRadii.md))
        .overlay(
            RoundedRectangle(cornerRadius: CleanerRadii.md)
                .stroke(CleanerColors.hairline, lineWidth: 1)
        )
        .accessibilityIdentifier("settingsStoredDataCard")
    }

    private func categoryBinding(for category: ScanCategory) -> Binding<Bool> {
        Binding(
            get: { store.configuration.categories.contains(category) },
            set: { store.setCategory(category, enabled: $0) }
        )
    }

    private var largeFileMBBinding: Binding<Int> {
        Binding(
            get: { max(1, Int(store.configuration.largeFileThresholdBytes / 1_048_576)) },
            set: { store.configuration.largeFileThresholdBytes = UInt64($0) * 1_048_576 }
        )
    }

    private var minDuplicateKBBinding: Binding<Int> {
        Binding(
            get: { max(1, Int(store.configuration.minDuplicateBytes / 1_024)) },
            set: { store.configuration.minDuplicateBytes = UInt64($0) * 1_024 }
        )
    }

    @MainActor
    private func pickDirectory(prompt: String) async -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = prompt
        let response = await panel.begin()
        return response == .OK ? panel.url : nil
    }

    private func addScanRoot() {
        Task {
            guard let url = await pickDirectory(prompt: "Add Scan Root") else { return }
            if !store.configuration.roots.contains(url) {
                store.configuration.roots.append(url)
                await store.refreshVolumeStorage()
            }
        }
    }

    private func removeScanRoot(_ path: String) {
        guard store.configuration.roots.count > 1 else { return }
        store.configuration.roots.removeAll { $0.path == path }
        Task { await store.refreshVolumeStorage() }
    }

    private func addExcludedFolder() {
        Task {
            guard let url = await pickDirectory(prompt: "Exclude Folder") else { return }
            if !store.configuration.excludedFolders.contains(url.path) {
                store.configuration.excludedFolders.append(url.path)
            }
        }
    }

    private func removeExcludedFolder(_ path: String) {
        store.configuration.excludedFolders.removeAll { $0 == path }
    }
}
