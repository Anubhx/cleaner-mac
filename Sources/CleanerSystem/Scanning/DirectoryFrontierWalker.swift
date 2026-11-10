import Foundation
import UniformTypeIdentifiers
import CleanerCore

struct FrontierWalkState {
    var pending: [URL]
    var pendingHead: Int = 0
    var candidates: [ScannedItem]
    var deadItems: [ScannedItem]
    var visited: Set<String>
    var scannedCount: Int
    var bytesEvaluated: UInt64
    var skippedProtectedDirectories: Int = 0
    let startedAt: Date
    let configuration: ScanConfiguration

    var remainingPendingCount: Int { max(0, pending.count - pendingHead) }
    var hasPendingDirectories: Bool { pendingHead < pending.count }
    var peekNextDirectory: URL? { hasPendingDirectories ? pending[pendingHead] : nil }

    mutating func enqueueDirectory(_ url: URL) {
        pending.append(url)
    }

    mutating func popNextDirectory() -> URL {
        let next = pending[pendingHead]
        pendingHead += 1
        if pendingHead >= 4096 {
            pending.removeFirst(pendingHead)
            pendingHead = 0
        }
        return next
    }

    init(from checkpoint: ScanCheckpoint) {
        self.pending = checkpoint.pendingDirectories
        self.candidates = checkpoint.candidateFiles
        self.deadItems = checkpoint.deadItems
        self.visited = checkpoint.visitedDirectoryPaths
        self.scannedCount = checkpoint.scannedFiles
        self.bytesEvaluated = checkpoint.bytesEvaluated
        self.skippedProtectedDirectories = checkpoint.skippedProtectedDirectories
        self.startedAt = checkpoint.startedAt
        self.configuration = checkpoint.configuration
    }

    func makeCheckpoint() -> ScanCheckpoint {
        ScanCheckpoint(
            configuration: configuration,
            pendingDirectories: Array(pending[pendingHead...]),
            candidateFiles: candidates,
            deadItems: deadItems,
            visitedDirectoryPaths: visited,
            scannedFiles: scannedCount,
            bytesEvaluated: bytesEvaluated,
            skippedProtectedDirectories: skippedProtectedDirectories,
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
        .isUbiquitousItemKey,
    ]

    static func isExplicitLibraryRoot(configuration: ScanConfiguration, userLibraryPath: String) -> Bool {
        configuration.roots.contains { root in
            let p = SafetyGuard.canonicalizeFirmlink(root.standardizedFileURL.path(percentEncoded: false))
            return p == userLibraryPath || p.hasPrefix(userLibraryPath + "/")
        }
    }

    static func userLibraryURL(configuration: ScanConfiguration, safetyGuard: SafetyGuard) -> URL {
        (configuration.libraryOverride
            ?? (configuration.homeOverride ?? safetyGuard.currentUserHome)
                .appendingPathComponent("Library", isDirectory: true))
            .standardizedFileURL
    }

    static func userLibraryPath(configuration: ScanConfiguration, safetyGuard: SafetyGuard) -> String {
        SafetyGuard.canonicalizeFirmlink(userLibraryURL(configuration: configuration, safetyGuard: safetyGuard).path(percentEncoded: false))
    }

    static func isInsideUserLibrary(_ path: String, userLibraryPath: String) -> Bool {
        path == userLibraryPath || path.hasPrefix(userLibraryPath + "/")
    }

    static func isPermissionError(_ error: any Error) -> Bool {
        FilesystemProbes.isPermissionError(error)
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

        let children: [URL]
        do {
            children = try fm.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: resourceKeys,
                options: options
            )
        } catch {
            if Self.isPermissionError(error) {
                state.skippedProtectedDirectories += 1
            }
            return
        }

        let libPath = userLibraryPath(configuration: config, safetyGuard: safetyGuard)
        let explicitLib = isExplicitLibraryRoot(configuration: config, userLibraryPath: libPath)
        let dirCanonical = SafetyGuard.canonicalizeFirmlink(directory.standardizedFileURL.path(percentEncoded: false))
        let inUserLibrary = !explicitLib && isInsideUserLibrary(dirCanonical, userLibraryPath: libPath)

        // macOS sets UF_HIDDEN on ~/Library; ensure it still enters frontier even when skipHiddenFiles is enabled.
        let libURL = userLibraryURL(configuration: config, safetyGuard: safetyGuard)
        let libParentCanonical = SafetyGuard.canonicalizeFirmlink(libURL.deletingLastPathComponent().path(percentEncoded: false))
        var enqueuedHiddenLibrary = false
        if !explicitLib && dirCanonical == libParentCanonical && !state.visited.contains(libPath) {
            if !state.pending[state.pendingHead...].contains(where: { $0.standardizedFileURL == libURL }),
               let libVals = try? libURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
               libVals.isDirectory == true,
               libVals.isSymbolicLink != true {
                state.enqueueDirectory(libURL)
                enqueuedHiddenLibrary = true
            }
        }

        if children.isEmpty && !enqueuedHiddenLibrary && config.categories.contains(.deadFiles) && !inUserLibrary {
            recordEmptyDirectoryIfEligible(directory, state: &state, safetyGuard: safetyGuard, batchBuffer: &batchBuffer)
            return
        }

        let keySet = Set(resourceKeys)
        for child in children {
            if Task.isCancelled { break }
            let values: URLResourceValues
            do {
                values = try child.resourceValues(forKeys: keySet)
            } catch {
                if Self.isPermissionError(error), FilesystemProbes.isDirectoryPath(child) {
                    let childCanonical = FilesystemProbes.canonicalPath(for: child)
                    let allowedLibrary = explicitLib || !shouldSkipUserLibrarySubtree(childCanonical: childCanonical, userLibraryPath: libPath)
                    if allowedLibrary,
                       safetyGuard.isScanDirectoryAllowed(child, excludedFolders: config.excludedFolders),
                       state.visited.insert(childCanonical).inserted {
                        state.skippedProtectedDirectories += 1
                    }
                }
                continue
            }
            if values.isSymbolicLink == true { continue }

            if values.isDirectory == true {
                let childCanonical = SafetyGuard.canonicalizeFirmlink(child.standardizedFileURL.path(percentEncoded: false))
                if !explicitLib && shouldSkipUserLibrarySubtree(childCanonical: childCanonical, userLibraryPath: libPath) {
                    continue
                }
                if EmptyDirectoryPolicy.shouldInspectDirectory(
                    name: child.lastPathComponent,
                    isPackage: values.isPackage ?? false,
                    isHidden: (values.isHidden ?? false) && childCanonical != libPath
                ) {
                    state.enqueueDirectory(child)
                }
                continue
            }

            guard values.isRegularFile == true else { continue }
            recordRegularFile(
                child,
                values: values,
                inUserLibrary: inUserLibrary,
                state: &state,
                batchBuffer: &batchBuffer
            )
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
        inUserLibrary: Bool,
        state: inout FrontierWalkState,
        batchBuffer: inout [ScannedItem]
    ) {
        let size = UInt64(max(0, values.fileSize ?? 0))
        let allocated = UInt64(max(0, values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? values.fileSize ?? 0))
        var dataless = false
        if values.isUbiquitousItem == true,
           let cloudVals = try? fileURL.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]) {
            dataless = cloudVals.ubiquitousItemDownloadingStatus == .notDownloaded
        }
        let physicalBytes = dataless ? 0 : min(size, allocated)
        state.scannedCount += 1
        state.bytesEvaluated &+= physicalBytes

        let isLargeFile = state.configuration.categories.contains(.largeFiles)
            && physicalBytes >= state.configuration.largeFileThresholdBytes
        if inUserLibrary && !isLargeFile {
            return
        }

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
            inode: nil,
            linkCount: 1,
            isCloudDataless: dataless,
            contentTypeIdentifier: nil
        )
        state.candidates.append(item)
        if isLargeFile {
            batchBuffer.append(item)
        }
    }
}

