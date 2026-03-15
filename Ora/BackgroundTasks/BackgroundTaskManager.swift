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
    let artifactPath: String?

    init(artifactPath: String? = nil) {
        self.artifactPath = artifactPath
    }
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

    // MARK: - Properties

    private let logger = Logger.ora(category: "orchestration")
    private var observers: [UUID: AsyncStream<BackgroundTaskEvent>.Continuation] = [:]
    private var runningTasks: [UUID: Task<Void, Never>] = [:]
    private var nextEventSequenceNumber: UInt64 = 0

    private var executor: Executor = BackgroundTaskManager.defaultExecutor
    private var concurrencyLimit: Int = BackgroundTaskManager.defaultConcurrencyLimit
    private var queueDepthLimit: Int = BackgroundTaskManager.defaultQueueDepthLimit

    // MARK: - Configuration

    func configureForTesting(
        executor: @escaping Executor,
        concurrencyLimit: Int = BackgroundTaskManager.defaultConcurrencyLimit,
        queueDepthLimit: Int = BackgroundTaskManager.defaultQueueDepthLimit
    ) {
        self.executor = executor
        self.concurrencyLimit = max(1, concurrencyLimit)
        self.queueDepthLimit = max(1, queueDepthLimit)
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

        let task = self.runningTasks.removeValue(forKey: taskID)
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
            task?.cancel()
            await self.scheduleWorkIfNeeded()
            return snapshot
        } catch {
            self.logger.error("Failed to cancel background task \(taskID): \(error.localizedDescription)")
            task?.cancel()
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

    func observe() -> AsyncStream<BackgroundTaskEvent> {
        let observerID = UUID()
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
        let executor = self.executor
        let request = BackgroundTaskExecutionRequest(
            taskID: snapshot.id,
            taskKind: snapshot.taskKind,
            inputs: snapshot.inputs,
            policy: snapshot.policy,
            sessionID: snapshot.sessionID
        )

        let handle = Task { [weak self] in
            let outcome: Result<BackgroundTaskExecutionResult, BackgroundTaskExecutionFailure>
            do {
                let result = try await Self.runWithTimeout(
                    request: request,
                    timeoutSeconds: snapshot.policy.timeoutSeconds,
                    executor: executor
                )
                outcome = .success(result)
            } catch is CancellationError {
                guard let self else {
                    return
                }
                await self.finishCancellation(taskID: snapshot.id)
                return
            } catch let error as BackgroundTaskExecutionFailure {
                outcome = .failure(error)
            } catch {
                outcome = .failure(.failed(message: error.localizedDescription))
            }

            guard let self else {
                return
            }
            await self.finishExecution(taskID: snapshot.id, outcome: outcome)
        }

        self.runningTasks[snapshot.id] = handle
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
        request: BackgroundTaskExecutionRequest,
        timeoutSeconds: Int,
        executor: @escaping Executor
    ) async throws -> BackgroundTaskExecutionResult {
        return try await withThrowingTaskGroup(of: BackgroundTaskExecutionResult.self) { group in
            group.addTask {
                return try await executor(request)
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

    private static func defaultExecutor(
        request: BackgroundTaskExecutionRequest
    ) async throws -> BackgroundTaskExecutionResult {
        _ = request
        return BackgroundTaskExecutionResult()
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
