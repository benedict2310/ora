//
//  BackgroundTaskManagerTests.swift
//  OraTests
//
//  Tests for the persistent background task queue lifecycle manager.
//

import XCTest
@testable import Ora

@MainActor
final class BackgroundTaskManagerTests: XCTestCase {

    func test_enqueue_createsQueuedRecord() async throws {
        let controller = BlockingExecutorController()
        let manager = await self.makeInMemoryManager(
            executor: { request in
                return try await controller.execute(request: request)
            }
        )

        let snapshot = try await manager.enqueue(
            inputs: BackgroundTaskInputs(urls: ["https://example.com"], label: "Example"),
            policy: BackgroundTaskPolicy()
        )

        XCTAssertEqual(snapshot.state, .queued)
        let stored = await manager.task(id: snapshot.id)
        XCTAssertEqual(stored?.id, snapshot.id)

        await manager.cancelAll()
        let cleaned = await self.waitUntil { await controller.currentRunningCount() == 0 }
        XCTAssertTrue(cleaned)
    }

    func test_enqueue_rejectsEmptyURLList() async throws {
        let manager = await self.makeInMemoryManager()

        await self.assertThrowsError(
            operation: {
                try await manager.enqueue(inputs: BackgroundTaskInputs(urls: [], label: nil))
            },
            errorHandler: { error in
            XCTAssertEqual(error as? BackgroundTaskManagerError, .emptyInput)
            }
        )
    }

    func test_enqueue_rejectsWhenQueueIsFull() async throws {
        let controller = BlockingExecutorController()
        let manager = await self.makeInMemoryManager(
            executor: { request in
                return try await controller.execute(request: request)
            },
            concurrencyLimit: 1,
            queueDepthLimit: 2
        )

        _ = try await manager.enqueue(inputs: BackgroundTaskInputs(urls: ["https://example.com/1"]))
        _ = try await manager.enqueue(inputs: BackgroundTaskInputs(urls: ["https://example.com/2"]))

        await self.assertThrowsError(
            operation: {
                try await manager.enqueue(inputs: BackgroundTaskInputs(urls: ["https://example.com/3"]))
            },
            errorHandler: { error in
            XCTAssertEqual(error as? BackgroundTaskManagerError, .queueFull(limit: 2))
            }
        )

        await manager.cancelAll()
        let cleaned = await self.waitUntil { await controller.currentRunningCount() == 0 }
        XCTAssertTrue(cleaned)
    }

    func test_runningCount_neverExceedsConcurrencyLimit() async throws {
        let tracker = DelayedExecutorTracker(delay: .milliseconds(120))
        let manager = await self.makeInMemoryManager(
            executor: { request in
                return try await tracker.execute(request: request)
            },
            concurrencyLimit: 2
        )

        for index in 0..<5 {
            _ = try await manager.enqueue(
                inputs: BackgroundTaskInputs(urls: ["https://example.com/\(index)"])
            )
        }

        let allCompleted = await self.waitUntil(timeout: .seconds(3)) {
            let tasks = await manager.list(limit: 10)
            return tasks.filter { $0.state == .completed }.count == 5
        }
        XCTAssertTrue(allCompleted)
        let maxObserved = await tracker.maxRunningObserved()
        XCTAssertLessThanOrEqual(maxObserved, 2)
    }

    func test_timeout_movesTaskToFailed() async throws {
        let manager = await self.makeInMemoryManager(
            executor: { _ in
                try await Task.sleep(for: .seconds(5))
                return BackgroundTaskExecutionResult()
            }
        )

        let snapshot = try await manager.enqueue(
            inputs: BackgroundTaskInputs(urls: ["https://example.com/slow"]),
            policy: BackgroundTaskPolicy(timeoutSeconds: 1)
        )

        let didFail = await self.waitUntil(timeout: .seconds(3)) {
            let task = await manager.task(id: snapshot.id)
            return task?.state == .failed
        }
        XCTAssertTrue(didFail)

        let task = await manager.task(id: snapshot.id)
        XCTAssertEqual(task?.state, .failed)
        XCTAssertEqual(task?.errorMessage, "Task timed out after 1 seconds.")
    }

    func test_cancelQueuedTask_movesToCanceled() async throws {
        let controller = BlockingExecutorController()
        let manager = await self.makeInMemoryManager(
            executor: { request in
                return try await controller.execute(request: request)
            },
            concurrencyLimit: 1
        )

        let first = try await manager.enqueue(inputs: BackgroundTaskInputs(urls: ["https://example.com/1"]))
        let second = try await manager.enqueue(inputs: BackgroundTaskInputs(urls: ["https://example.com/2"]))

        let statesReady = await self.waitUntil {
            let running = await manager.task(id: first.id)
            let queued = await manager.task(id: second.id)
            return running?.state == .running && queued?.state == .queued
        }
        XCTAssertTrue(statesReady)

        _ = await manager.cancel(taskID: second.id)

        let canceled = await manager.task(id: second.id)
        XCTAssertEqual(canceled?.state, .canceled)

        await manager.cancelAll()
        let cleaned = await self.waitUntil { await controller.currentRunningCount() == 0 }
        XCTAssertTrue(cleaned)
    }

    func test_cancelRunningTask_movesToCanceled() async throws {
        let controller = BlockingExecutorController()
        let manager = await self.makeInMemoryManager(
            executor: { request in
                return try await controller.execute(request: request)
            },
            concurrencyLimit: 1
        )

        let snapshot = try await manager.enqueue(inputs: BackgroundTaskInputs(urls: ["https://example.com/running"]))

        let isRunning = await self.waitUntil {
            let task = await manager.task(id: snapshot.id)
            return task?.state == .running
        }
        XCTAssertTrue(isRunning)

        _ = await manager.cancel(taskID: snapshot.id)

        let canceled = await manager.task(id: snapshot.id)
        XCTAssertEqual(canceled?.state, .canceled)
        let cleaned = await self.waitUntil { await controller.currentRunningCount() == 0 }
        XCTAssertTrue(cleaned)
    }

    func test_observe_emitsLifecycleEventsInOrder() async throws {
        let manager = await self.makeInMemoryManager()
        let collector = EventCollector()
        let stream = await manager.observe()
        let collectionTask = Task {
            for await event in stream {
                await collector.record(event)
                if await collector.count() == 3 {
                    break
                }
            }
        }

        let snapshot = try await manager.enqueue(inputs: BackgroundTaskInputs(urls: ["https://example.com/observe"]))

        let collected = await self.waitUntil {
            await collector.count() == 3
        }
        XCTAssertTrue(collected)

        collectionTask.cancel()

        let events = await collector.events()
        XCTAssertEqual(events.map(\.toState), [.queued, .running, .completed])
        XCTAssertEqual(Set(events.map(\.taskID)), Set([snapshot.id]))
        XCTAssertEqual(events.map(\.sequenceNumber), [1, 2, 3])
    }

    func test_observeWithSnapshot_returnsInitialStateAndFutureEvents() async throws {
        let controller = BlockingExecutorController()
        let manager = await self.makeInMemoryManager(
            executor: { request in
                return try await controller.execute(request: request)
            },
            concurrencyLimit: 1
        )

        let snapshot = try await manager.enqueue(
            inputs: BackgroundTaskInputs(urls: ["https://example.com/observe-with-snapshot"])
        )

        let observation = await manager.observeWithSnapshot(limit: 50)
        XCTAssertEqual(observation.initialSnapshots.map(\.id), [snapshot.id])

        let terminalEventTask = Task<BackgroundTaskRecordSnapshot?, Never> {
            for await event in observation.stream {
                if event.record.id == snapshot.id, event.toState == .canceled {
                    return event.record
                }
            }
            return nil
        }

        _ = await manager.cancel(taskID: snapshot.id)
        let terminalRecord = await terminalEventTask.value

        XCTAssertEqual(terminalRecord?.state, .canceled)
        XCTAssertEqual(terminalRecord?.id, snapshot.id)
        let cleaned = await self.waitUntil { await controller.currentRunningCount() == 0 }
        XCTAssertTrue(cleaned)
    }

    func test_configuredWorker_executesThroughManager() async throws {
        let worker = RecordingBackgroundWorker()
        let manager = await self.makeInMemoryManager()
        await manager.configure(worker: worker)

        let snapshot = try await manager.enqueue(
            inputs: BackgroundTaskInputs(urls: ["https://example.com/worker"]),
            policy: BackgroundTaskPolicy()
        )

        let completed = await self.waitUntil(timeout: .seconds(2)) {
            let task = await manager.task(id: snapshot.id)
            return task?.state == .completed
        }
        XCTAssertTrue(completed)
        let executedTaskIDs = await worker.executedTaskIDs()
        XCTAssertEqual(executedTaskIDs, [snapshot.id])
    }

    func test_recoverUnfinishedTasksOnLaunch_marksQueuedAndRunningAsCanceled() async throws {
        let storeURL = try self.makeTemporaryStoreURL()
        let persistence = PersistenceManager.createForTesting(inMemory: false, storeURL: storeURL)

        let queued = BackgroundTaskRecord(
            inputs: BackgroundTaskInputs(urls: ["https://example.com/queued"]),
            policy: BackgroundTaskPolicy()
        )
        let running = BackgroundTaskRecord(
            inputs: BackgroundTaskInputs(urls: ["https://example.com/running"]),
            policy: BackgroundTaskPolicy()
        )
        running.stateRawValue = BackgroundTaskState.running.rawValue
        running.startedAt = Date()

        persistence.context.insert(queued)
        persistence.context.insert(running)
        persistence.flushSave()

        let reloadedPersistence = PersistenceManager.createForTesting(inMemory: false, storeURL: storeURL)
        let manager = BackgroundTaskManager(modelContainer: reloadedPersistence.container)

        await manager.recoverUnfinishedTasksOnLaunch()

        let tasks = await manager.list(limit: 10)
        XCTAssertEqual(tasks.count, 2)
        XCTAssertTrue(tasks.allSatisfy { $0.state == .canceled })
        XCTAssertTrue(tasks.allSatisfy { $0.errorMessage == BackgroundTaskManager.recoveryCancellationReason })
    }

    func test_recoverPendingSummaries_marksFailedEvenWithGenerator() async throws {
        // Recovery always marks pending summaries as failed to prevent crash loops.
        // If the previous summary attempt crashed the process (MLX SIGTRAP),
        // re-enqueuing would crash again immediately on launch.
        let storeURL = try self.makeTemporaryStoreURL()
        let persistence = PersistenceManager.createForTesting(inMemory: false, storeURL: storeURL)

        let completedWithPendingSummary = BackgroundTaskRecord(
            inputs: BackgroundTaskInputs(urls: ["https://example.com/page"]),
            policy: BackgroundTaskPolicy()
        )
        completedWithPendingSummary.stateRawValue = BackgroundTaskState.completed.rawValue
        completedWithPendingSummary.summaryStateRawValue = BackgroundTaskSummaryState.pending.rawValue
        completedWithPendingSummary.completedAt = Date()

        persistence.context.insert(completedWithPendingSummary)
        persistence.flushSave()

        let taskID = completedWithPendingSummary.id

        let reloadedPersistence = PersistenceManager.createForTesting(inMemory: false, storeURL: storeURL)
        let manager = BackgroundTaskManager(modelContainer: reloadedPersistence.container)

        let mockLLM = RecoverySummaryMockLLM()
        let rootDir = try self.makeTemporaryArtifactRootURL()
        let summaryGenerator = SummaryGenerator(
            llmService: mockLLM,
            artifactStore: ArtifactStore(rootURL: rootDir),
            taskManagerProvider: { manager }
        )

        await manager.configure(
            worker: URLSessionWorker(),
            artifactStore: ArtifactStore(rootURL: rootDir),
            summaryGenerator: summaryGenerator
        )

        await manager.recoverUnfinishedTasksOnLaunch()

        // Should mark as failed, NOT re-enqueue (prevents crash loops)
        let jobCount = await summaryGenerator.pendingJobCount
        XCTAssertEqual(jobCount, 0, "Pending summary should NOT be re-enqueued (crash loop prevention)")

        let task = await manager.task(id: taskID)
        XCTAssertEqual(task?.state, .completed)
        XCTAssertEqual(task?.summaryState, .failed, "Pending summary should be marked failed on recovery")
    }

    func test_recoverPendingSummaries_marksFailedWithoutGenerator() async throws {
        let storeURL = try self.makeTemporaryStoreURL()
        let persistence = PersistenceManager.createForTesting(inMemory: false, storeURL: storeURL)

        let completedWithPendingSummary = BackgroundTaskRecord(
            inputs: BackgroundTaskInputs(urls: ["https://example.com/page"]),
            policy: BackgroundTaskPolicy()
        )
        completedWithPendingSummary.stateRawValue = BackgroundTaskState.completed.rawValue
        completedWithPendingSummary.summaryStateRawValue = BackgroundTaskSummaryState.pending.rawValue
        completedWithPendingSummary.completedAt = Date()

        persistence.context.insert(completedWithPendingSummary)
        persistence.flushSave()

        let taskID = completedWithPendingSummary.id

        let reloadedPersistence = PersistenceManager.createForTesting(inMemory: false, storeURL: storeURL)
        let manager = BackgroundTaskManager(modelContainer: reloadedPersistence.container)

        // Configure without summary generator
        let rootDir = try self.makeTemporaryArtifactRootURL()
        await manager.configure(
            worker: URLSessionWorker(),
            artifactStore: ArtifactStore(rootURL: rootDir),
            summaryGenerator: nil
        )

        await manager.recoverUnfinishedTasksOnLaunch()

        // The task should have summaryState marked as failed
        let task = await manager.task(id: taskID)
        XCTAssertEqual(task?.state, .completed)
        XCTAssertEqual(task?.summaryState, .failed, "Pending summary should be marked failed when no generator is available")
    }

    func test_cancelAll_marksActiveAndQueuedTasksCanceled() async throws {
        let controller = BlockingExecutorController()
        let manager = await self.makeInMemoryManager(
            executor: { request in
                return try await controller.execute(request: request)
            },
            concurrencyLimit: 1
        )

        let first = try await manager.enqueue(inputs: BackgroundTaskInputs(urls: ["https://example.com/1"]))
        let second = try await manager.enqueue(inputs: BackgroundTaskInputs(urls: ["https://example.com/2"]))

        let statesReady = await self.waitUntil {
            let running = await manager.task(id: first.id)
            let queued = await manager.task(id: second.id)
            return running?.state == .running && queued?.state == .queued
        }
        XCTAssertTrue(statesReady)

        await manager.cancelAll()

        let tasks = await manager.list(limit: 10)
        XCTAssertEqual(tasks.count, 2)
        XCTAssertTrue(tasks.allSatisfy { $0.state == .canceled })
        let cleaned = await self.waitUntil { await controller.currentRunningCount() == 0 }
        XCTAssertTrue(cleaned)
    }

    func test_execution_persistsArtifactsAndUpdatesArtifactPath() async throws {
        let rootURL = try self.makeTemporaryArtifactRootURL()
        let completedAt = Self.artifactCompletedAt
        let artifactStore = ArtifactStore(
            rootURL: rootURL,
            now: { completedAt }
        )
        let sampleResult = Self.sampleWorkerResult()
        let manager = await self.makeInMemoryManager(
            executor: { _ in
                return BackgroundTaskExecutionResult(
                    artifactWorkerResult: sampleResult,
                    persistRawHTML: true
                )
            },
            artifactStore: artifactStore
        )

        let snapshot = try await manager.enqueue(
            inputs: BackgroundTaskInputs(urls: ["https://example.com/research"], label: "Artifact Task")
        )

        let completed = await self.waitUntil {
            let task = await manager.task(id: snapshot.id)
            return task?.state == .completed && task?.artifactPath != nil
        }
        XCTAssertTrue(completed)

        let storedTask = await manager.task(id: snapshot.id)
        XCTAssertNotNil(storedTask?.artifactPath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: storedTask?.artifactPath ?? ""))
        let artifact = try await artifactStore.read(taskID: snapshot.id)
        XCTAssertEqual(artifact.result.summary, Self.sampleWorkerResult().summary)
        XCTAssertEqual(artifact.rawHTMLPages.count, 2)
    }

    func test_execution_withWorkerResult_persistsArtifactsAndUpdatesArtifactPath() async throws {
        let rootURL = try self.makeTemporaryArtifactRootURL()
        let completedAt = Self.artifactCompletedAt
        let artifactStore = ArtifactStore(
            rootURL: rootURL,
            now: { completedAt }
        )
        let manager = await self.makeInMemoryManager(
            executor: { request in
                return BackgroundTaskExecutionResult(
                    workerResult: Self.sampleQueueWorkerResult(
                        taskID: request.taskID,
                        taskKind: request.taskKind
                    )
                )
            },
            artifactStore: artifactStore
        )

        let snapshot = try await manager.enqueue(
            inputs: BackgroundTaskInputs(urls: ["https://example.com/research"], label: "Queue Artifact Task")
        )

        let completed = await self.waitUntil(timeout: .seconds(5)) {
            let task = await manager.task(id: snapshot.id)
            return task?.state == .completed && task?.artifactPath != nil
        }
        XCTAssertTrue(completed)

        let storedTask = await manager.task(id: snapshot.id)
        XCTAssertNotNil(storedTask?.artifactPath)

        let artifact = try await artifactStore.read(taskID: snapshot.id)
        XCTAssertEqual(artifact.result.title, "Queue Artifact Task")
        XCTAssertEqual(artifact.result.pages.count, 2)
        XCTAssertEqual(artifact.citations.count, 2)
        XCTAssertFalse(artifact.result.summary.isEmpty)
    }

    func test_execution_withSummaryGenerator_writesSummaryMarkdown() async throws {
        let rootURL = try self.makeTemporaryArtifactRootURL()
        let artifactStore = ArtifactStore(rootURL: rootURL)
        let managerHolder = BackgroundTaskManagerHolder()
        let summaryGenerator = SummaryGenerator(
            llmService: BackgroundTaskSummaryMockLLMService(response: "- Summary line"),
            artifactStore: artifactStore,
            taskManagerProvider: { await managerHolder.manager }
        )
        let manager = await self.makeInMemoryManager(
            executor: { request in
                return BackgroundTaskExecutionResult(
                    workerResult: Self.sampleQueueWorkerResult(
                        taskID: request.taskID,
                        taskKind: request.taskKind
                    )
                )
            },
            artifactStore: artifactStore,
            summaryGenerator: summaryGenerator
        )
        await managerHolder.set(manager)
        await summaryGenerator.start()
        self.addTeardownBlock {
            Task {
                await summaryGenerator.stop()
            }
        }

        let snapshot = try await manager.enqueue(
            inputs: BackgroundTaskInputs(urls: ["https://example.com/research"], label: "Summary Task")
        )

        let summarized = await self.waitUntil(timeout: .seconds(15)) {
            guard let task = await manager.task(id: snapshot.id),
                  task.summaryState == .completed,
                  let artifactPath = task.artifactPath else {
                return false
            }
            let summaryURL = URL(fileURLWithPath: artifactPath).appendingPathComponent("summary.md")
            return FileManager.default.fileExists(atPath: summaryURL.path)
        }
        XCTAssertTrue(summarized)

        let task = await manager.task(id: snapshot.id)
        let summaryURL = URL(fileURLWithPath: task?.artifactPath ?? "").appendingPathComponent("summary.md")
        let summary = try String(contentsOf: summaryURL, encoding: .utf8)
        XCTAssertTrue(summary.contains("Summary line"))
    }

    // MARK: - Helpers

    private func makeInMemoryManager(
        executor: @escaping BackgroundTaskManager.Executor = { _ in BackgroundTaskExecutionResult() },
        concurrencyLimit: Int = BackgroundTaskManager.defaultConcurrencyLimit,
        queueDepthLimit: Int = BackgroundTaskManager.defaultQueueDepthLimit,
        artifactStore: ArtifactStore? = nil,
        summaryGenerator: SummaryGenerator? = nil
    ) async -> BackgroundTaskManager {
        let persistence = PersistenceManager.createForTesting(inMemory: true)
        let manager = BackgroundTaskManager(modelContainer: persistence.container)
        await manager.configureForTesting(
            executor: executor,
            concurrencyLimit: concurrencyLimit,
            queueDepthLimit: queueDepthLimit,
            artifactStore: artifactStore,
            summaryGenerator: summaryGenerator
        )
        return manager
    }

    private func makeTemporaryStoreURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BackgroundTaskManagerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return directory.appendingPathComponent("default.store")
    }

    private func makeTemporaryArtifactRootURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BackgroundTaskArtifacts-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return directory
    }

    private func waitUntil(
        timeout: Duration = .seconds(2),
        condition: @escaping @Sendable () async -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let start = clock.now
        while clock.now - start < timeout {
            if await condition() {
                return true
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return false
    }

    private func assertThrowsError<T>(
        operation: @escaping () async throws -> T,
        errorHandler: @escaping (Error) -> Void
    ) async {
        do {
            _ = try await operation()
            XCTFail("Expected error to be thrown")
        } catch {
            errorHandler(error)
        }
    }

    nonisolated private static func sampleWorkerResult() -> BackgroundTaskWorkerResult {
        return BackgroundTaskWorkerResult(
            title: "Background Artifact",
            summary: "Saved artifact data for the completed task.",
            markdown: "Background task completed successfully.",
            pages: [
                BackgroundTaskArtifactPage(
                    pageNumber: 1,
                    url: "https://example.com/source-a",
                    title: "Source A",
                    extractedText: "Source A text",
                    rawHTML: "<html><body>A</body></html>"
                ),
                BackgroundTaskArtifactPage(
                    pageNumber: 2,
                    url: "https://example.com/source-b",
                    title: "Source B",
                    extractedText: "Source B text",
                    rawHTML: "<html><body>B</body></html>"
                )
            ],
            citations: [
                BackgroundTaskArtifactCitation(
                    url: "https://example.com/source-a",
                    title: "Source A",
                    snippet: "Source A text"
                )
            ]
        )
    }

    nonisolated private static func sampleQueueWorkerResult(taskID: UUID, taskKind: String) -> WorkerResult {
        return WorkerResult(
            pages: [
                PageResult(
                    url: "https://example.com/source-a",
                    finalURL: "https://example.com/source-a",
                    title: "Source A",
                    text: "Launch is scheduled for Q2 and the team is aligned.",
                    contentType: "text/html",
                    wordCount: 10,
                    fetchedAt: artifactCompletedAt,
                    rawHTML: "<html><body>Source A</body></html>"
                ),
                PageResult(
                    url: "https://example.com/source-b",
                    finalURL: "https://example.com/source-b",
                    title: "Source B",
                    text: "Dependencies are already approved and procurement is complete.",
                    contentType: "text/html",
                    wordCount: 9,
                    fetchedAt: artifactCompletedAt,
                    rawHTML: "<html><body>Source B</body></html>"
                )
            ],
            metadata: WorkerMetadata(
                taskID: taskID,
                taskKind: taskKind,
                startedAt: artifactCompletedAt.addingTimeInterval(-5),
                completedAt: artifactCompletedAt,
                requestedURLCount: 2,
                succeededURLCount: 2,
                failedURLCount: 0,
                processedSequentially: true
            ),
            failedURLs: []
        )
    }

    nonisolated private static let artifactCompletedAt = ISO8601DateFormatter().date(from: "2026-01-06T12:00:00Z")!
}

private actor BlockingExecutorController {
    private var releasedTaskIDs: Set<UUID> = []
    private(set) var startedTaskIDs: [UUID] = []
    private(set) var currentRunning: Int = 0

    func execute(request: BackgroundTaskExecutionRequest) async throws -> BackgroundTaskExecutionResult {
        self.startedTaskIDs.append(request.taskID)
        self.currentRunning += 1

        do {
            while !self.releasedTaskIDs.contains(request.taskID) {
                try await Task.sleep(for: .milliseconds(20))
            }
            self.currentRunning -= 1
            return BackgroundTaskExecutionResult()
        } catch {
            self.currentRunning -= 1
            throw error
        }
    }

    func currentRunningCount() -> Int {
        return self.currentRunning
    }
}

private actor DelayedExecutorTracker {
    private let delay: Duration
    private(set) var currentRunning: Int = 0
    private(set) var maxRunning: Int = 0

    init(delay: Duration) {
        self.delay = delay
    }

    func execute(request: BackgroundTaskExecutionRequest) async throws -> BackgroundTaskExecutionResult {
        _ = request
        self.currentRunning += 1
        self.maxRunning = max(self.maxRunning, self.currentRunning)

        do {
            try await Task.sleep(for: self.delay)
            self.currentRunning -= 1
            return BackgroundTaskExecutionResult()
        } catch {
            self.currentRunning -= 1
            throw error
        }
    }

    func maxRunningObserved() -> Int {
        return self.maxRunning
    }
}

private actor EventCollector {
    private var storedEvents: [BackgroundTaskEvent] = []

    func record(_ event: BackgroundTaskEvent) {
        self.storedEvents.append(event)
    }

    func count() -> Int {
        return self.storedEvents.count
    }

    func events() -> [BackgroundTaskEvent] {
        return self.storedEvents
    }
}

private actor RecordingBackgroundWorker: BackgroundWorker {
    private var taskIDs: [UUID] = []

    func execute(
        taskID: UUID,
        input: BackgroundTaskInputs,
        policy: BackgroundTaskPolicy
    ) async throws -> WorkerResult {
        _ = input
        self.taskIDs.append(taskID)

        return WorkerResult(
            pages: [
                PageResult(
                    url: "https://example.com/worker",
                    finalURL: "https://example.com/worker",
                    title: "Worker",
                    text: "Text",
                    contentType: "text/plain",
                    wordCount: 1,
                    fetchedAt: Date(),
                    rawHTML: nil
                )
            ],
            metadata: WorkerMetadata(
                taskID: taskID,
                taskKind: policy.taskKind,
                startedAt: Date(),
                completedAt: Date(),
                requestedURLCount: 1,
                succeededURLCount: 1,
                failedURLCount: 0,
                processedSequentially: true
            ),
            failedURLs: []
        )
    }

    func executedTaskIDs() -> [UUID] {
        return self.taskIDs
    }
}

private actor BackgroundTaskManagerHolder {
    private(set) var manager: BackgroundTaskManager?

    func set(_ manager: BackgroundTaskManager) {
        self.manager = manager
    }
}

private actor BackgroundTaskSummaryMockLLMService: LLMServicing {
    private let response: String

    init(response: String) {
        self.response = response
    }

    func generate(messages: [LLMMessage], maxTokens: Int) async -> AsyncThrowingStream<LLMDelta, Error> {
        _ = messages
        _ = maxTokens
        let response = self.response
        return AsyncThrowingStream { continuation in
            continuation.yield(.token(response))
            continuation.finish()
        }
    }

    func warmup() async throws {}

    func prepare() async throws {}

    func unload() async {}

    func capabilities() async -> ProviderCapabilities {
        return .textOnly
    }

    func clearCache() async {}

    func generateOneShot(prompt: String, maxTokens: Int) async throws -> String {
        _ = prompt
        _ = maxTokens
        return self.response
    }
}

private actor RecoverySummaryMockLLM: LLMServicing {
    func prepare() async throws {}
    func warmup() async throws {}
    func unload() async {}
    func capabilities() async -> ProviderCapabilities { .textOnly }
    func clearCache() async {}

    func generate(messages: [LLMMessage], maxTokens: Int) async -> AsyncThrowingStream<LLMDelta, Error> {
        return AsyncThrowingStream { continuation in
            continuation.yield(.token("mock"))
            continuation.finish()
        }
    }

    func generateOneShot(prompt: String, maxTokens: Int) async throws -> String {
        return "mock summary"
    }
}
