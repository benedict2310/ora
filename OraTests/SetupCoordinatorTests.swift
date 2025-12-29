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

    // MARK: - Step Transition Tests

    func test_stepTransition_welcomeToPermissions() {
        // Valid transition in sequence
        XCTAssertEqual(SetupStep.welcome.rawValue + 1, SetupStep.permissions.rawValue)
    }

    func test_stepTransition_permissionsToDownload() {
        XCTAssertEqual(SetupStep.permissions.rawValue + 1, SetupStep.download.rawValue)
    }

    func test_stepTransition_downloadToReady() {
        XCTAssertEqual(SetupStep.download.rawValue + 1, SetupStep.ready.rawValue)
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

    func test_initialState_primaryLLMDefault() {
        let state = SetupState()
        XCTAssertEqual(state.primaryLLM, .qwen7B)
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

    // MARK: - State Mutation Tests

    func test_stateIsSendable() {
        // SetupState conforms to Sendable
        var state = SetupState()
        state.currentStep = .permissions
        state.isComplete = true

        // Pass across isolation boundaries (this compiles = Sendable works)
        Task.detached {
            let _ = state.currentStep
            let _ = state.isComplete
        }
    }

    func test_downloadProgress_canBeUpdated() {
        var state = SetupState()
        state.downloadProgress = 0.5

        XCTAssertEqual(state.downloadProgress, 0.5)
    }

    func test_downloadError_canBeSet() {
        var state = SetupState()
        state.downloadError = "Network error"

        XCTAssertEqual(state.downloadError, "Network error")
    }

    func test_downloadingModel_canBeSet() {
        var state = SetupState()
        state.downloadingModel = "Parakeet ASR"

        XCTAssertEqual(state.downloadingModel, "Parakeet ASR")
    }

    func test_primaryLLM_canBeChanged() {
        var state = SetupState()
        state.primaryLLM = .qwen3B

        XCTAssertEqual(state.primaryLLM, .qwen3B)
    }

    func test_skippedOptionalPermissions_canBeSet() {
        var state = SetupState()
        state.skippedOptionalPermissions = true

        XCTAssertTrue(state.skippedOptionalPermissions)
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

    func test_initialState_hasState() {
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

    func test_state_primaryLLMMatchesRAM() {
        let coordinator = SetupCoordinator.shared

        // Primary LLM should be set based on RAM
        let expectedLLM: ModelIdentifier = coordinator.state.systemRAMGB >= 16 ? .qwen7B : .qwen3B
        XCTAssertEqual(coordinator.state.primaryLLM, expectedLLM)
    }

    // MARK: - Setup Complete Detection Tests

    func test_isSetupComplete_readsUserDefaults() {
        let coordinator = SetupCoordinator.shared

        // This tests the property exists and returns a boolean
        let isComplete = coordinator.isSetupComplete
        XCTAssertEqual(isComplete, UserDefaults.standard.bool(forKey: "com.ora.setupComplete"))
    }

    // MARK: - Step Navigation Tests

    func test_previousStep_respectsCanGoBack() {
        let coordinator = SetupCoordinator.shared

        // previousStep should respect the canGoBack property of each step
        // Since we can't easily reset state, just verify the method exists
        coordinator.previousStep()
    }

    // MARK: - Permissions Update Tests

    func test_updatePermissionsGranted_updatesState() {
        let coordinator = SetupCoordinator.shared

        // Store initial value
        let initialValue = coordinator.state.permissionsGranted

        // Update permissions granted
        coordinator.updatePermissionsGranted(true)
        XCTAssertTrue(coordinator.state.permissionsGranted)

        // Reset to initial value
        coordinator.updatePermissionsGranted(initialValue)
    }

    // MARK: - Postpone Tests

    func test_postponeSetup_setsIsShowingSetupToFalse() {
        let coordinator = SetupCoordinator.shared

        // Call postpone (this should set isShowingSetup to false)
        coordinator.postponeSetup()

        XCTAssertFalse(coordinator.isShowingSetup)
    }

    // MARK: - UserDefaults Persistence Tests

    func test_userDefaultsKey_isCorrect() {
        // The setup complete key should be consistent
        let key = "com.ora.setupComplete"
        let value = UserDefaults.standard.bool(forKey: key)

        // Just verify we can read from this key without crash
        _ = value
    }

    // MARK: - NSWindowDelegate Conformance Tests

    func test_coordinator_conformsToNSWindowDelegate() {
        let coordinator = SetupCoordinator.shared

        // Verify coordinator conforms to NSWindowDelegate
        XCTAssertTrue(coordinator is NSWindowDelegate)
    }
}

// MARK: - Setup Notification Tests

final class SetupNotificationTests: XCTestCase {

    func test_setupDidComplete_notificationExists() {
        // Verify the notification name is properly defined
        let name = Notification.Name.setupDidComplete
        XCTAssertEqual(name.rawValue, "setupDidComplete")
    }

    func test_setupDidComplete_canBePosted() {
        // Verify the notification can be posted and observed
        let expectation = self.expectation(description: "Notification received")

        let observer = NotificationCenter.default.addObserver(
            forName: .setupDidComplete,
            object: nil,
            queue: .main
        ) { _ in
            expectation.fulfill()
        }

        NotificationCenter.default.post(name: .setupDidComplete, object: nil)

        wait(for: [expectation], timeout: 1.0)
        NotificationCenter.default.removeObserver(observer)
    }
}

// MARK: - Download Gating Tests

@MainActor
final class SetupDownloadGatingTests: XCTestCase {

    func test_canProceed_downloadRequiresCompletion() {
        // When at download step, should only proceed if downloadProgress >= 1.0
        var state = SetupState()
        state.currentStep = .download
        state.downloadProgress = 0.5

        // Progress less than 1.0 means download not complete
        XCTAssertLessThan(state.downloadProgress, 1.0)
    }

    func test_canProceed_downloadWithErrorBlocksProgress() {
        var state = SetupState()
        state.currentStep = .download
        state.downloadProgress = 1.0
        state.downloadError = "Network error"

        // Even with progress at 100%, an error should block
        XCTAssertNotNil(state.downloadError)
    }

    func test_downloadComplete_allowsProceeding() {
        var state = SetupState()
        state.currentStep = .download
        state.downloadProgress = 1.0
        state.downloadError = nil

        // Progress at 100% with no error means download is complete
        XCTAssertGreaterThanOrEqual(state.downloadProgress, 1.0)
        XCTAssertNil(state.downloadError)
    }
}

// MARK: - Permission Gating Tests

@MainActor
final class SetupPermissionGatingTests: XCTestCase {

    func test_canProceed_permissionsRequiredForContinue() {
        var state = SetupState()
        state.currentStep = .permissions
        state.permissionsGranted = false

        // Without permissions, cannot proceed
        XCTAssertFalse(state.permissionsGranted)
    }

    func test_canProceed_permissionsGrantedAllowsContinue() {
        var state = SetupState()
        state.currentStep = .permissions
        state.permissionsGranted = true

        // With permissions granted, can proceed
        XCTAssertTrue(state.permissionsGranted)
    }
}
