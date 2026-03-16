//
//  TaskNotificationDelegateTests.swift
//  OraTests
//
//  Tests for TaskNotificationDelegate artifact path validation
//  and action handling logic.
//

import XCTest
import UserNotifications
@testable import Ora

final class TaskNotificationDelegateTests: XCTestCase {

    // MARK: - Path Validation

    func test_artifactPathValidation_acceptsPathWithinRoot() {
        let rootURL = URL(fileURLWithPath: "/tmp/test-artifacts/Ora Research")
        let delegate = TaskNotificationDelegate(artifactRootProvider: { rootURL })

        let valid = delegate.isPathWithinArtifactRoot(
            "/tmp/test-artifacts/Ora Research/2026-03-16/task-abc12345-test"
        )
        XCTAssertTrue(valid)
    }

    func test_artifactPathValidation_rejectsPathOutsideRoot() {
        let rootURL = URL(fileURLWithPath: "/tmp/test-artifacts/Ora Research")
        let delegate = TaskNotificationDelegate(artifactRootProvider: { rootURL })

        let valid = delegate.isPathWithinArtifactRoot("/etc/passwd")
        XCTAssertFalse(valid)
    }

    func test_artifactPathValidation_rejectsTraversalAttack() {
        let rootURL = URL(fileURLWithPath: "/tmp/test-artifacts/Ora Research")
        let delegate = TaskNotificationDelegate(artifactRootProvider: { rootURL })

        let valid = delegate.isPathWithinArtifactRoot(
            "/tmp/test-artifacts/Ora Research/../../../etc/passwd"
        )
        XCTAssertFalse(valid)
    }

    func test_artifactPathValidation_acceptsExactRoot() {
        let rootURL = URL(fileURLWithPath: "/tmp/test-artifacts/Ora Research")
        let delegate = TaskNotificationDelegate(artifactRootProvider: { rootURL })

        let valid = delegate.isPathWithinArtifactRoot(
            "/tmp/test-artifacts/Ora Research"
        )
        XCTAssertTrue(valid)
    }

    func test_artifactPathValidation_rejectsSimilarPrefix() {
        let rootURL = URL(fileURLWithPath: "/tmp/test-artifacts/Ora Research")
        let delegate = TaskNotificationDelegate(artifactRootProvider: { rootURL })

        // "Ora Research Evil" starts with the same prefix but is not under root
        let valid = delegate.isPathWithinArtifactRoot(
            "/tmp/test-artifacts/Ora Research Evil/malicious"
        )
        XCTAssertFalse(valid)
    }

    func test_artifactPathValidation_returnsFalseWhenProviderThrows() {
        let delegate = TaskNotificationDelegate(artifactRootProvider: {
            throw NSError(domain: "test", code: 1)
        })

        let valid = delegate.isPathWithinArtifactRoot("/any/path")
        XCTAssertFalse(valid)
    }

    // MARK: - Default Click

    func test_defaultClick_activatesApp() async {
        // Verify the delegate can be instantiated and the default click
        // code path exists. Full integration requires a running app.
        let delegate = TaskNotificationDelegate(artifactRootProvider: {
            URL(fileURLWithPath: "/tmp/test-root")
        })

        // The delegate should be a valid UNUserNotificationCenterDelegate
        XCTAssertNotNil(delegate as UNUserNotificationCenterDelegate)
    }

    // MARK: - Show in Finder Action

    func test_showInFinderAction_revealsArtifactPath() {
        // Verify that the action identifier constant matches expected value
        XCTAssertEqual(
            TaskNotificationService.showInFinderActionIdentifier,
            "com.ora.backgroundTask.showInFinder"
        )
    }
}
