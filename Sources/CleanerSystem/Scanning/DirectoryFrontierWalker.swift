import Foundation
import UniformTypeIdentifiers
import CleanerCore

struct FrontierWalkState {
    var pending: [URL]
    var candidates: [ScannedItem]
    var deadItems: [ScannedItem]
    var visited: Set<String>
    var scannedCount: Int
    var bytesEvaluated: UInt64
    let startedAt: Date
    let configuration: ScanConfiguration

    init(from checkpoint: ScanCheckpoint) {
        self.pending = checkpoint.pendingDirectories
        self.candidates = checkpoint.candidateFiles
        self.deadItems = checkpoint.deadItems
        self.visited = checkpoint.visitedDirectoryPaths
        self.scannedCount = checkpoint.scannedFiles
        self.bytesEvaluated = checkpoint.bytesEvaluated
        self.startedAt = checkpoint.startedAt
        self.configuration = checkpoint.configuration
    }

    func makeCheckpoint() -> ScanCheckpoint {
        ScanCheckpoint(
            configuration: configuration,
            pendingDirectories: pending,
            candidateFiles: candidates,
            deadItems: deadItems,
            visitedDirectoryPaths: visited,
            scannedFiles: scannedCount,
            bytesEvaluated: bytesEvaluated,
            startedAt: startedAt
        )
    }
}

enum DirectoryFrontierWalker {
    private static let blockedLibraryDirectSubdirs: Set<String> = [
        "Preferences",
        "Keychains",
        "Cookies",
        "Accounts",
        "Mail",
        "Messages",
        "Safari",
        "Calendars",
        "Contacts",
        "Reminders",
        "Suggestions",
        "BiometricKit",
        "IdentityServices",
        "HomeKit",
        "CloudKit",
        "SyncedPreferences",
        "Mobile Documents",
        "Group Containers",
        "Application Scripts",
        "LaunchAgents",
        "Caches",
        "Logs",
        "HTTPStorages",
        "Saved Application State",
        "WebKit",
    ]

    static let resourceKeys: [URLResourceKey] = [
        .isDirectoryKey,
        .isRegularFileKey,
        .isSymbolicLinkKey,
        .isPackageKey,
        .isHiddenKey,
        .fileSizeKey,
        .fileAllocatedSizeKey,
        .totalFileAllocatedSizeKey,
        .contentModificationDateKey,
        .creationDateKey,
        .contentAccessDateKey,
        .linkCountKey,
        .isUbiquitousItemKey,
        .ubiquitousItemDownloadingStatusKey,
        .contentTypeKey,
    ]

    static func isExplicitLibraryRoot(configuration: ScanConfiguration, userLibraryPath: String) -> Bool {
        configuration.roots.contains { root in
            let p = SafetyGuard.canonicalizeFirmlink(root.standardizedFileURL.path(percentEncoded: false))
            return p == userLibraryPath || p.hasPrefix(userLibraryPath + "/")
        }
    }

    static func userLibraryPath(configuration: ScanConfiguration, safetyGuard: SafetyGuard) -> String {
        let userLibraryURL = (configuration.libraryOverride
            ?? (configuration.homeOverride ?? safetyGuard.currentUserHome)
                .appendingPathComponent("Library", isDirectory: true))
            .standardizedFileURL
        return SafetyGuard.canonicalizeFirmlink(userLibraryURL.path(percentEncoded: false))
    }

    static func isInsideUserLibrary(_ path: String, userLibraryPath: String) -> Bool {
        path == userLibraryPath || path.hasPrefix(userLibraryPath + "/")
    }

    static func inspectDirectory(
        _ directory: URL,
        state: inout FrontierWalkState,
        safetyGuard: SafetyGuard,
        batchBuffer: inout [ScannedItem]
    ) {
        let fm = FileManager.default
        let config = state.configuration
        let options: FileManager.DirectoryEnumerationOptions = config.skipHiddenFiles ? [.skipsHiddenFiles] : []

        guard let children = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: resourceKeys,
            options: options
        ) else { return }

        let libPath = userLibraryPath(configuration: config, safetyGuard: safetyGuard)
        let explicitLib = isExplicitLibraryRoot(configuration: config, userLibraryPath: libPath)
        let dirCanonical = SafetyGuard.canonicalizeFirmlink(directory.standardizedFileURL.path(percentEncoded: false))
        let inUserLibrary = !explicitLib && isInsideUserLibrary(dirCanonical, userLibraryPath: libPath)

        if children.isEmpty && config.categories.contains(.deadFiles) && !inUserLibrary {
            recordEmptyDirectoryIfEligible(directory, state: &state, safetyGuard: safetyGuard, batchBuffer: &batchBuffer)
            return
        }

        let keySet = Set(resourceKeys)
        for child in children {
            if Task.isCancelled { break }
            guard let values = try? child.resourceValues(forKeys: keySet) else { continue }
            if values.isSymbolicLink == true { continue }

            if values.isDirectory == true {
                let childCanonical = SafetyGuard.canonicalizeFirmlink(child.standardizedFileURL.path(percentEncoded: false))
                if !explicitLib && shouldSkipUserLibrarySubtree(childCanonical: childCanonical, userLibraryPath: libPath) {
                    continue
                }
                if EmptyDirectoryPolicy.shouldInspectDirectory(
                    name: child.lastPathComponent,
                    isPackage: values.isPackage ?? false,
                    isHidden: values.isHidden ?? false
                ) {
                    state.pending.append(child)
                }
                continue
            }

            guard values.isRegularFile == true else { continue }
            recordRegularFile(child, values: values, state: &state, batchBuffer: &batchBuffer)
        }
    }

    private static func shouldSkipUserLibrarySubtree(
        childCanonical: String,
        userLibraryPath: String
    ) -> Bool {
        guard childCanonical.hasPrefix(userLibraryPath + "/") else { return false }
        let relative = String(childCanonical.dropFirst(userLibraryPath.count + 1))
        let components = relative.split(separator: "/").map(String.init)
        guard let top = components.first else { return false }
        if blockedLibraryDirectSubdirs.contains(top) {
            return true
        }
        // Inside Containers/<bundle>/Data/Library/<blockedSubdir>
        if top == "Containers", components.count >= 5, components[2] == "Data", components[3] == "Library" {
            return blockedLibraryDirectSubdirs.contains(components[4])
        }
        return false
    }

    private static func recordEmptyDirectoryIfEligible(
        _ directory: URL,
        state: inout FrontierWalkState,
        safetyGuard: SafetyGuard,
        batchBuffer: inout [ScannedItem]
    ) {
        let isRoot = state.configuration.roots.contains { $0.standardizedFileURL == directory }
        guard !isRoot,
              let values = try? directory.resourceValues(forKeys: [.isPackageKey, .isHiddenKey]),
              EmptyDirectoryPolicy.shouldInspectDirectory(
                  name: directory.lastPathComponent,
                  isPackage: values.isPackage ?? false,
                  isHidden: values.isHidden ?? false
              ),
              (try? safetyGuard.validatePath(directory, excludedFolders: state.configuration.excludedFolders)) != nil,
              FilesystemProbes.isCleanableByCurrentProcess(directory) else {
            return
        }

        let emptyItem = ScannedItem(
            url: directory,
            name: directory.lastPathComponent,
            logicalSize: 0,
            allocatedSize: 0,
            isDirectory: true,
            category: .deadFiles,
            deadKind: .emptyDirectory,
            inode: FilesystemProbes.inodeIdentity(for: directory)
        )
        state.deadItems.append(emptyItem)
        batchBuffer.append(emptyItem)
    }

    private static func recordRegularFile(
        _ fileURL: URL,
        values: URLResourceValues,
        state: inout FrontierWalkState,
        batchBuffer: inout [ScannedItem]
    ) {
        let size = UInt64(max(0, values.fileSize ?? 0))
        let allocated = UInt64(max(0, values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? values.fileSize ?? 0))
        let dataless = FilesystemProbes.isCloudDataless(values: values)
        let physicalBytes = dataless ? 0 : min(size, allocated)
        state.scannedCount += 1
        state.bytesEvaluated &+= physicalBytes

        let item = ScannedItem(
            url: fileURL,
            name: fileURL.lastPathComponent,
            logicalSize: size,
            allocatedSize: allocated,
            isDirectory: false,
            modifiedDate: values.contentModificationDate,
            createdDate: values.creationDate,
            accessedDate: values.contentAccessDate,
            category: .largeFiles,
            inode: FilesystemProbes.inodeIdentity(for: fileURL),
            linkCount: values.linkCount ?? 1,
            isCloudDataless: dataless,
            contentTypeIdentifier: values.contentType?.identifier
        )
        state.candidates.append(item)
        if state.configuration.categories.contains(.largeFiles)
            && physicalBytes >= state.configuration.largeFileThresholdBytes {
            batchBuffer.append(item)
        }
    }
}

