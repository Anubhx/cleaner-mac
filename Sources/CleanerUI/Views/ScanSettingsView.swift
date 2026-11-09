import SwiftUI
import AppKit
import CleanerCore

public struct ScanSettingsView: View {
    @Bindable var store: CleanerWorkspaceStore

    public init(store: CleanerWorkspaceStore) {
        self.store = store
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: CleanerSpacing.lg) {
                VStack(alignment: .leading, spacing: CleanerSpacing.xxs) {
                    Text("Scan & Safety Settings")
                        .font(CleanerTypography.titleLarge())
                    Text("All scanning runs locally on this Mac with zero network requests or telemetry.")
                        .font(CleanerTypography.callout)
                        .foregroundStyle(.secondary)
                }

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
                safetyPolicyCard
            }
            .padding(CleanerSpacing.lg)
        }
        .background(Color(nsColor: .windowBackgroundColor))
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
                    Text(subtitle).font(CleanerTypography.caption).foregroundStyle(.secondary)
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

    private var safetyPolicyCard: some View {
        VStack(alignment: .leading, spacing: CleanerSpacing.sm) {
            Text("Protected-Path Rules")
                .font(CleanerTypography.headline)

            Toggle("Allow App Bundles (*.app) When Explicitly Selected", isOn: $store.configuration.allowAppBundles)
            Text("Disabled by default. System roots (/System, /Library, /usr, /bin) and other users' home folders are always hard-blocked and cannot be overridden.")
                .font(CleanerTypography.caption)
                .foregroundStyle(.secondary)

            Toggle("Skip Hidden Files During Scan", isOn: $store.configuration.skipHiddenFiles)
        }
        .padding(CleanerSpacing.md)
        .background(CleanerColors.cardFill, in: RoundedRectangle(cornerRadius: CleanerRadii.md))
        .overlay(
            RoundedRectangle(cornerRadius: CleanerRadii.md)
                .stroke(CleanerColors.hairline, lineWidth: 1)
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

    private func pickDirectory(prompt: String) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = prompt
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func addScanRoot() {
        guard let url = pickDirectory(prompt: "Add Scan Root") else { return }
        if !store.configuration.roots.contains(url) {
            store.configuration.roots.append(url)
            Task { await store.refreshVolumeStorage() }
        }
    }

    private func removeScanRoot(_ path: String) {
        guard store.configuration.roots.count > 1 else { return }
        store.configuration.roots.removeAll { $0.path == path }
        Task { await store.refreshVolumeStorage() }
    }

    private func addExcludedFolder() {
        guard let url = pickDirectory(prompt: "Exclude Folder") else { return }
        if !store.configuration.excludedFolders.contains(url.path) {
            store.configuration.excludedFolders.append(url.path)
        }
    }

    private func removeExcludedFolder(_ path: String) {
        store.configuration.excludedFolders.removeAll { $0 == path }
    }
}
