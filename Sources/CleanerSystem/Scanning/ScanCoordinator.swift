import Foundation
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

        let initial = ScanCheckpoint(
            configuration: configuration,
            pendingDirectories: configuration.roots.map(\.standardizedFileURL),
            candidateFiles: [],
            deadItems: [],
            visitedDirectoryPaths: [],
            scannedFiles: 0,
            bytesEvaluated: 0,
            startedAt: Date()
        )
        checkpoint = initial
        launchWorker(from: initial)
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
        var state = FrontierWalkState(from: initial)
        var batchBuffer: [ScannedItem] = []
        var lastFlush = Date()

        while !state.pending.isEmpty {
            if Task.isCancelled || isCancelRequested {
                return cancelOutcome(state: state, buffer: batchBuffer)
            }
            if isPauseRequested {
                return pauseOutcome(state: state, buffer: batchBuffer)
            }

            let currentDir = state.pending.removeFirst().standardizedFileURL
            if let perDirectoryDelay {
                try? await Task.sleep(for: perDirectoryDelay)
            }
            let canonicalDir = SafetyGuard.canonicalizeFirmlink(currentDir.path(percentEncoded: false))
            guard state.visited.insert(canonicalDir).inserted,
                  safetyGuard.isScanDirectoryAllowed(currentDir, excludedFolders: state.configuration.excludedFolders) else {
                continue
            }

            DirectoryFrontierWalker.inspectDirectory(
                currentDir,
                state: &state,
                safetyGuard: safetyGuard,
                batchBuffer: &batchBuffer
            )

            let now = Date()
            if batchBuffer.count >= 64 || now.timeIntervalSince(lastFlush) >= 0.08 {
                let progress = ScanProgress(
                    phase: .enumerating,
                    currentPath: currentDir.path,
                    scannedFiles: state.scannedCount,
                    bytesEvaluated: state.bytesEvaluated,
                    pendingDirectoriesCount: state.pending.count,
                    startedAt: state.startedAt
                )
                emitBatch(batchBuffer, progress: progress, finishStream: false)
                batchBuffer.removeAll(keepingCapacity: true)
                lastFlush = now
                await Task.yield()
            }
        }

        if Task.isCancelled || isCancelRequested {
            return cancelOutcome(state: state, buffer: batchBuffer)
        }

        let outcome = await finalizeOutcome(state: state, safetyGuard: safetyGuard)
        emitBatch([], progress: outcome.progress, finishStream: true)
        return outcome
    }

    private func cancelOutcome(state: FrontierWalkState, buffer: [ScannedItem]) -> ScanOutcome {
        let progress = ScanProgress(
            phase: .cancelled,
            currentPath: "",
            scannedFiles: state.scannedCount,
            bytesEvaluated: state.bytesEvaluated,
            pendingDirectoriesCount: state.pending.count,
            startedAt: state.startedAt
        )
        emitBatch(buffer, progress: progress, finishStream: true)
        return ScanOutcome(progress: progress, wasCancelled: true)
    }

    private func pauseOutcome(state: FrontierWalkState, buffer: [ScannedItem]) -> ScanOutcome {
        checkpoint = state.makeCheckpoint()
        let progress = ScanProgress(
            phase: .paused,
            currentPath: state.pending.first?.path ?? "",
            scannedFiles: state.scannedCount,
            bytesEvaluated: state.bytesEvaluated,
            pendingDirectoriesCount: state.pending.count,
            startedAt: state.startedAt
        )
        emitBatch(buffer, progress: progress, finishStream: false)
        return ScanOutcome(progress: progress, wasCancelled: false)
    }

    private func finalizeOutcome(state: FrontierWalkState, safetyGuard: SafetyGuard) async -> ScanOutcome {
        let config = state.configuration
        var byCategory: [ScanCategory: [ScannedItem]] = [:]
        var duplicateGroups: [DuplicateGroup] = []

        if config.categories.contains(.largeFiles) {
            byCategory[.largeFiles] = CategoryClassifier.largeFiles(
                from: state.candidates,
                thresholdBytes: config.largeFileThresholdBytes
            )
        }
        if config.categories.contains(.oldFiles) {
            byCategory[.oldFiles] = CategoryClassifier.oldFiles(
                from: state.candidates,
                thresholdDays: config.oldFileThresholdDays,
                basis: config.ageBasis
            )
        }
        if config.categories.contains(.deadFiles) {
            byCategory[.deadFiles] = CategoryClassifier.deadFiles(
                emptyDirectories: state.deadItems,
                configuration: config,
                safetyGuard: safetyGuard
            )
        }
        if config.categories.contains(.duplicates) {
            let hashProgress = ScanProgress(
                phase: .hashingDuplicates,
                currentPath: "Verifying content hashes",
                scannedFiles: state.scannedCount,
                bytesEvaluated: state.bytesEvaluated,
                pendingDirectoriesCount: 0,
                startedAt: state.startedAt
            )
            emitBatch([], progress: hashProgress, finishStream: false)
            let eligible = state.candidates.filter { $0.logicalSize >= config.minDuplicateBytes }
            duplicateGroups = await DuplicateScanPipeline.findDuplicateGroups(eligible)
            byCategory[.duplicates] = duplicateGroups.flatMap(\.allItems)
        }

        let cancelled = Task.isCancelled || isCancelRequested
        let finalProgress = ScanProgress(
            phase: cancelled ? .cancelled : .completed,
            currentPath: "",
            scannedFiles: state.scannedCount,
            bytesEvaluated: state.bytesEvaluated,
            pendingDirectoriesCount: 0,
            startedAt: state.startedAt
        )
        return ScanOutcome(
            itemsByCategory: byCategory,
            duplicateGroups: duplicateGroups,
            progress: finalProgress,
            wasCancelled: cancelled
        )
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
