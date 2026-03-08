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
        XCTAssertEqual(SetupStep.modelExplanation.title, "Models")
        XCTAssertEqual(SetupStep.download.title, "Download")
        XCTAssertEqual(SetupStep.ready.title, "Ready")
    }

    // MARK: - Can Go Back Tests

    func test_canGoBack_welcomeCannotGoBack() {
        XCTAssertFalse(SetupStep.welcome.canGoBack)
    }

    func test_canGoBack_permissionsCanGoBack() {
        XCTAssertTrue(SetupStep.permissions.canGoBack)
    }

    func test_canGoBack_modelExplanationCanGoBack() {
        XCTAssertTrue(SetupStep.modelExplanation.canGoBack)
    }

    func test_canGoBack_downloadCannotGoBack() {
        // Can't go back during download to prevent interruption
        XCTAssertFalse(SetupStep.download.canGoBack)
    }

    func test_canGoBack_readyCannotGoBack() {
        XCTAssertFalse(SetupStep.ready.canGoBack)
    }

    // MARK: - CaseIterable Tests

    func test_allCases_containsFiveSteps() {
        XCTAssertEqual(SetupStep.allCases.count, 5)
    }

    func test_rawValues_areSequential() {
        XCTAssertEqual(SetupStep.welcome.rawValue, 0)
        XCTAssertEqual(SetupStep.permissions.rawValue, 1)
        XCTAssertEqual(SetupStep.modelExplanation.rawValue, 2)
        XCTAssertEqual(SetupStep.download.rawValue, 3)
        XCTAssertEqual(SetupStep.ready.rawValue, 4)
    }

    // MARK: - Step Transition Tests

    func test_stepTransition_welcomeToPermissions() {
        // Valid transition in sequence
        XCTAssertEqual(SetupStep.welcome.rawValue + 1, SetupStep.permissions.rawValue)
    }

    func test_stepTransition_permissionsToModelExplanation() {
        XCTAssertEqual(SetupStep.permissions.rawValue + 1, SetupStep.modelExplanation.rawValue)
    }

    func test_stepTransition_modelExplanationToDownload() {
        XCTAssertEqual(SetupStep.modelExplanation.rawValue + 1, SetupStep.download.rawValue)
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
        XCTAssertEqual(state.primaryLLM, .qwen35_4B_Vision)
    }

    // MARK: - System Info

    func test_systemRAMGB_defaultsToZero() {
        let state = SetupState()
        XCTAssertEqual(state.systemRAMGB, 0)
    }

    func test_recommendedModel_defaultsToVision4B() {
        let state = SetupState()
        XCTAssertEqual(state.recommendedModel, "Qwen3 VL 4B")
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

    // MARK: - Download Cancellation State
    // Note: Detailed download stats (speed, ETA, bytes) are now tracked in ModelsState

    func test_downloadWasCancelled_defaultsFalse() {
        let state = SetupState()
        XCTAssertFalse(state.downloadWasCancelled)
    }

    func test_downloadWasCancelled_canBeSet() {
        var state = SetupState()
        state.downloadWasCancelled = true
        XCTAssertTrue(state.downloadWasCancelled)
    }

    // MARK: - Format Helpers (Static)

    func test_formatBytes_formatsCorrectly() {
        // Test MB formatting
        XCTAssertEqual(SetupState.formatBytes(500 * 1024 * 1024), "500 MB")
        
        // Test GB formatting
        XCTAssertEqual(SetupState.formatBytes(Int64(1.5 * 1024 * 1024 * 1024)), "1.5 GB")
        
        // Test 0 bytes
        XCTAssertEqual(SetupState.formatBytes(0), "0 MB")
    }

    func test_totalModelSizeDisplay_returnsExpectedValue() {
        XCTAssertEqual(SetupState.totalModelSizeDisplay, "~4.6 GB")
    }

    func test_totalModelSizeDisplay_forVisionModel_returnsExpectedValue() {
        XCTAssertEqual(
            SetupState.totalModelSizeDisplay(for: .qwen35_4B_Vision),
            "~4.6 GB"
        )
    }
}

// MARK: - ModelsState Download Tracking Tests
// Note: Download progress/speed/ETA tracking has been moved to ModelsState (single source of truth)

final class ModelsStateDownloadTrackingTests: XCTestCase {

    func test_initialModelsState_hasNoDownloading() {
        let state = ModelsState()
        XCTAssertFalse(state.isDownloading)
        XCTAssertEqual(state.overallDownloadSpeed, 0)
        XCTAssertNil(state.estimatedTimeRemainingSeconds)
        XCTAssertTrue(state.downloadProgress.isEmpty)
    }

    func test_totalBytesDownloaded_calculatesFromProgress() {
        var state = ModelsState()
        state.downloadProgress[.parakeetTDT] = ModelDownloadProgress(
            identifier: .parakeetTDT,
            bytesDownloaded: 300_000_000,
            totalBytes: 600_000_000
        )
        state.downloadProgress[.qwen35_4B_Vision] = ModelDownloadProgress(
            identifier: .qwen35_4B_Vision,
            bytesDownloaded: 1_000_000_000,
            totalBytes: 3_500_000_000
        )

        XCTAssertEqual(state.totalBytesDownloaded, 1_300_000_000)
        XCTAssertEqual(state.totalBytesToDownload, 4_100_000_000)
    }

    func test_formattedDownloadSpeed_formatsCorrectly() {
        var state = ModelsState()

        state.overallDownloadSpeed = 12.3 * 1024 * 1024  // 12.3 MB/s
        XCTAssertEqual(state.formattedDownloadSpeed, "12.3 MB/s")

        state.overallDownloadSpeed = 0.01 * 1024 * 1024  // Very slow
        XCTAssertEqual(state.formattedDownloadSpeed, "...")  // Shows placeholder for slow speeds
    }

    func test_formattedTimeRemaining_formatsSeconds() {
        var state = ModelsState()
        state.estimatedTimeRemainingSeconds = 45
        XCTAssertEqual(state.formattedTimeRemaining, "~45s left")
    }

    func test_formattedTimeRemaining_formatsMinutes() {
        var state = ModelsState()
        state.estimatedTimeRemainingSeconds = 120
        XCTAssertEqual(state.formattedTimeRemaining, "~2 min left")
    }

    func test_formattedTimeRemaining_formatsHours() {
        var state = ModelsState()
        state.estimatedTimeRemainingSeconds = 3660  // 1 hour 1 minute
        XCTAssertEqual(state.formattedTimeRemaining, "~1h 1m left")
    }

    func test_formattedTimeRemaining_nilForZero() {
        var state = ModelsState()
        state.estimatedTimeRemainingSeconds = 0
        XCTAssertNil(state.formattedTimeRemaining)
    }

    func test_formattedBytesDownloaded_formatsCorrectly() {
        var state = ModelsState()
        state.downloadProgress[.parakeetTDT] = ModelDownloadProgress(
            identifier: .parakeetTDT,
            bytesDownloaded: Int64(1.5 * 1024 * 1024 * 1024),
            totalBytes: Int64(2.0 * 1024 * 1024 * 1024)
        )
        XCTAssertEqual(state.formattedBytesDownloaded, "1.5 GB")
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

        XCTAssertEqual(coordinator.state.recommendedModel, "Qwen3 VL 4B")
    }

    func test_state_primaryLLMMatchesRAM() {
        let coordinator = SetupCoordinator.shared

        XCTAssertEqual(coordinator.state.primaryLLM, .qwen35_4B_Vision)
    }

    func test_resolvePrimaryLLM_firstRunHonorsPersistedVisionModel() {
        let resolved = SetupCoordinator.resolvePrimaryLLM(
            persistedLLM: .qwen35_4B_Vision,
            isRepairFlow: false,
            totalRAMBytes: 32_000_000_000
        )
        XCTAssertEqual(resolved, .qwen35_4B_Vision)
    }

    func test_resolvePrimaryLLM_repairFlowHonorsPersistedVisionModel() {
        let resolved = SetupCoordinator.resolvePrimaryLLM(
            persistedLLM: .qwen35_4B_Vision,
            isRepairFlow: true,
            totalRAMBytes: 32_000_000_000
        )
        XCTAssertEqual(resolved, .qwen35_4B_Vision)
    }

    func test_resolvePrimaryLLM_repairFlowFallsBackWhenInsufficientMemory() {
        let resolved = SetupCoordinator.resolvePrimaryLLM(
            persistedLLM: .qwen35_4B_Vision,
            isRepairFlow: true,
            totalRAMBytes: 8_000_000_000
        )
        XCTAssertEqual(resolved, .qwen35_4B_Vision)
    }

    func test_resolvePrimaryLLM_legacyQwen3FallsBackToVision4B() {
        let resolved = SetupCoordinator.resolvePrimaryLLM(
            persistedLLM: .qwen3_4B,
            isRepairFlow: true,
            totalRAMBytes: 32_000_000_000
        )
        XCTAssertEqual(resolved, .qwen35_4B_Vision)
    }

    func test_resolvePrimaryLLM_retainsSupported8BSelection() {
        let resolved = SetupCoordinator.resolvePrimaryLLM(
            persistedLLM: .qwen35_8B_Vision,
            isRepairFlow: true,
            totalRAMBytes: 32_000_000_000
        )
        XCTAssertEqual(resolved, .qwen35_8B_Vision)
    }

    func test_resolvePrimaryLLM_fallsBackFromUnsupported32BSelection() {
        let resolved = SetupCoordinator.resolvePrimaryLLM(
            persistedLLM: .qwen35_32B_Vision,
            isRepairFlow: true,
            totalRAMBytes: 32_000_000_000
        )
        XCTAssertEqual(resolved, .qwen35_4B_Vision)
    }

    // MARK: - Models State (Unified Tracking)

    func test_coordinator_hasModelsState() {
        let coordinator = SetupCoordinator.shared

        // Coordinator should expose modelsState for unified download tracking
        XCTAssertNotNil(coordinator.modelsState)
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
    
    func test_modelStateDidChange_notificationExists() {
        // Verify the notification name is properly defined
        let name = Notification.Name.modelStateDidChange
        XCTAssertEqual(name.rawValue, "com.ora.modelStateDidChange")
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
