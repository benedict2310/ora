//
//  TaskProgressObserverTests.swift
//  OraTests
//
//  Tests for TaskProgressObserver lifecycle and cancel behavior.
//

import XCTest
@testable import Ora

@MainActor
final class TaskProgressObserverTests: XCTestCase {

    func test_observer_tracksActiveTaskLifecycle() async throws {
        let manager = await self.makeTaskManager(
            executor: { _ in
                try await Task.sleep(for: .milliseconds(150))
                return BackgroundTaskExecutionResult()
            }
        )
        let observer = TaskProgressObserver(
            managerProvider: { manager },
            menuPresenter: {}
        )

        _ = try await manager.enqueue(
            inputs: BackgroundTaskInputs(urls: ["https://example.com/lifecycle"], label: "Lifecycle Task")
        )

        let becameActive = await self.waitUntil {
            observer.primaryTask?.phase == .fetching(urlCount: 1)
        }
        XCTAssertTrue(becameActive)

        let cleared = await self.waitUntil(timeout: .seconds(3)) {
            observer.activeTasks.isEmpty
        }
        XCTAssertTrue(cleared)
    }

    func test_observer_reportsQueuedAndFetchingPhases() async throws {
        let blocker = TaskProgressBlockingExecutor()
        let manager = await self.makeTaskManager(
            executor: { request in
                try await blocker.execute(request: request)
            },
            concurrencyLimit: 1
        )
        let observer = TaskProgressObserver(
            managerProvider: { manager },
            menuPresenter: {}
        )

        let first = try await manager.enqueue(
            inputs: BackgroundTaskInputs(urls: ["https://example.com/first"], label: "First Task")
        )
        _ = try await manager.enqueue(
            inputs: BackgroundTaskInputs(urls: ["https://example.com/second"], label: "Second Task")
        )

        let phasesReady = await self.waitUntil {
            let phasesByLabel = Dictionary(uniqueKeysWithValues: observer.activeTasks.map { ($0.label, $0.phase) })
            return phasesByLabel["First Task"] == .fetching(urlCount: 1)
                && phasesByLabel["Second Task"] == .queued(urlCount: 1)
        }
        XCTAssertTrue(phasesReady)

        await blocker.release(taskID: first.id)
        await manager.cancelAll()
    }

    func test_observer_reportsSummarizingPhase() async throws {
        let manager = await self.makeTaskManager(
            executor: { _ in
                return BackgroundTaskExecutionResult()
            }
        )
        let observer = TaskProgressObserver(
            managerProvider: { manager },
            menuPresenter: {}
        )

        let snapshot = try await manager.enqueue(
            inputs: BackgroundTaskInputs(urls: ["https://example.com/summary"], label: "Summary Task")
        )

        let completed = await self.waitUntil {
            let task = await manager.task(id: snapshot.id)
            return task?.state == .completed
        }
        XCTAssertTrue(completed)

        await manager.updateSummaryState(taskID: snapshot.id, state: .pending)

        let summarizing = await self.waitUntil {
            observer.primaryTask?.phase == .summarizing
        }
        XCTAssertTrue(summarizing)

        await manager.updateSummaryState(taskID: snapshot.id, state: .completed)

        let cleared = await self.waitUntil {
            observer.activeTasks.isEmpty
        }
        XCTAssertTrue(cleared)
    }

    func test_observer_recoversWhenManagerBecomesAvailableLater() async throws {
        let provider = TaskProgressManagerProvider()
        let observer = TaskProgressObserver(
            managerProvider: { provider.manager },
            menuPresenter: {}
        )

        let manager = await self.makeTaskManager(
            executor: { _ in
                try await Task.sleep(for: .seconds(1))
                return BackgroundTaskExecutionResult()
            }
        )
        provider.manager = manager

        _ = try await manager.enqueue(
            inputs: BackgroundTaskInputs(urls: ["https://example.com/retry"], label: "Retry Task")
        )

        let recovered = await self.waitUntil(timeout: .seconds(3)) {
            observer.primaryTask?.label == "Retry Task"
        }
        XCTAssertTrue(recovered)

        await manager.cancelAll()
    }

    func test_cancelPrimaryTask_cancelsManagerTask() async throws {
        let blocker = TaskProgressBlockingExecutor()
        let manager = await self.makeTaskManager(
            executor: { request in
                try await blocker.execute(request: request)
            }
        )
        let observer = TaskProgressObserver(
            managerProvider: { manager },
            menuPresenter: {}
        )

        let snapshot = try await manager.enqueue(
            inputs: BackgroundTaskInputs(urls: ["https://example.com/cancel"], label: "Cancelable Task")
        )

        let becameActive = await self.waitUntil {
            observer.primaryTask?.id == snapshot.id
        }
        XCTAssertTrue(becameActive)

        observer.cancelPrimaryTask()

        let canceled = await self.waitUntil {
            let task = await manager.task(id: snapshot.id)
            return task?.state == .canceled
        }
        XCTAssertTrue(canceled)

        let cleared = await self.waitUntil {
            observer.activeTasks.isEmpty
        }
        XCTAssertTrue(cleared)
    }

    func test_staleSummarizingTask_isHiddenAfterGracePeriod() async throws {
        let manager = await self.makeTaskManager(
            executor: { _ in
                return BackgroundTaskExecutionResult()
            }
        )
        let observer = TaskProgressObserver(
            managerProvider: { manager },
            menuPresenter: {}
        )

        let snapshot = try await manager.enqueue(
            inputs: BackgroundTaskInputs(urls: ["https://example.com/stale"], label: "Stale Task")
        )

        // Wait for task to complete
        let completed = await self.waitUntil {
            let task = await manager.task(id: snapshot.id)
            return task?.state == .completed
        }
        XCTAssertTrue(completed)

        // Mark summary as pending — this should initially appear as summarizing
        await manager.updateSummaryState(taskID: snapshot.id, state: .pending)

        let summarizing = await self.waitUntil {
            observer.primaryTask?.phase == .summarizing
        }
        XCTAssertTrue(summarizing, "Recent pending summary should show as summarizing")

        // Backdate the completedAt to more than 5 minutes ago
        await manager.backdateCompletedAt(taskID: snapshot.id, seconds: -400)

        // After the grace period, the stale task should no longer appear in active tasks
        let cleared = await self.waitUntil(timeout: .seconds(5)) {
            observer.activeTasks.isEmpty
        }
        XCTAssertTrue(cleared, "Stale summarizing task should be hidden after grace period")
    }

    private func makeTaskManager(
        executor: @escaping BackgroundTaskManager.Executor,
        concurrencyLimit: Int = BackgroundTaskManager.defaultConcurrencyLimit
    ) async -> BackgroundTaskManager {
        let persistence = PersistenceManager.createForTesting(inMemory: true)
        let manager = BackgroundTaskManager(modelContainer: persistence.container)
        await manager.configureForTesting(
            executor: executor,
            concurrencyLimit: concurrencyLimit,
            notificationService: nil
        )
        return manager
    }

    private func waitUntil(
        timeout: Duration = .seconds(2),
        condition: @escaping () async -> Bool
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
}

private actor TaskProgressBlockingExecutor {
    private var releasedTaskIDs: Set<UUID> = []

    func execute(request: BackgroundTaskExecutionRequest) async throws -> BackgroundTaskExecutionResult {
        while !self.releasedTaskIDs.contains(request.taskID) {
            try await Task.sleep(for: .milliseconds(20))
        }
        return BackgroundTaskExecutionResult()
    }

    func release(taskID: UUID) {
        self.releasedTaskIDs.insert(taskID)
    }
}

@MainActor
private final class TaskProgressManagerProvider {
    var manager: BackgroundTaskManager?
}
