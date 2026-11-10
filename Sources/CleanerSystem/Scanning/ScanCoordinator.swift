import Foundation
import os
import CleanerCore

private final class ScanRunControl: Sendable {
    private struct Flags: Sendable {
        var pauseRequested = false
        var cancelRequested = false
    }

    let generation: UUID
    private let state = OSAllocatedUnfairLock(initialState: Flags())

    init(generation: UUID) {
        self.generation = generation
    }

    func requestPause() {
        state.withLock { $0.pauseRequested = true }
    }

    func requestCancel() {
        state.withLock { $0.cancelRequested = true }
    }

    var isPaused: Bool {
        state.withLock { $0.pauseRequested }
    }

    var isCancelled: Bool {
        state.withLock { $0.cancelRequested }
    }
}

public actor ScanCoordinator {
    private let safetyGuard: SafetyGuard
    private let perDirectoryDelay: Duration?

    private var activeGeneration = UUID()
    private var activeTask: Task<ScanOutcome, Never>?
    private var activeControl: ScanRunControl?
    private var checkpoint: ScanCheckpoint?
    private var streamPair: (stream: AsyncStream<ScanBatch>, continuation: AsyncStream<ScanBatch>.Continuation) =
        AsyncStream.makeStream(of: ScanBatch.self)

    public init(safetyGuard: SafetyGuard = SafetyGuard(), perDirectoryDelay: Duration? = nil) {
        self.safetyGuard = safetyGuard
        self.perDirectoryDelay = perDirectoryDelay
    }

    public func makeProgressStream() -> AsyncStream<ScanBatch> {
        activeGeneration = UUID()
        activeControl?.requestCancel()
        activeTask?.cancel()
        streamPair.continuation.finish()
        streamPair = AsyncStream.makeStream(of: ScanBatch.self)
        return streamPair.stream
    }

    public func runFullScan(configuration: ScanConfiguration) async -> ScanOutcome {
        guard let task = await prepareAndLaunchStart(configuration: configuration) else {
            return ScanOutcome(progress: ScanProgress(phase: .cancelled), wasCancelled: true)
        }
        return await task.value
    }

    public func start(configuration: ScanConfiguration) async throws {
        _ = await prepareAndLaunchStart(configuration: configuration)
    }

    public func pause() async -> ScanCheckpoint {
        activeControl?.requestPause()
        if let task = activeTask {
            _ = await task.value
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
        guard let task = await prepareAndLaunch(checkpoint: savedCheckpoint) else {
            return ScanOutcome(progress: ScanProgress(phase: .cancelled), wasCancelled: true)
        }
        return await task.value
    }

    public func cancel() async -> ScanOutcome {
        let expectedGeneration = activeGeneration
        let controlToCancel = activeControl
        let taskToCancel = activeTask
        let fallbackProgress = checkpoint.map {
            ScanProgress(
                phase: .cancelled,
                currentPath: "",
                scannedFiles: $0.scannedFiles,
                bytesEvaluated: $0.bytesEvaluated,
                pendingDirectoriesCount: $0.pendingDirectories.count,
                skippedProtectedDirectories: $0.skippedProtectedDirectories,
                startedAt: $0.startedAt
            )
        } ?? ScanProgress(phase: .cancelled)

        controlToCancel?.requestCancel()
        taskToCancel?.cancel()

        if let taskToCancel {
            let outcome = await taskToCancel.value
            if activeGeneration == expectedGeneration {
                activeTask = nil
                activeControl = nil
                checkpoint = nil
                if outcome.progress.phase == .paused {
                    let cancelledProgress = ScanProgress(
                        phase: .cancelled,
                        currentPath: "",
                        scannedFiles: outcome.progress.scannedFiles,
                        bytesEvaluated: outcome.progress.bytesEvaluated,
                        pendingDirectoriesCount: outcome.progress.pendingDirectoriesCount,
                        skippedProtectedDirectories: outcome.progress.skippedProtectedDirectories,
                        startedAt: outcome.progress.startedAt
                    )
                    emitBatch([], progress: cancelledProgress, finishStream: true)
                    return ScanOutcome(progress: cancelledProgress, wasCancelled: true)
                }
            }
            return outcome
        }

        if activeGeneration == expectedGeneration {
            activeTask = nil
            activeControl = nil
            checkpoint = nil
            emitBatch([], progress: fallbackProgress, finishStream: true)
        }
        return ScanOutcome(progress: fallbackProgress, wasCancelled: true)
    }

    private func prepareAndLaunchStart(configuration: ScanConfiguration) async -> Task<ScanOutcome, Never>? {
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
        return await prepareAndLaunch(checkpoint: initial)
    }

    private func prepareAndLaunch(checkpoint initial: ScanCheckpoint) async -> Task<ScanOutcome, Never>? {
        let generation = UUID()
        activeGeneration = generation

        let previousControl = activeControl
        let previousTask = activeTask
        activeControl = nil
        activeTask = nil

        previousControl?.requestCancel()
        previousTask?.cancel()
        if let previousTask {
            _ = await previousTask.value
        }

        guard activeGeneration == generation else { return nil }

        let control = ScanRunControl(generation: generation)
        self.checkpoint = initial
        self.activeControl = control

        let guardPolicy = safetyGuard
        let delay = perDirectoryDelay
        let task = Task.detached(priority: .utility) { [weak self] in
            await Self.executeScanWorker(
                coordinator: self,
                startingFrom: initial,
                safetyGuard: guardPolicy,
                perDirectoryDelay: delay,
                control: control
            )
        }
        self.activeTask = task
        return task
    }

    private nonisolated static func executeScanWorker(
        coordinator: ScanCoordinator?,
        startingFrom initial: ScanCheckpoint,
        safetyGuard: SafetyGuard,
        perDirectoryDelay: Duration?,
        control: ScanRunControl
    ) async -> ScanOutcome {
        var state = FrontierWalkState(from: initial)
        var batchBuffer: [ScannedItem] = []
        var lastFlush = Date()

        while state.hasPendingDirectories {
            if Task.isCancelled || control.isCancelled {
                return await finishCancelled(
                    coordinator: coordinator,
                    generation: control.generation,
                    state: state,
                    buffer: batchBuffer
                )
            }
            if control.isPaused {
                return await finishPaused(
                    coordinator: coordinator,
                    generation: control.generation,
                    state: state,
                    buffer: batchBuffer
                )
            }

            if let perDirectoryDelay {
                try? await Task.sleep(for: perDirectoryDelay)
                if Task.isCancelled || control.isCancelled {
                    return await finishCancelled(
                        coordinator: coordinator,
                        generation: control.generation,
                        state: state,
                        buffer: batchBuffer
                    )
                }
                if control.isPaused {
                    return await finishPaused(
                        coordinator: coordinator,
                        generation: control.generation,
                        state: state,
                        buffer: batchBuffer
                    )
                }
            }

            let currentDir = state.popNextDirectory().standardizedFileURL

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
                    pendingDirectoriesCount: state.remainingPendingCount,
                    skippedProtectedDirectories: state.skippedProtectedDirectories,
                    startedAt: state.startedAt
                )
                await coordinator?.emitBatchIfCurrent(generation: control.generation, items: batchBuffer, progress: progress, finishStream: false)
                batchBuffer.removeAll(keepingCapacity: true)
                lastFlush = now
                await Task.yield()
            }
        }

        if Task.isCancelled || control.isCancelled {
            return await finishCancelled(
                coordinator: coordinator,
                generation: control.generation,
                state: state,
                buffer: batchBuffer
            )
        }
        if control.isPaused {
            return await finishPaused(
                coordinator: coordinator,
                generation: control.generation,
                state: state,
                buffer: batchBuffer
            )
        }

        let outcome = await finalizeOutcome(
            coordinator: coordinator,
            state: state,
            safetyGuard: safetyGuard,
            control: control
        )
        await coordinator?.completeRun(generation: control.generation, outcome: outcome)
        return outcome
    }

    private nonisolated static func finishCancelled(
        coordinator: ScanCoordinator?,
        generation: UUID,
        state: FrontierWalkState,
        buffer: [ScannedItem]
    ) async -> ScanOutcome {
        let progress = ScanProgress(
            phase: .cancelled,
            currentPath: "",
            scannedFiles: state.scannedCount,
            bytesEvaluated: state.bytesEvaluated,
            pendingDirectoriesCount: state.remainingPendingCount,
            skippedProtectedDirectories: state.skippedProtectedDirectories,
            startedAt: state.startedAt
        )
        let outcome = ScanOutcome(progress: progress, wasCancelled: true)
        await coordinator?.completeCancelledRun(generation: generation, buffer: buffer, progress: progress)
        return outcome
    }

    private nonisolated static func finishPaused(
        coordinator: ScanCoordinator?,
        generation: UUID,
        state: FrontierWalkState,
        buffer: [ScannedItem]
    ) async -> ScanOutcome {
        let saved = state.makeCheckpoint()
        let progress = ScanProgress(
            phase: .paused,
            currentPath: state.peekNextDirectory?.path ?? "",
            scannedFiles: state.scannedCount,
            bytesEvaluated: state.bytesEvaluated,
            pendingDirectoriesCount: state.remainingPendingCount,
            skippedProtectedDirectories: state.skippedProtectedDirectories,
            startedAt: state.startedAt
        )
        await coordinator?.recordPausedRun(generation: generation, checkpoint: saved, buffer: buffer, progress: progress)
        return ScanOutcome(progress: progress, wasCancelled: false)
    }

    private nonisolated static func finalizeOutcome(
        coordinator: ScanCoordinator?,
        state: FrontierWalkState,
        safetyGuard: SafetyGuard,
        control: ScanRunControl
    ) async -> ScanOutcome {
        let config = state.configuration
        let libPath = DirectoryFrontierWalker.userLibraryPath(configuration: config, safetyGuard: safetyGuard)
        let explicitLib = DirectoryFrontierWalker.isExplicitLibraryRoot(configuration: config, userLibraryPath: libPath)
        let excludedLibraryPrefix: String? = explicitLib ? nil : libPath

        var byCategory: [ScanCategory: [ScannedItem]] = [:]
        var duplicateGroups: [DuplicateGroup] = []
        var totalEvaluatedBytes = state.bytesEvaluated
        var totalSkippedProtected = state.skippedProtectedDirectories

        if !Task.isCancelled && !control.isCancelled && config.categories.contains(.largeFiles) {
            byCategory[.largeFiles] = CategoryClassifier.largeFiles(
                from: state.candidates,
                thresholdBytes: config.largeFileThresholdBytes
            )
        }
        if !Task.isCancelled && !control.isCancelled && config.categories.contains(.oldFiles) {
            byCategory[.oldFiles] = CategoryClassifier.oldFiles(
                from: state.candidates,
                thresholdDays: config.oldFileThresholdDays,
                basis: config.ageBasis,
                excludedLibraryPrefix: excludedLibraryPrefix
            )
        }
        if !Task.isCancelled && !control.isCancelled && config.categories.contains(.deadFiles) {
            let deadClassification = CategoryClassifier.deadFilesWithDiagnostics(
                emptyDirectories: state.deadItems,
                configuration: config,
                safetyGuard: safetyGuard
            )
            let dead = deadClassification.items
            byCategory[.deadFiles] = dead
            let extraDeadBytes = dead
                .filter { item in
                    guard item.deadKind != .emptyDirectory else { return false }
                    let parentCanonical = SafetyGuard.canonicalizeFirmlink(
                        item.url.deletingLastPathComponent().standardizedFileURL.path(percentEncoded: false)
                    )
                    let itemCanonical = SafetyGuard.canonicalizeFirmlink(
                        item.url.standardizedFileURL.path(percentEncoded: false)
                    )
                    return !state.visited.contains(parentCanonical) && !state.visited.contains(itemCanonical)
                }
                .reduce(0) { $0 &+ $1.reclaimableDiskBytes }
            totalEvaluatedBytes &+= extraDeadBytes
            totalSkippedProtected += deadClassification.skippedProtectedDirectoryPaths.subtracting(state.visited).count
        }
        if !Task.isCancelled && !control.isCancelled && config.categories.contains(.duplicates) {
            let hashProgress = ScanProgress(
                phase: .hashingDuplicates,
                currentPath: "Verifying content hashes",
                scannedFiles: state.scannedCount,
                bytesEvaluated: totalEvaluatedBytes,
                pendingDirectoriesCount: 0,
                skippedProtectedDirectories: totalSkippedProtected,
                startedAt: state.startedAt
            )
            await coordinator?.emitBatchIfCurrent(generation: control.generation, items: [], progress: hashProgress, finishStream: false)
            let eligible = state.candidates.filter { item in
                guard item.logicalSize >= config.minDuplicateBytes else { return false }
                if let excludedLibraryPrefix {
                    let canonical = SafetyGuard.canonicalizeFirmlink(item.url.standardizedFileURL.path(percentEncoded: false))
                    if DirectoryFrontierWalker.isInsideUserLibrary(canonical, userLibraryPath: excludedLibraryPrefix) {
                        return false
                    }
                }
                return true
            }
            duplicateGroups = await DuplicateScanPipeline.findDuplicateGroups(eligible)
            byCategory[.duplicates] = duplicateGroups.flatMap(\.allItems)
        }

        let cancelled = Task.isCancelled || control.isCancelled
        let finalProgress = ScanProgress(
            phase: cancelled ? .cancelled : .completed,
            currentPath: "",
            scannedFiles: state.scannedCount,
            bytesEvaluated: totalEvaluatedBytes,
            pendingDirectoriesCount: 0,
            skippedProtectedDirectories: totalSkippedProtected,
            startedAt: state.startedAt
        )
        return ScanOutcome(
            itemsByCategory: cancelled ? [:] : byCategory,
            duplicateGroups: cancelled ? [] : duplicateGroups,
            progress: finalProgress,
            wasCancelled: cancelled
        )
    }

    private func emitBatchIfCurrent(
        generation: UUID,
        items: [ScannedItem],
        progress: ScanProgress,
        finishStream: Bool
    ) {
        guard generation == activeGeneration else { return }
        emitBatch(items, progress: progress, finishStream: finishStream)
    }

    private func recordPausedRun(
        generation: UUID,
        checkpoint: ScanCheckpoint,
        buffer: [ScannedItem],
        progress: ScanProgress
    ) {
        guard generation == activeGeneration else { return }
        self.checkpoint = checkpoint
        self.activeTask = nil
        self.activeControl = nil
        emitBatch(buffer, progress: progress, finishStream: false)
    }

    private func completeCancelledRun(
        generation: UUID,
        buffer: [ScannedItem],
        progress: ScanProgress
    ) {
        guard generation == activeGeneration else { return }
        self.checkpoint = nil
        self.activeTask = nil
        self.activeControl = nil
        emitBatch(buffer, progress: progress, finishStream: true)
    }

    private func completeRun(generation: UUID, outcome: ScanOutcome) {
        guard generation == activeGeneration else { return }
        self.checkpoint = nil
        self.activeTask = nil
        self.activeControl = nil
        emitBatch([], progress: outcome.progress, finishStream: true)
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
