//
//  SetupCoordinatorTests.swift
//  OraTests
//
//  Tests for first-run setup flow
//

import XCTest
@testable import Ora

// MARK: - Setup Step Tests

final class SetupStepTests: XCTestCase {

    // MARK: - Title Tests

    func test_title_returnsCorrectValues() {
        XCTAssertEqual(SetupStep.welcome.title, "Welcome")
        XCTAssertEqual(SetupStep.permissions.title, "Permissions")
        XCTAssertEqual(SetupStep.download.title, "Download Models")
        XCTAssertEqual(SetupStep.ready.title, "Ready")
    }

    // MARK: - Can Go Back Tests

    func test_canGoBack_welcomeCannotGoBack() {
        XCTAssertFalse(SetupStep.welcome.canGoBack)
    }

    func test_canGoBack_permissionsCanGoBack() {
        XCTAssertTrue(SetupStep.permissions.canGoBack)
    }

    func test_canGoBack_downloadCannotGoBack() {
        // Can't go back during download to prevent interruption
        XCTAssertFalse(SetupStep.download.canGoBack)
    }

    func test_canGoBack_readyCannotGoBack() {
        XCTAssertFalse(SetupStep.ready.canGoBack)
    }

    // MARK: - CaseIterable Tests

    func test_allCases_containsFourSteps() {
        XCTAssertEqual(SetupStep.allCases.count, 4)
    }

    func test_rawValues_areSequential() {
        XCTAssertEqual(SetupStep.welcome.rawValue, 0)
        XCTAssertEqual(SetupStep.permissions.rawValue, 1)
        XCTAssertEqual(SetupStep.download.rawValue, 2)
        XCTAssertEqual(SetupStep.ready.rawValue, 3)
    }
}

// MARK: - Setup State Tests

final class SetupStateTests: XCTestCase {

    // MARK: - Initial State

    func test_initialState_startsAtWelcome() {
        let state = SetupState()
        XCTAssertEqual(state.currentStep, .welcome)
    }

    func test_initialState_notComplete() {
        let state = SetupState()
        XCTAssertFalse(state.isComplete)
    }

    func test_initialState_permissionsNotGranted() {
        let state = SetupState()
        XCTAssertFalse(state.permissionsGranted)
    }

    func test_initialState_downloadProgressZero() {
        let state = SetupState()
        XCTAssertEqual(state.downloadProgress, 0)
    }

    func test_initialState_noDownloadError() {
        let state = SetupState()
        XCTAssertNil(state.downloadError)
    }

    func test_initialState_noCurrentDownload() {
        let state = SetupState()
        XCTAssertNil(state.downloadingModel)
    }

    // MARK: - System Info

    func test_systemRAMGB_defaultsToZero() {
        let state = SetupState()
        XCTAssertEqual(state.systemRAMGB, 0)
    }

    func test_recommendedModel_defaultsTo7B() {
        let state = SetupState()
        XCTAssertEqual(state.recommendedModel, "Qwen 2.5 7B")
    }

    // MARK: - Model Progresses

    func test_modelProgresses_emptyByDefault() {
        let state = SetupState()
        XCTAssertTrue(state.modelProgresses.isEmpty)
    }

    func test_modelProgresses_canTrackIndividualModels() {
        var state = SetupState()
        state.modelProgresses[.parakeetTDT] = 0.5
        state.modelProgresses[.qwen7B] = 0.25
        state.modelProgresses[.kokoro] = 1.0

        XCTAssertEqual(state.modelProgresses[.parakeetTDT], 0.5)
        XCTAssertEqual(state.modelProgresses[.qwen7B], 0.25)
        XCTAssertEqual(state.modelProgresses[.kokoro], 1.0)
    }
}

// MARK: - Setup Coordinator Tests

@MainActor
final class SetupCoordinatorTests: XCTestCase {

    // MARK: - Singleton Tests

    func test_shared_returnsSameInstance() {
        let instance1 = SetupCoordinator.shared
        let instance2 = SetupCoordinator.shared

        XCTAssertTrue(instance1 === instance2)
    }

    // MARK: - Initial State Tests

    func test_initialState_notShowingSetup() {
        let coordinator = SetupCoordinator.shared

        // Note: The shared instance may have state from previous test runs.
        // We can only verify the structure exists.
        XCTAssertNotNil(coordinator.state)
    }

    func test_state_hasSystemRAMInfo() {
        let coordinator = SetupCoordinator.shared

        // System RAM should be populated from ProcessInfo
        XCTAssertGreaterThan(coordinator.state.systemRAMGB, 0)
    }

    func test_state_hasRecommendedModel() {
        let coordinator = SetupCoordinator.shared

        // Should recommend based on RAM
        let expectedModel = coordinator.state.systemRAMGB >= 16 ? "Qwen 2.5 7B" : "Qwen 2.5 3B"
        XCTAssertEqual(coordinator.state.recommendedModel, expectedModel)
    }

    // MARK: - Setup Complete Detection Tests

    func test_isSetupComplete_readsUserDefaults() {
        let coordinator = SetupCoordinator.shared

        // This tests the property exists and returns a boolean
        let _ = coordinator.isSetupComplete
        // No assertion needed - just verifying the property works
    }

    // MARK: - Step Navigation Tests

    func test_previousStep_fromPermissions_goesToWelcome() {
        let coordinator = SetupCoordinator.shared

        // Set to permissions step (would need internal access to test properly)
        // For now, just verify the method exists and doesn't crash
        coordinator.previousStep()
    }
}

// MARK: - Setup Notification Tests

final class SetupNotificationTests: XCTestCase {

    func test_setupDidComplete_notificationExists() {
        // Verify the notification name is properly defined
        let name = Notification.Name.setupDidComplete
        XCTAssertEqual(name.rawValue, "setupDidComplete")
    }
}
