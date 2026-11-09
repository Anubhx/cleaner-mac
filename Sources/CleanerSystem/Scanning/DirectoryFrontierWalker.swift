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
    static let resourceKeys: [URLResourceKey] = [
        .isDirectoryKey,
        .isRegularFileKey,
        .isSymbolicLinkKey,
        .isPackageKey,
        .isHiddenKey,
        .fileSizeKey,
        .fileAllocatedSizeKey,
        .contentModificationDateKey,
        .creationDateKey,
        .contentAccessDateKey,
        .linkCountKey,
        .isUbiquitousItemKey,
        .ubiquitousItemDownloadingStatusKey,
        .contentTypeKey,
    ]

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

        if children.isEmpty && config.categories.contains(.deadFiles) {
            recordEmptyDirectoryIfEligible(directory, state: &state, safetyGuard: safetyGuard, batchBuffer: &batchBuffer)
            return
        }

        let userLibraryURL = (config.libraryOverride
            ?? safetyGuard.currentUserHome.appendingPathComponent("Library", isDirectory: true))
            .standardizedFileURL
        let userLibraryPath = SafetyGuard.canonicalizeFirmlink(userLibraryURL.path(percentEncoded: false))
        let explicitLibraryRoot = config.roots.contains { root in
            let p = SafetyGuard.canonicalizeFirmlink(root.standardizedFileURL.path(percentEncoded: false))
            return p == userLibraryPath || p.hasPrefix(userLibraryPath + "/")
        }

        let keySet = Set(resourceKeys)
        for child in children {
            if Task.isCancelled { break }
            guard let values = try? child.resourceValues(forKeys: keySet) else { continue }
            if values.isSymbolicLink == true { continue }

            if values.isDirectory == true {
                let childCanonical = SafetyGuard.canonicalizeFirmlink(child.standardizedFileURL.path(percentEncoded: false))
                if !explicitLibraryRoot && (childCanonical == userLibraryPath || childCanonical.hasPrefix(userLibraryPath + "/")) {
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
        let allocated = UInt64(max(0, values.fileAllocatedSize ?? values.fileSize ?? 0))
        state.scannedCount += 1
        state.bytesEvaluated &+= size

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
            isCloudDataless: FilesystemProbes.isCloudDataless(values: values),
            contentTypeIdentifier: values.contentType?.identifier
        )
        state.candidates.append(item)
        if state.configuration.categories.contains(.largeFiles)
            && size >= state.configuration.largeFileThresholdBytes {
            batchBuffer.append(item)
        }
    }
}

