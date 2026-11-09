import Foundation
import UniformTypeIdentifiers
import CleanerCore

public actor ScanCoordinator {
    private let safetyGuard: SafetyGuard
    private let perDirectoryDelay: Duration?

    private var activeTask: Task<ScanOutcome, Never>?
    private var checkpoint: ScanCheckpoint?
    private var isPauseRequested = false
    private var isCancelRequested = false
    private var streamPair: (stream: AsyncStream<ScanBatch>, continuation: AsyncStream<ScanBatch>.Continuation) =
        AsyncStream.makeStream(of: ScanBatch.self)

    public init(safetyGuard: SafetyGuard = SafetyGuard(), perDirectoryDelay: Duration? = nil) {
        self.safetyGuard = safetyGuard
        self.perDirectoryDelay = perDirectoryDelay
    }

    public func makeProgressStream() -> AsyncStream<ScanBatch> {
        streamPair.continuation.finish()
        streamPair = AsyncStream.makeStream(of: ScanBatch.self)
        return streamPair.stream
    }

    public func runFullScan(configuration: ScanConfiguration) async -> ScanOutcome {
        try? start(configuration: configuration)
        guard let activeTask else { return ScanOutcome() }
        return await activeTask.value
    }

    public func start(configuration: ScanConfiguration) throws {
        activeTask?.cancel()
        isPauseRequested = false
        isCancelRequested = false

        let initialCheckpoint = ScanCheckpoint(
            configuration: configuration,
            pendingDirectories: configuration.roots.map(\.standardizedFileURL),
            candidateFiles: [],
            deadItems: [],
            visitedDirectoryPaths: [],
            scannedFiles: 0,
            bytesEvaluated: 0,
            startedAt: Date()
        )
        checkpoint = initialCheckpoint
        launchWorker(from: initialCheckpoint)
    }

    public func pause() async -> ScanCheckpoint {
        isPauseRequested = true
        if let activeTask {
            _ = await activeTask.value
        }
        return checkpoint ?? ScanCheckpoint(
            configuration: ScanConfiguration(),
            pendingDirectories: [],
            candidateFiles: [],
            deadItems: [],
            visitedDirectoryPaths: [],
            scannedFiles: 0,
            bytesEvaluated: 0,
            startedAt: Date()
        )
    }

    public func resume(from savedCheckpoint: ScanCheckpoint) async -> ScanOutcome {
        isPauseRequested = false
        isCancelRequested = false
        checkpoint = savedCheckpoint
        launchWorker(from: savedCheckpoint)
        guard let activeTask else { return ScanOutcome() }
        return await activeTask.value
    }

    public func cancel() async -> ScanOutcome {
        isCancelRequested = true
        activeTask?.cancel()
        guard let activeTask else {
            let progress = ScanProgress(phase: .cancelled)
            emitBatch([], progress: progress, finishStream: true)
            return ScanOutcome(progress: progress, wasCancelled: true)
        }
        return await activeTask.value
    }

    private func launchWorker(from initial: ScanCheckpoint) {
        let guardPolicy = safetyGuard
        activeTask = Task(priority: .utility) { [weak self] in
            guard let self else { return ScanOutcome() }
            return await self.executeScanLoop(startingFrom: initial, safetyGuard: guardPolicy)
        }
    }

    private func executeScanLoop(
        startingFrom initial: ScanCheckpoint,
        safetyGuard: SafetyGuard
    ) async -> ScanOutcome {
        let config = initial.configuration
        var pending = initial.pendingDirectories
        var candidates = initial.candidateFiles
        var deadItems = initial.deadItems
        var visited = initial.visitedDirectoryPaths
        var scannedCount = initial.scannedFiles
        var bytesEvaluated = initial.bytesEvaluated
        var batchBuffer: [ScannedItem] = []
        var lastFlush = Date()

        let fm = FileManager.default
        let keys: [URLResourceKey] = [
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
        let keySet = Set(keys)

        while !pending.isEmpty {
            if Task.isCancelled || isCancelRequested {
                let progress = ScanProgress(
                    phase: .cancelled,
                    currentPath: "",
                    scannedFiles: scannedCount,
                    bytesEvaluated: bytesEvaluated,
                    pendingDirectoriesCount: pending.count,
                    startedAt: initial.startedAt
                )
                emitBatch(batchBuffer, progress: progress, finishStream: true)
                return ScanOutcome(progress: progress, wasCancelled: true)
            }

            if isPauseRequested {
                checkpoint = ScanCheckpoint(
                    configuration: config,
                    pendingDirectories: pending,
                    candidateFiles: candidates,
                    deadItems: deadItems,
                    visitedDirectoryPaths: visited,
                    scannedFiles: scannedCount,
                    bytesEvaluated: bytesEvaluated,
                    startedAt: initial.startedAt
                )
                let progress = ScanProgress(
                    phase: .paused,
                    currentPath: pending.first?.path ?? "",
                    scannedFiles: scannedCount,
                    bytesEvaluated: bytesEvaluated,
                    pendingDirectoriesCount: pending.count,
                    startedAt: initial.startedAt
                )
                emitBatch(batchBuffer, progress: progress, finishStream: false)
                return ScanOutcome(progress: progress, wasCancelled: false)
            }

            let currentDir = pending.removeFirst().standardizedFileURL
            if let perDirectoryDelay {
                try? await Task.sleep(for: perDirectoryDelay)
            }
            let canonicalDir = SafetyGuard.canonicalizeFirmlink(currentDir.path(percentEncoded: false))
            guard visited.insert(canonicalDir).inserted else { continue }
            guard safetyGuard.isScanDirectoryAllowed(currentDir, excludedFolders: config.excludedFolders) else { continue }

            let options: FileManager.DirectoryEnumerationOptions = config.skipHiddenFiles ? [.skipsHiddenFiles] : []
            guard let children = try? fm.contentsOfDirectory(
                at: currentDir,
                includingPropertiesForKeys: keys,
                options: options
            ) else {
                continue
            }

            if children.isEmpty && config.categories.contains(.deadFiles) {
                let isRoot = config.roots.contains { $0.standardizedFileURL == currentDir }
                if !isRoot,
                   let values = try? currentDir.resourceValues(forKeys: [.isPackageKey, .isHiddenKey]),
                   EmptyDirectoryPolicy.shouldInspectDirectory(
                       name: currentDir.lastPathComponent,
                       isPackage: values.isPackage ?? false,
                       isHidden: values.isHidden ?? false
                   ),
                   (try? safetyGuard.validatePath(currentDir, excludedFolders: config.excludedFolders)) != nil,
                   FilesystemProbes.isCleanableByCurrentProcess(currentDir) {
                    let emptyItem = ScannedItem(
                        url: currentDir,
                        name: currentDir.lastPathComponent,
                        logicalSize: 0,
                        allocatedSize: 0,
                        isDirectory: true,
                        category: .deadFiles,
                        deadKind: .emptyDirectory,
                        inode: FilesystemProbes.inodeIdentity(for: currentDir)
                    )
                    deadItems.append(emptyItem)
                    batchBuffer.append(emptyItem)
                }
                continue
            }

            for child in children {
                if Task.isCancelled || isCancelRequested { break }
                guard let values = try? child.resourceValues(forKeys: keySet) else { continue }
                if values.isSymbolicLink == true { continue }

                if values.isDirectory == true {
                    let isPkg = values.isPackage ?? false
                    let isHid = values.isHidden ?? false
                    if EmptyDirectoryPolicy.shouldInspectDirectory(
                        name: child.lastPathComponent,
                        isPackage: isPkg,
                        isHidden: isHid
                    ) {
                        pending.append(child)
                    }
                    continue
                }

                guard values.isRegularFile == true else { continue }
                let size = UInt64(max(0, values.fileSize ?? 0))
                let allocated = UInt64(max(0, values.fileAllocatedSize ?? values.fileSize ?? 0))
                scannedCount += 1
                bytesEvaluated &+= size

                let item = ScannedItem(
                    url: child,
                    name: child.lastPathComponent,
                    logicalSize: size,
                    allocatedSize: allocated,
                    isDirectory: false,
                    modifiedDate: values.contentModificationDate,
                    createdDate: values.creationDate,
                    accessedDate: values.contentAccessDate,
                    category: .largeFiles,
                    inode: FilesystemProbes.inodeIdentity(for: child),
                    linkCount: values.linkCount ?? 1,
                    isCloudDataless: FilesystemProbes.isCloudDataless(values: values),
                    contentTypeIdentifier: values.contentType?.identifier
                )
                candidates.append(item)
                if config.categories.contains(.largeFiles) && size >= config.largeFileThresholdBytes {
                    batchBuffer.append(item)
                }
            }

            let now = Date()
            if batchBuffer.count >= 64 || now.timeIntervalSince(lastFlush) >= 0.08 {
                let progress = ScanProgress(
                    phase: .enumerating,
                    currentPath: currentDir.path,
                    scannedFiles: scannedCount,
                    bytesEvaluated: bytesEvaluated,
                    pendingDirectoriesCount: pending.count,
                    startedAt: initial.startedAt
                )
                emitBatch(batchBuffer, progress: progress, finishStream: false)
                batchBuffer.removeAll(keepingCapacity: true)
                lastFlush = now
                await Task.yield()
            }
        }

        if Task.isCancelled || isCancelRequested {
            let progress = ScanProgress(
                phase: .cancelled,
                currentPath: "",
                scannedFiles: scannedCount,
                bytesEvaluated: bytesEvaluated,
                pendingDirectoriesCount: 0,
                startedAt: initial.startedAt
            )
            emitBatch(batchBuffer, progress: progress, finishStream: true)
            return ScanOutcome(progress: progress, wasCancelled: true)
        }

        if isPauseRequested {
            checkpoint = ScanCheckpoint(
                configuration: config,
                pendingDirectories: [],
                candidateFiles: candidates,
                deadItems: deadItems,
                visitedDirectoryPaths: visited,
                scannedFiles: scannedCount,
                bytesEvaluated: bytesEvaluated,
                startedAt: initial.startedAt
            )
        }

        let outcome = await finalizeCategories(
            config: config,
            candidates: candidates,
            deadItems: deadItems,
            scannedCount: scannedCount,
            bytesEvaluated: bytesEvaluated,
            startedAt: initial.startedAt,
            safetyGuard: safetyGuard
        )
        emitBatch([], progress: outcome.progress, finishStream: true)
        return outcome
    }

    private func finalizeCategories(
        config: ScanConfiguration,
        candidates: [ScannedItem],
        deadItems: [ScannedItem],
        scannedCount: Int,
        bytesEvaluated: UInt64,
        startedAt: Date,
        safetyGuard: SafetyGuard
    ) async -> ScanOutcome {
        var byCategory: [ScanCategory: [ScannedItem]] = [:]
        var duplicateGroups: [DuplicateGroup] = []

        if config.categories.contains(.largeFiles) {
            let large = candidates
                .filter { $0.logicalSize >= config.largeFileThresholdBytes }
                .map { item in
                    ScannedItem(
                        url: item.url,
                        name: item.name,
                        logicalSize: item.logicalSize,
                        allocatedSize: item.allocatedSize,
                        isDirectory: false,
                        modifiedDate: item.modifiedDate,
                        createdDate: item.createdDate,
                        accessedDate: item.accessedDate,
                        category: .largeFiles,
                        inode: item.inode,
                        linkCount: item.linkCount,
                        isCloudDataless: item.isCloudDataless,
                        contentTypeIdentifier: item.contentTypeIdentifier
                    )
                }
                .sorted { $0.logicalSize > $1.logicalSize }
            byCategory[.largeFiles] = large
        }

        if config.categories.contains(.oldFiles) {
            let cutoff = Date().addingTimeInterval(-TimeInterval(config.oldFileThresholdDays) * 86_400)
            let old = candidates.compactMap { item -> ScannedItem? in
                let relevantDate: Date?
                switch config.ageBasis {
                case .lastAccessedOrModified:
                    relevantDate = [item.accessedDate, item.modifiedDate].compactMap { $0 }.max()
                case .lastModifiedOnly:
                    relevantDate = item.modifiedDate
                }
                guard let relevantDate, relevantDate < cutoff else { return nil }
                return ScannedItem(
                    url: item.url,
                    name: item.name,
                    logicalSize: item.logicalSize,
                    allocatedSize: item.allocatedSize,
                    isDirectory: false,
                    modifiedDate: item.modifiedDate,
                    createdDate: item.createdDate,
                    accessedDate: item.accessedDate,
                    category: .oldFiles,
                    inode: item.inode,
                    linkCount: item.linkCount,
                    isCloudDataless: item.isCloudDataless,
                    contentTypeIdentifier: item.contentTypeIdentifier
                )
            }
            .sorted { ($0.modifiedDate ?? .distantFuture) < ($1.modifiedDate ?? .distantFuture) }
            byCategory[.oldFiles] = old
        }

        if config.categories.contains(.deadFiles) {
            var allDead = deadItems
            let downloadsRoot = config.downloadsOverride
                ?? safetyGuard.currentUserHome.appendingPathComponent("Downloads", isDirectory: true)
            let broken = DeadFileScanner.scanBrokenDownloads(
                downloadsRoot: downloadsRoot,
                safetyGuard: safetyGuard,
                excludedFolders: config.excludedFolders
            )
            allDead.append(contentsOf: broken)

            let libraryRoot = config.libraryOverride
                ?? safetyGuard.currentUserHome.appendingPathComponent("Library", isDirectory: true)
            let appRoots = config.appSearchRootsOverride ?? InstalledAppIndex.defaultSearchRoots
            let installedIDs = InstalledAppIndex.installedBundleIDs(in: appRoots)
            let orphans = DeadFileScanner.scanOrphanedAppData(
                libraryRoot: libraryRoot,
                installedBundleIDs: installedIDs,
                safetyGuard: safetyGuard,
                excludedFolders: config.excludedFolders
            )
            allDead.append(contentsOf: orphans)

            var uniqueURLs = Set<URL>()
            byCategory[.deadFiles] = allDead
                .filter { uniqueURLs.insert($0.url).inserted }
                .sorted { $0.logicalSize > $1.logicalSize }
        }

        if config.categories.contains(.duplicates) {
            let progress = ScanProgress(
                phase: .hashingDuplicates,
                currentPath: "Verifying content hashes",
                scannedFiles: scannedCount,
                bytesEvaluated: bytesEvaluated,
                pendingDirectoriesCount: 0,
                startedAt: startedAt
            )
            emitBatch([], progress: progress, finishStream: false)

            let eligible = candidates.filter { $0.logicalSize >= config.minDuplicateBytes }
            duplicateGroups = await findDuplicateGroups(eligible)
            byCategory[.duplicates] = duplicateGroups.flatMap(\.allItems)
        }

        let finalProgress = ScanProgress(
            phase: Task.isCancelled || isCancelRequested ? .cancelled : .completed,
            currentPath: "",
            scannedFiles: scannedCount,
            bytesEvaluated: bytesEvaluated,
            pendingDirectoriesCount: 0,
            startedAt: startedAt
        )

        return ScanOutcome(
            itemsByCategory: byCategory,
            duplicateGroups: duplicateGroups,
            progress: finalProgress,
            wasCancelled: Task.isCancelled || isCancelRequested
        )
    }

    private func findDuplicateGroups(_ files: [ScannedItem]) async -> [DuplicateGroup] {
        let sizeBuckets = Dictionary(grouping: files, by: \.logicalSize).values.filter { $0.count >= 2 }
        var partialBuckets: [String: [ScannedItem]] = [:]

        await withTaskGroup(of: (String, ScannedItem)?.self) { group in
            for bucket in sizeBuckets {
                for item in bucket {
                    group.addTask(priority: .utility) {
                        guard !Task.isCancelled,
                              let digest = StreamingHasher.partialDigest(for: item.url) else {
                            return nil
                        }
                        return ("\(item.logicalSize)-\(digest)", item)
                    }
                }
            }
            for await entry in group {
                guard let (key, item) = entry else { continue }
                partialBuckets[key, default: []].append(item)
            }
        }

        let candidatesForFullHash = partialBuckets.values.filter { $0.count >= 2 }.flatMap { $0 }
        var fullBuckets: [String: [ScannedItem]] = [:]

        await withTaskGroup(of: (String, ScannedItem)?.self) { group in
            for item in candidatesForFullHash {
                group.addTask(priority: .utility) {
                    guard !Task.isCancelled,
                          let digest = await StreamingHasher.fullDigest(for: item.url) else {
                        return nil
                    }
                    let dupItem = ScannedItem(
                        url: item.url,
                        name: item.name,
                        logicalSize: item.logicalSize,
                        allocatedSize: item.allocatedSize,
                        isDirectory: false,
                        modifiedDate: item.modifiedDate,
                        createdDate: item.createdDate,
                        accessedDate: item.accessedDate,
                        category: .duplicates,
                        inode: item.inode,
                        linkCount: item.linkCount,
                        isCloudDataless: item.isCloudDataless,
                        contentTypeIdentifier: item.contentTypeIdentifier
                    )
                    return (digest, dupItem)
                }
            }
            for await entry in group {
                guard let (digest, item) = entry else { continue }
                fullBuckets[digest, default: []].append(item)
            }
        }

        return DuplicateGrouper.buildGroups(from: fullBuckets)
    }

    private func emitBatch(_ items: [ScannedItem], progress: ScanProgress, finishStream: Bool) {
        let shouldEmit = !items.isEmpty
            || progress.phase == .enumerating
            || progress.phase == .hashingDuplicates
            || progress.phase == .paused
            || progress.phase == .completed
            || progress.phase == .cancelled
        if shouldEmit {
            streamPair.continuation.yield(ScanBatch(items: items, progress: progress))
        }
        if finishStream {
            streamPair.continuation.finish()
        }
    }
}
