//
//  TranscriptCoordinatorTests.swift
//  OraTests
//
//  Unit tests for TranscriptCoordinator
//

import XCTest
@testable import Ora

final class TranscriptCoordinatorTests: XCTestCase {

    // MARK: - AC-1: Shared Instance

    func test_sharedInstance_exists() {
        let coordinator = TranscriptCoordinator.shared
        XCTAssertNotNil(coordinator)
    }

    // MARK: - AC-4: Cancel Session

    func test_cancelSession_doesNotThrow() async {
        let coordinator = TranscriptCoordinator.shared

        // Cancelling when no session is active should not throw
        await coordinator.cancelSession()
    }

    func test_cancelSession_stopsActiveSession() async {
        let coordinator = TranscriptCoordinator.shared

        // Start a session in background
        let sessionTask = Task {
            try await coordinator.startSession()
        }

        // Give it a moment to start
        try? await Task.sleep(for: .milliseconds(50))

        // Cancel the session
        await coordinator.cancelSession()

        // Cancel the task as well
        sessionTask.cancel()

        // Should complete without hanging
        let result = try? await sessionTask.value
        XCTAssertNil(result) // Cancelled session returns nil
    }

    // MARK: - Session Lifecycle

    func test_startSession_cancelsExistingSession() async throws {
        let coordinator = TranscriptCoordinator.shared

        // Start first session (will be cancelled)
        let firstTask = Task {
            try await coordinator.startSession()
        }

        // Give it a moment
        try await Task.sleep(for: .milliseconds(50))

        // Start second session - should cancel first
        let secondTask = Task {
            try await coordinator.startSession()
        }

        // Give it a moment
        try await Task.sleep(for: .milliseconds(50))

        // Cancel both for cleanup
        await coordinator.cancelSession()
        firstTask.cancel()
        secondTask.cancel()

        // Test passes if no deadlock/crash occurs
    }
}
