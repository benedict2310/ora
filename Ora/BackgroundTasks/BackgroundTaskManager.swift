//
//  BackgroundTaskManager.swift
//  Ora
//
//  Persistent task queue and lifecycle manager for background jobs.
//

import Foundation
import SwiftData
import os

struct BackgroundTaskExecutionRequest: Sendable, Equatable {
    let taskID: UUID
    let taskKind: String
    let inputs: BackgroundTaskInputs
    let policy: BackgroundTaskPolicy
    let sessionID: UUID?
}

struct BackgroundTaskExecutionResult: Sendable, Equatable {
    let artifactWorkerResult: BackgroundTaskWorkerResult?
    let persistRawHTML: Bool
    let artifactPath: String?
    let workerResult: WorkerResult?

    init(
        artifactWorkerResult: BackgroundTaskWorkerResult? = nil,
        persistRawHTML: Bool = false,
        artifactPath: String? = nil,
        workerResult: WorkerResult? = nil
    ) {
        self.artifactWorkerResult = artifactWorkerResult
        self.persistRawHTML = persistRawHTML
        self.artifactPath = artifactPath
        self.workerResult = workerResult
    }
}

struct BackgroundTaskObservation: Sendable {
    let initialSnapshots: [BackgroundTaskRecordSnapshot]
    let stream: AsyncStream<BackgroundTaskEvent>
}

enum BackgroundTaskManagerError: LocalizedError, Equatable, Sendable {
    case emptyURLList
    case queueFull(limit: Int)

    var errorDescription: String? {
        switch self {
        case .emptyURLList:
            return "Background tasks require at least one URL."
        case .queueFull(let limit):
            return "Background task queue is full (limit: \(limit))."
        }
    }
}

private enum BackgroundTaskExecutionFailure: Error, Equatable, Sendable {
    case timedOut(seconds: Int)
    case failed(message: String)
}

@ModelActor
actor BackgroundTaskManager {

    typealias Executor = @Sendable (BackgroundTaskExecutionRequest) async throws -> BackgroundTaskExecutionResult

    // MARK: - Configuration

    static let defaultQueueDepthLimit = 10
    static let defaultConcurrencyLimit = 2
    static let recoveryCancellationReason = "Ora quit before task completed."

    /// Resolve the shared BackgroundTaskManager from PersistenceManager.
    /// Returns nil when called from test harnesses that don't use PersistenceManager.shared.
    @MainActor
    static func resolveShared() -> BackgroundTaskManager? {
        return PersistenceManager.shared.backgroundTaskManager
    }

    // MARK: - Properties

    private let logger = Logger.ora(category: "orchestration")
    private var observers: [UUID: AsyncStream<BackgroundTaskEvent>.Continuation] = [:]
    private var runningTasks: [UUID: Task<Void, Never>] = [:]
    private var nextEventSequenceNumber: UInt64 = 0

    private var worker: any BackgroundWorker = URLSessionWorker()
    private var executorOverride: Executor?
    private var concurrencyLimit: Int = BackgroundTaskManager.defaultConcurrencyLimit
    private var queueDepthLimit: Int = BackgroundTaskManager.defaultQueueDepthLimit
    private var artifactStore: ArtifactStore = .shared
    private var summaryGenerator: SummaryGenerator?
    private var notificationService: (any TaskNotificationPosting)? = TaskNotificationService()

    // MARK: - Configuration

    func configure(
        worker: any BackgroundWorker,
        concurrencyLimit: Int = BackgroundTaskManager.defaultConcurrencyLimit,
        queueDepthLimit: Int = BackgroundTaskManager.defaultQueueDepthLimit,
        artifactStore: ArtifactStore? = nil,
        summaryGenerator: SummaryGenerator? = nil,
        notificationService: (any TaskNotificationPosting)? = TaskNotificationService()
    ) {
        self.worker = worker
        self.executorOverride = nil
        self.concurrencyLimit = max(1, concurrencyLimit)
        self.queueDepthLimit = max(1, queueDepthLimit)
        if let artifactStore {
            self.artifactStore = artifactStore
        }
        self.summaryGenerator = summaryGenerator
        self.notificationService = notificationService
    }

    func configureForTesting(
        executor: @escaping Executor,
        worker: (any BackgroundWorker)? = nil,
        concurrencyLimit: Int = BackgroundTaskManager.defaultConcurrencyLimit,
        queueDepthLimit: Int = BackgroundTaskManager.defaultQueueDepthLimit,
        artifactStore: ArtifactStore? = nil,
        summaryGenerator: SummaryGenerator? = nil,
        notificationService: (any TaskNotificationPosting)? = nil
    ) {
        self.executorOverride = executor
        if let worker {
            self.worker = worker
        }
        self.concurrencyLimit = max(1, concurrencyLimit)
        self.queueDepthLimit = max(1, queueDepthLimit)
        if let artifactStore {
            self.artifactStore = artifactStore
        }
        self.summaryGenerator = summaryGenerator
        self.notificationService = notificationService
    }

    // MARK: - Public API

    func enqueue(
        inputs: BackgroundTaskInputs,
        policy: BackgroundTaskPolicy = BackgroundTaskPolicy(),
        sessionID: UUID? = nil
    ) async throws -> BackgroundTaskRecordSnapshot {
        let normalizedInputs = BackgroundTaskInputs(urls: inputs.urls, label: inputs.label)
        guard !normalizedInputs.urls.isEmpty else {
            throw BackgroundTaskManagerError.emptyURLList
        }

        guard try self.unfinishedTaskCount() < self.queueDepthLimit else {
            throw BackgroundTaskManagerError.queueFull(limit: self.queueDepthLimit)
        }

        let normalizedPolicy = BackgroundTaskPolicy(
            taskKind: policy.taskKind,
            timeoutSeconds: policy.timeoutSeconds
        )
        let record = BackgroundTaskRecord(
            inputs: normalizedInputs,
            policy: normalizedPolicy,
            sessionID: sessionID
        )
        self.modelContext.insert(record)
        try self.saveContext()

        let snapshot = try record.snapshot()
        self.emitEvent(for: snapshot, from: nil, at: snapshot.createdAt)
        await self.scheduleWorkIfNeeded()
        return snapshot
    }

    @discardableResult
    func cancel(taskID: UUID) async -> BackgroundTaskRecordSnapshot? {
        guard let record = try? self.fetchRecord(id: taskID) else {
            return nil
        }

        let currentState = record.state
        guard currentState == .queued || currentState == .running else {
            return try? record.snapshot()
        }

        let completedAt = Date()
        let previousState = currentState
        record.state = .canceled
        record.errorMessage = "Task canceled."
        record.completedAt = completedAt
        record.artifactPath = nil

        do {
            try self.saveContext()
            let snapshot = try record.snapshot()
            self.emitEvent(for: snapshot, from: previousState, at: completedAt)

            if let task = self.runningTasks[taskID] {
                // Don't remove from runningTasks yet — the task stays counted
                // until its executor actually exits via finishCancellation,
                // preventing the concurrency limit from being exceeded.
                task.cancel()
            } else {
                // Queued task (not running), safe to schedule immediately.
                await self.scheduleWorkIfNeeded()
            }
            return snapshot
        } catch {
            self.logger.error("Failed to cancel background task \(taskID): \(error.localizedDescription)")
            self.runningTasks[taskID]?.cancel()
            return nil
        }
    }

    func cancelAll() async {
        let activeRecords: [BackgroundTaskRecord]
        do {
            activeRecords = try self.fetchActiveRecords()
        } catch {
            self.logger.error("Failed to fetch active background tasks for cancellation: \(error.localizedDescription)")
            return
        }

        guard !activeRecords.isEmpty else {
            return
        }

        let canceledAt = Date()
        let runningHandles = self.runningTasks
        self.runningTasks.removeAll()

        var events: [(BackgroundTaskRecordSnapshot, BackgroundTaskState, Date)] = []
        for record in activeRecords {
            let previousState = record.state
            guard previousState == .queued || previousState == .running else {
                continue
            }

            record.state = .canceled
            record.errorMessage = "Task canceled."
            record.completedAt = canceledAt
            record.artifactPath = nil

            if let snapshot = try? record.snapshot() {
                events.append((snapshot, previousState, canceledAt))
            }
        }

        do {
            try self.saveContext()
        } catch {
            self.logger.error("Failed to cancel all background tasks: \(error.localizedDescription)")
        }

        for handle in runningHandles.values {
            handle.cancel()
        }

        for (snapshot, previousState, timestamp) in events {
            self.emitEvent(for: snapshot, from: previousState, at: timestamp)
        }
    }

    func task(id: UUID) async -> BackgroundTaskRecordSnapshot? {
        guard let record = try? self.fetchRecord(id: id) else {
            return nil
        }
        return try? record.snapshot()
    }

    func list(limit: Int = 50) async -> [BackgroundTaskRecordSnapshot] {
        return self.fetchSnapshots(limit: limit)
    }

    func observeWithSnapshot(limit: Int = 50) -> BackgroundTaskObservation {
        let observerID = UUID()
        let initialSnapshots = self.fetchSnapshots(limit: limit)
        let stream = self.makeObserverStream(observerID: observerID)

        return BackgroundTaskObservation(
            initialSnapshots: initialSnapshots,
            stream: stream
        )
    }

    func observe() -> AsyncStream<BackgroundTaskEvent> {
        let observerID = UUID()
        return self.makeObserverStream(observerID: observerID)
    }

    private func fetchSnapshots(limit: Int) -> [BackgroundTaskRecordSnapshot] {
        let clampedLimit = max(1, limit)
        var descriptor = FetchDescriptor<BackgroundTaskRecord>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        descriptor.fetchLimit = clampedLimit

        do {
            return try self.modelContext.fetch(descriptor).compactMap { try? $0.snapshot() }
        } catch {
            self.logger.error("Failed to list background tasks: \(error.localizedDescription)")
            return []
        }
    }

    private func makeObserverStream(observerID: UUID) -> AsyncStream<BackgroundTaskEvent> {
        return AsyncStream { continuation in
            self.observers[observerID] = continuation
            continuation.onTermination = { @Sendable [weak self] _ in
                guard let self else {
                    return
                }
                Task {
                    await self.removeObserver(id: observerID)
                }
            }
        }
    }

    func recoverUnfinishedTasksOnLaunch() async {
        let staleRecords: [BackgroundTaskRecord]
        do {
            staleRecords = try self.fetchActiveRecords()
        } catch {
            self.logger.error("Failed to recover unfinished background tasks: \(error.localizedDescription)")
            return
        }

        guard !staleRecords.isEmpty else {
            return
        }

        let recoveredAt = Date()
        var events: [(BackgroundTaskRecordSnapshot, BackgroundTaskState, Date)] = []

        for record in staleRecords {
            let previousState = record.state
            guard previousState == .queued || previousState == .running else {
                continue
            }

            record.state = .canceled
            record.errorMessage = Self.recoveryCancellationReason
            record.completedAt = recoveredAt
            record.artifactPath = nil

            if let snapshot = try? record.snapshot() {
                events.append((snapshot, previousState, recoveredAt))
            }
        }

        do {
            try self.saveContext()
        } catch {
            self.logger.error("Failed to persist recovered background tasks: \(error.localizedDescription)")
        }

        for (snapshot, previousState, timestamp) in events {
            self.emitEvent(for: snapshot, from: previousState, at: timestamp)
        }
    }

    // MARK: - Scheduling

    private func scheduleWorkIfNeeded() async {
        while self.runningTasks.count < self.concurrencyLimit {
            let record: BackgroundTaskRecord
            do {
                guard let nextRecord = try self.fetchNextQueuedRecord() else {
                    return
                }
                record = nextRecord
            } catch {
                self.logger.error("Failed to fetch next queued background task: \(error.localizedDescription)")
                return
            }

            let startedAt = Date()
            record.state = .running
            record.startedAt = startedAt
            record.completedAt = nil
            record.errorMessage = nil

            do {
                try self.saveContext()
                let snapshot = try record.snapshot()
                self.emitEvent(for: snapshot, from: .queued, at: startedAt)
                self.startExecution(for: snapshot)
            } catch {
                self.logger.error("Failed to start background task \(record.id): \(error.localizedDescription)")
                return
            }
        }
    }

    private func startExecution(for snapshot: BackgroundTaskRecordSnapshot) {
        let request = BackgroundTaskExecutionRequest(
            taskID: snapshot.id,
            taskKind: snapshot.taskKind,
            inputs: snapshot.inputs,
            policy: snapshot.policy,
            sessionID: snapshot.sessionID
        )

        let handle = Task { [weak self] in
            guard let self else {
                return
            }

            let outcome: Result<BackgroundTaskExecutionResult, BackgroundTaskExecutionFailure>
            do {
                let executorResult = try await Self.runWithTimeout(timeoutSeconds: snapshot.policy.timeoutSeconds) {
                    return try await self.executeRequest(request: request)
                }
                let persistedResult = try await self.persistArtifactsIfNeeded(
                    for: snapshot,
                    executionResult: executorResult
                )
                outcome = .success(persistedResult)
            } catch is CancellationError {
                await self.finishCancellation(taskID: snapshot.id)
                return
            } catch let error as BackgroundTaskExecutionFailure {
                outcome = .failure(error)
            } catch {
                outcome = .failure(.failed(message: error.localizedDescription))
            }

            await self.finishExecution(taskID: snapshot.id, outcome: outcome)
        }

        self.runningTasks[snapshot.id] = handle
    }

    private func persistArtifactsIfNeeded(
        for task: BackgroundTaskRecordSnapshot,
        executionResult: BackgroundTaskExecutionResult
    ) async throws -> BackgroundTaskExecutionResult {
        let artifactWorkerResult: BackgroundTaskWorkerResult
        if let storedResult = executionResult.artifactWorkerResult {
            artifactWorkerResult = storedResult
        } else if let workerResult = executionResult.workerResult {
            artifactWorkerResult = Self.makeArtifactWorkerResult(from: workerResult, task: task)
        } else {
            return executionResult
        }

        let manifest = try await self.artifactStore.save(
            task: task,
            workerResult: artifactWorkerResult,
            persistRawHTML: executionResult.persistRawHTML
        )
        return BackgroundTaskExecutionResult(
            artifactWorkerResult: artifactWorkerResult,
            persistRawHTML: executionResult.persistRawHTML,
            artifactPath: manifest.artifactPath,
            workerResult: executionResult.workerResult
        )
    }

    private static func makeArtifactWorkerResult(
        from workerResult: WorkerResult,
        task: BackgroundTaskRecordSnapshot
    ) -> BackgroundTaskWorkerResult {
        let pages = workerResult.pages.enumerated().map { index, page in
            BackgroundTaskArtifactPage(
                pageNumber: index + 1,
                url: page.finalURL,
                title: page.title,
                extractedText: page.text,
                rawHTML: page.rawHTML
            )
        }
        let citations = workerResult.pages.map { page in
            BackgroundTaskArtifactCitation(
                url: page.finalURL,
                title: page.title,
                snippet: Self.citationSnippet(for: page.text)
            )
        }

        let title = Self.defaultArtifactTitle(task: task, pages: workerResult.pages)
        let summary = Self.defaultArtifactSummary(pages: workerResult.pages)
        let markdown = Self.defaultArtifactMarkdown(title: title, pages: workerResult.pages)

        return BackgroundTaskWorkerResult(
            title: title,
            summary: summary,
            markdown: markdown,
            pages: pages,
            citations: citations
        )
    }

    private static func defaultArtifactTitle(
        task: BackgroundTaskRecordSnapshot,
        pages: [PageResult]
    ) -> String {
        if let label = task.inputs.label?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty {
            return label
        }
        if let pageTitle = pages.lazy.compactMap(\.title).first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            return pageTitle
        }
        if let firstURL = task.inputs.urls.first, let host = URL(string: firstURL)?.host, !host.isEmpty {
            return "Research: \(host)"
        }
        return "Research Result"
    }

    private static func defaultArtifactSummary(pages: [PageResult]) -> String {
        let snippets = pages.prefix(3).compactMap { page -> String? in
            let snippet = Self.citationSnippet(for: page.text, maxLength: 220)
            guard !snippet.isEmpty else {
                return nil
            }
            if let title = page.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
                return "\(title): \(snippet)"
            }
            return snippet
        }

        if snippets.isEmpty {
            return "Research completed successfully."
        }
        return snippets.joined(separator: "\n")
    }

    private static func defaultArtifactMarkdown(
        title: String,
        pages: [PageResult]
    ) -> String {
        var markdown = "# \(title)\n\n"
        let bullets = pages.prefix(5).compactMap { page -> String? in
            let snippet = Self.citationSnippet(for: page.text, maxLength: 180)
            guard !snippet.isEmpty else {
                return nil
            }
            let trimmedTitle = page.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let bulletTitle = trimmedTitle.isEmpty ? page.finalURL : trimmedTitle
            return "- \(bulletTitle): \(snippet)"
        }

        if bullets.isEmpty {
            markdown += "Research completed successfully."
        } else {
            markdown += bullets.joined(separator: "\n")
        }

        return markdown
    }

    private static func citationSnippet(for text: String, maxLength: Int = 280) -> String {
        let collapsed = text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard collapsed.count > maxLength else {
            return collapsed
        }
        return String(collapsed.prefix(maxLength - 1)) + "\u{2026}"
    }

    private func finishExecution(
        taskID: UUID,
        outcome: Result<BackgroundTaskExecutionResult, BackgroundTaskExecutionFailure>
    ) async {
        self.runningTasks.removeValue(forKey: taskID)

        guard let record = try? self.fetchRecord(id: taskID) else {
            await self.scheduleWorkIfNeeded()
            return
        }

        guard record.state == .running else {
            await self.scheduleWorkIfNeeded()
            return
        }

        let completedAt = Date()
        let previousState = record.state

        switch outcome {
        case .success(let result):
            record.state = .completed
            record.artifactPath = result.artifactPath
            record.errorMessage = nil
            record.completedAt = completedAt
            // Mark summary as pending only when a generator is available
            if result.artifactPath != nil, self.summaryGenerator != nil {
                record.summaryState = .pending
            }

        case .failure(.timedOut(let seconds)):
            record.state = .failed
            record.artifactPath = nil
            record.errorMessage = "Task timed out after \(seconds) seconds."
            record.completedAt = completedAt

        case .failure(.failed(let message)):
            record.state = .failed
            record.artifactPath = nil
            record.errorMessage = message
            record.completedAt = completedAt
        }

        do {
            try self.saveContext()
            let snapshot = try record.snapshot()
            self.emitEvent(for: snapshot, from: previousState, at: completedAt)

            // Enqueue summary generation for successfully completed tasks with artifacts
            if case .success(let result) = outcome, result.artifactPath != nil {
                if let summaryGenerator = self.summaryGenerator {
                    await summaryGenerator.enqueueSummary(taskID: taskID)
                }
            }

            // Post local notification for terminal states (fire-and-forget to avoid blocking scheduling)
            if let notificationService = self.notificationService {
                let label = snapshot.inputs.label ?? "Research task"
                switch outcome {
                case .success(let result):
                    let artifactPath = result.artifactPath
                    Task {
                        await notificationService.postCompletion(
                            taskID: taskID,
                            title: label,
                            summaryPreview: nil,
                            artifactPath: artifactPath
                        )
                    }
                case .failure(let failure):
                    let errorText: String
                    switch failure {
                    case .timedOut(let seconds):
                        errorText = "Task timed out after \(seconds) seconds."
                    case .failed(let message):
                        errorText = message
                    }
                    Task {
                        await notificationService.postFailure(
                            taskID: taskID,
                            title: label,
                            errorDescription: errorText
                        )
                    }
                }
            }
        } catch {
            self.logger.error("Failed to finish background task \(taskID): \(error.localizedDescription)")
        }

        await self.scheduleWorkIfNeeded()
    }

    private func finishCancellation(taskID: UUID) async {
        self.runningTasks.removeValue(forKey: taskID)
        await self.scheduleWorkIfNeeded()
    }

    private static func runWithTimeout(
        timeoutSeconds: Int,
        execute: @escaping @Sendable () async throws -> BackgroundTaskExecutionResult
    ) async throws -> BackgroundTaskExecutionResult {
        return try await withThrowingTaskGroup(of: BackgroundTaskExecutionResult.self) { group in
            group.addTask {
                return try await execute()
            }

            group.addTask {
                try await Task.sleep(for: .seconds(timeoutSeconds))
                throw BackgroundTaskExecutionFailure.timedOut(seconds: timeoutSeconds)
            }

            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    private func executeRequest(
        request: BackgroundTaskExecutionRequest
    ) async throws -> BackgroundTaskExecutionResult {
        if let executorOverride = self.executorOverride {
            return try await executorOverride(request)
        }

        let workerResult = try await self.worker.execute(
            taskID: request.taskID,
            input: request.inputs,
            policy: request.policy
        )
        return BackgroundTaskExecutionResult(workerResult: workerResult)
    }

    // MARK: - Summary State

    func updateSummaryState(taskID: UUID, state: BackgroundTaskSummaryState) {
        guard let record = try? self.fetchRecord(id: taskID) else {
            self.logger.warning("Cannot update summary state: task \(taskID) not found")
            return
        }
        guard record.summaryState != state else {
            return
        }

        let previousState = record.state
        let timestamp = Date()
        record.summaryState = state
        do {
            try self.saveContext()
            if let snapshot = try? record.snapshot() {
                self.emitEvent(for: snapshot, from: previousState, at: timestamp)
            }
        } catch {
            self.logger.error("Failed to persist summary state for task \(taskID): \(error.localizedDescription)")
        }
    }

    // MARK: - Persistence

    private func unfinishedTaskCount() throws -> Int {
        let descriptor = FetchDescriptor<BackgroundTaskRecord>()
        return try self.modelContext.fetch(descriptor)
            .filter { $0.state == .queued || $0.state == .running }
            .count
    }

    private func fetchActiveRecords() throws -> [BackgroundTaskRecord] {
        let descriptor = FetchDescriptor<BackgroundTaskRecord>(
            sortBy: [SortDescriptor(\.createdAt, order: .forward)]
        )
        return try self.modelContext.fetch(descriptor)
            .filter { $0.state == .queued || $0.state == .running }
    }

    private func fetchNextQueuedRecord() throws -> BackgroundTaskRecord? {
        let descriptor = FetchDescriptor<BackgroundTaskRecord>(
            predicate: #Predicate { $0.stateRawValue == "queued" },
            sortBy: [SortDescriptor(\.createdAt, order: .forward)]
        )
        return try self.modelContext.fetch(descriptor).first
    }

    private func fetchRecord(id: UUID) throws -> BackgroundTaskRecord? {
        let descriptor = FetchDescriptor<BackgroundTaskRecord>(
            predicate: #Predicate { $0.id == id }
        )
        return try self.modelContext.fetch(descriptor).first
    }

    private func saveContext() throws {
        guard self.modelContext.hasChanges else {
            return
        }

        try self.modelContext.save()
    }

    // MARK: - Observers

    private func emitEvent(
        for snapshot: BackgroundTaskRecordSnapshot,
        from previousState: BackgroundTaskState?,
        at timestamp: Date
    ) {
        self.nextEventSequenceNumber &+= 1
        let event = BackgroundTaskEvent(
            sequenceNumber: self.nextEventSequenceNumber,
            taskID: snapshot.id,
            timestamp: timestamp,
            fromState: previousState,
            toState: snapshot.state,
            record: snapshot
        )

        for continuation in self.observers.values {
            continuation.yield(event)
        }
    }

    private func removeObserver(id: UUID) {
        self.observers.removeValue(forKey: id)
    }
}
