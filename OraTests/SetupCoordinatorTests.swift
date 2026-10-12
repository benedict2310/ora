//
//  SetupCoordinatorTests.swift
//  OraTests
//
//  Focused tests for first-run setup state and coordinator behavior
//

import XCTest
@testable import Ora

// MARK: - Setup Step Tests

final class SetupStepTests: XCTestCase {

    func test_stepMappingAndNavigationRules_areStable() {
        let expected: [(SetupStep, Int, String, Bool)] = [
            (.welcome, 0, "Welcome", false),
            (.permissions, 1, "Permissions", true),
            (.modelExplanation, 2, "Models", true),
            (.download, 3, "Download", false),
            (.ready, 4, "Ready", false)
        ]

        XCTAssertEqual(SetupStep.allCases.count, expected.count)
        for (step, rawValue, title, canGoBack) in expected {
            XCTAssertEqual(step.rawValue, rawValue)
            XCTAssertEqual(step.title, title)
            XCTAssertEqual(step.canGoBack, canGoBack)
        }
    }
}

// MARK: - Setup State Tests

final class SetupStateTests: XCTestCase {

    func test_initialState_containsCompleteDefaults() {
        let state = SetupState()

        XCTAssertEqual(state.currentStep, .welcome)
        XCTAssertFalse(state.isComplete)
        XCTAssertFalse(state.permissionsGranted)
        XCTAssertFalse(state.skippedOptionalPermissions)
        XCTAssertEqual(state.downloadProgress, 0)
        XCTAssertNil(state.downloadingModel)
        XCTAssertNil(state.downloadError)
        XCTAssertEqual(state.primaryLLM, .recommendedLocalLLM())
        XCTAssertFalse(state.downloadWasCancelled)
        XCTAssertEqual(state.systemRAMGB, 0)
        XCTAssertEqual(state.recommendedModel, ModelIdentifier.recommendedLocalLLM().displayName)
    }

    func test_formatBytes_coversMegabyteAndGigabyteBoundaries() {
        XCTAssertEqual(SetupState.formatBytes(0), "0 MB")
        XCTAssertEqual(SetupState.formatBytes(500 * 1024 * 1024), "500 MB")
        XCTAssertEqual(SetupState.formatBytes(Int64(1024 * 1024 * 1024)), "1.0 GB")
        XCTAssertEqual(SetupState.formatBytes(Int64(1.5 * 1024 * 1024 * 1024)), "1.5 GB")
    }
}

// MARK: - Models State Tests

final class ModelsStateDownloadTrackingTests: XCTestCase {

    func test_initialState_andByteAggregates_areCorrect() {
        var state = ModelsState()
        XCTAssertFalse(state.isDownloading)
        XCTAssertEqual(state.overallDownloadSpeed, 0)
        XCTAssertNil(state.estimatedTimeRemainingSeconds)
        XCTAssertTrue(state.downloadProgress.isEmpty)

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
        XCTAssertEqual(state.formattedBytesDownloaded, "1.2 GB")
    }

    func test_formattedDownloadSpeed_coversThresholds() {
        var state = ModelsState()

        state.overallDownloadSpeed = 0.09 * 1024 * 1024
        XCTAssertEqual(state.formattedDownloadSpeed, "...")
        state.overallDownloadSpeed = 0.1001 * 1024 * 1024
        XCTAssertEqual(state.formattedDownloadSpeed, "0.1 MB/s")
        state.overallDownloadSpeed = 12.3 * 1024 * 1024
        XCTAssertEqual(state.formattedDownloadSpeed, "12.3 MB/s")
    }

    func test_formattedTimeRemaining_coversSecondMinuteAndHourRanges() {
        var state = ModelsState()

        state.estimatedTimeRemainingSeconds = 0
        XCTAssertNil(state.formattedTimeRemaining)
        state.estimatedTimeRemainingSeconds = 45
        XCTAssertEqual(state.formattedTimeRemaining, "~45s left")
        state.estimatedTimeRemainingSeconds = 120
        XCTAssertEqual(state.formattedTimeRemaining, "~2 min left")
        state.estimatedTimeRemainingSeconds = 3600
        XCTAssertEqual(state.formattedTimeRemaining, "~1h left")
        state.estimatedTimeRemainingSeconds = 3660
        XCTAssertEqual(state.formattedTimeRemaining, "~1h 1m left")
    }
}

// MARK: - Setup Coordinator Tests

@MainActor
final class SetupCoordinatorTests: XCTestCase {

    func test_sharedCoordinator_initializesSystemRecommendation() {
        let coordinator = SetupCoordinator.shared

        XCTAssertGreaterThan(coordinator.state.systemRAMGB, 0)
        XCTAssertEqual(coordinator.state.recommendedModel, ModelIdentifier.recommendedLocalLLM().displayName)
        XCTAssertEqual(coordinator.state.primaryLLM, .recommendedLocalLLM())
    }

    func test_resolvePrimaryLLM_coversPersistedAndFallbackBranches() {
        let cases: [(String, ModelIdentifier?, Bool, UInt64, ModelIdentifier)] = [
            ("first run retains supported vision model", .qwen35_4B_Vision, false, 32_000_000_000, .qwen35_4B_Vision),
            ("repair retains supported vision model", .qwen35_4B_Vision, true, 32_000_000_000, .qwen35_4B_Vision),
            ("repair falls back when vision model exceeds memory", .qwen35_4B_Vision, true, 8_000_000_000, .qwen3_4B),
            ("legacy model falls back to recommended model", .qwen3_4B, true, 32_000_000_000, .qwen35_4B_Vision),
            ("missing model uses low-memory recommendation", nil, false, 8_000_000_000, .qwen3_4B),
            ("supported eight billion model is retained", .qwen35_8B_Vision, true, 32_000_000_000, .qwen35_8B_Vision),
            ("unsupported thirty-two billion model falls back", .qwen35_32B_Vision, true, 32_000_000_000, .qwen35_4B_Vision)
        ]

        for (label, persistedLLM, isRepairFlow, totalRAMBytes, expected) in cases {
            XCTAssertEqual(
                SetupCoordinator.resolvePrimaryLLM(
                    persistedLLM: persistedLLM,
                    isRepairFlow: isRepairFlow,
                    totalRAMBytes: totalRAMBytes
                ),
                expected,
                label
            )
        }
    }

    func test_previousStep_movesBackOnlyFromNavigableSteps() {
        var state = SetupState()
        state.currentStep = .modelExplanation
        let coordinator = SetupCoordinator.makeForTesting(state: state)

        coordinator.previousStep()
        XCTAssertEqual(coordinator.state.currentStep, .permissions)

        var nonNavigableState = SetupState()
        nonNavigableState.currentStep = .download
        let nonNavigableCoordinator = SetupCoordinator.makeForTesting(state: nonNavigableState)
        nonNavigableCoordinator.previousStep()
        XCTAssertEqual(nonNavigableCoordinator.state.currentStep, .download)
    }

    func test_cancelDownloads_resetsDownloadStateAndReturnsToExplanation() {
        var state = SetupState()
        state.currentStep = .download
        state.downloadProgress = 0.75
        state.downloadingModel = "Parakeet ASR"
        state.downloadError = "Network error"
        let coordinator = SetupCoordinator.makeForTesting(state: state)

        coordinator.cancelDownloads()

        XCTAssertEqual(coordinator.state.currentStep, .modelExplanation)
        XCTAssertTrue(coordinator.state.downloadWasCancelled)
        XCTAssertEqual(coordinator.state.downloadProgress, 0)
        XCTAssertNil(coordinator.state.downloadError)
    }
}
