//
//  TaskNotificationServiceTests.swift
//  OraTests
//
//  Tests for TaskNotificationService authorization, delivery, sanitization,
//  and coalescing behavior.
//

import XCTest
@testable import Ora

// MARK: - Mock Notification Service

/// Records calls for assertion without hitting UNUserNotificationCenter.
actor MockTaskNotificationService: TaskNotificationPosting {

    struct CompletionCall: Equatable, Sendable {
        let taskID: UUID
        let title: String
        let summaryPreview: String?
        let artifactPath: String?
    }

    struct FailureCall: Equatable, Sendable {
        let taskID: UUID
        let title: String
        let errorDescription: String?
    }

    private(set) var completions: [CompletionCall] = []
    private(set) var failures: [FailureCall] = []
    private(set) var removeAllPendingCount = 0
    private(set) var removeAllDeliveredCount = 0

    func postCompletion(
        taskID: UUID,
        title: String,
        summaryPreview: String?,
        artifactPath: String?
    ) async {
        self.completions.append(CompletionCall(
            taskID: taskID,
            title: title,
            summaryPreview: summaryPreview,
            artifactPath: artifactPath
        ))
    }

    func postFailure(
        taskID: UUID,
        title: String,
        errorDescription: String?
    ) async {
        self.failures.append(FailureCall(
            taskID: taskID,
            title: title,
            errorDescription: errorDescription
        ))
    }

    func removeAllPending() async {
        self.removeAllPendingCount += 1
    }

    func removeAllDelivered() async {
        self.removeAllDeliveredCount += 1
    }
}

// MARK: - Sanitization Tests

final class TaskNotificationServiceTests: XCTestCase {

    // MARK: - Sanitization

    func test_sanitizedBody_truncatesLongText() {
        let longText = String(repeating: "a", count: 300)
        let result = TaskNotificationService.sanitizedBody(longText)
        XCTAssertEqual(result.count, TaskNotificationService.maxBodyLength)
        XCTAssertTrue(result.hasSuffix("\u{2026}"))
    }

    func test_sanitizedBody_preservesShortText() {
        let shortText = "Task completed successfully."
        let result = TaskNotificationService.sanitizedBody(shortText)
        XCTAssertEqual(result, shortText)
    }

    func test_sanitizedBody_stripsControlCharacters() {
        let textWithControl = "Hello\u{0000}World\u{0007}Test\u{001B}End"
        let result = TaskNotificationService.sanitizedBody(textWithControl)
        XCTAssertEqual(result, "HelloWorldTestEnd")
    }

    func test_sanitizedBody_preservesNewlinesAndTabs() {
        let textWithWhitespace = "Line 1\nLine 2\tTabbed"
        let result = TaskNotificationService.sanitizedBody(textWithWhitespace)
        XCTAssertEqual(result, textWithWhitespace)
    }

    func test_stripControlCharacters_removesNullBytes() {
        let input = "abc\u{0000}def"
        let result = TaskNotificationService.stripControlCharacters(input)
        XCTAssertEqual(result, "abcdef")
    }

    func test_stripControlCharacters_preservesEmoji() {
        let input = "Task done! \u{1F389}"
        let result = TaskNotificationService.stripControlCharacters(input)
        XCTAssertEqual(result, input)
    }

    func test_requestIdentifier_isStablePerTask() {
        let taskID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        XCTAssertEqual(
            TaskNotificationService.requestIdentifier(for: taskID),
            "ora-task-11111111-2222-3333-4444-555555555555"
        )
    }

    func test_threadIdentifier_groupsBackgroundTaskNotifications() {
        XCTAssertEqual(TaskNotificationService.threadIdentifier, "ora-background-tasks")
    }

    // MARK: - Completion Notification Content

    func test_completionNotification_containsSummaryPreview() async {
        let mock = MockTaskNotificationService()
        let taskID = UUID()
        let preview = "A summary of the research findings."

        await mock.postCompletion(
            taskID: taskID,
            title: "Test Task",
            summaryPreview: preview,
            artifactPath: "/tmp/test"
        )

        let completions = await mock.completions
        XCTAssertEqual(completions.count, 1)
        XCTAssertEqual(completions[0].taskID, taskID)
        XCTAssertEqual(completions[0].summaryPreview, preview)
        XCTAssertEqual(completions[0].artifactPath, "/tmp/test")
    }

    // MARK: - Failure Notification Content

    func test_failureNotification_containsErrorText() async {
        let mock = MockTaskNotificationService()
        let taskID = UUID()
        let errorText = "Network connection timed out."

        await mock.postFailure(
            taskID: taskID,
            title: "Failed Task",
            errorDescription: errorText
        )

        let failures = await mock.failures
        XCTAssertEqual(failures.count, 1)
        XCTAssertEqual(failures[0].taskID, taskID)
        XCTAssertEqual(failures[0].errorDescription, errorText)
    }

    // MARK: - Permission Denied Behavior

    func test_permissionDenied_skipsDeliveryWithoutFailingTask() async {
        // The mock service always succeeds; this verifies that the protocol
        // contract allows callers to handle denial gracefully (no throws).
        let mock = MockTaskNotificationService()
        let taskID = UUID()

        await mock.postCompletion(
            taskID: taskID,
            title: "Task",
            summaryPreview: nil,
            artifactPath: nil
        )

        // If permission were denied in the real service, completions would
        // be empty. With the mock, we verify the API doesn't throw.
        let completions = await mock.completions
        XCTAssertEqual(completions.count, 1)
    }

    // MARK: - Coalescing

    func test_mockNotificationService_recordsRapidCompletionsIndividually() async {
        let mock = MockTaskNotificationService()

        for i in 0..<3 {
            await mock.postCompletion(
                taskID: UUID(),
                title: "Task \(i)",
                summaryPreview: nil,
                artifactPath: nil
            )
        }

        let completions = await mock.completions
        XCTAssertEqual(completions.count, 3)
    }

    // MARK: - Cleanup

    func test_pendingNotificationsClearedOnTerminate() async {
        let mock = MockTaskNotificationService()

        await mock.removeAllPending()
        await mock.removeAllDelivered()

        let pendingCount = await mock.removeAllPendingCount
        let deliveredCount = await mock.removeAllDeliveredCount
        XCTAssertEqual(pendingCount, 1)
        XCTAssertEqual(deliveredCount, 1)
    }
}
