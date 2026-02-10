//
//  SetupViewsTests.swift
//  OraTests
//
//  Tests for setup flow SwiftUI views
//

import SwiftUI
import XCTest
@testable import Ora

@MainActor
final class SetupViewsTests: XCTestCase {

    func test_welcomeStepView_bodyBuilds() {
        var state = SetupState()
        state.systemRAMGB = 16
        state.recommendedModel = "Qwen 3 4B"

        let view = WelcomeStepView(state: state)
        _ = view.body
    }

    func test_systemInfoRow_bodyBuilds() {
        let view = SystemInfoRow(icon: "cpu", title: "System Memory", value: "16 GB RAM")
        _ = view.body
    }

    func test_permissionsStepView_bodyBuilds() {
        let coordinator = SetupCoordinator.makeForTesting(state: SetupState())
        let view = PermissionsStepView(coordinator: coordinator)
        _ = view.body
    }

    func test_permissionRow_bodyBuilds_forStatuses() {
        let granted = PermissionRow(type: .microphone, status: .authorized, onRequest: {})
        _ = granted.body

        let denied = PermissionRow(type: .calendar, status: .denied, onRequest: {})
        _ = denied.body

        let pending = PermissionRow(type: .contacts, status: .notDetermined, onRequest: {})
        _ = pending.body
    }

    func test_modelExplanationStepView_bodyBuilds() {
        let state = SetupState()
        let view = ModelExplanationStepView(state: state)
        _ = view.body
    }

    func test_downloadStepView_bodyBuilds_forStates() {
        // Test downloading state
        var downloadingSetupState = SetupState()
        downloadingSetupState.currentStep = .download
        downloadingSetupState.downloadProgress = 0.35
        downloadingSetupState.downloadingModel = "Parakeet ASR"

        var downloadingModelsState = ModelsState()
        downloadingModelsState.statuses = [
            .parakeetTDT: .downloading(progress: 0.35),
            .qwen3_4B: .notDownloaded,
            .kokoro: .notDownloaded
        ]
        downloadingModelsState.downloadProgress = [
            .parakeetTDT: ModelDownloadProgress(
                identifier: .parakeetTDT,
                bytesDownloaded: 200_000_000,
                totalBytes: 600_000_000
            )
        ]
        downloadingModelsState.isDownloading = true

        let downloadingView = DownloadStepView(
            setupState: downloadingSetupState,
            modelsState: downloadingModelsState
        )
        _ = downloadingView.body

        // Test complete state
        var completeSetupState = SetupState()
        completeSetupState.currentStep = .download
        completeSetupState.downloadProgress = 1.0

        var completeModelsState = ModelsState()
        completeModelsState.statuses = [
            .parakeetTDT: .ready,
            .qwen3_4B: .ready,
            .kokoro: .ready
        ]
        completeModelsState.downloadProgress = [
            .parakeetTDT: ModelDownloadProgress(
                identifier: .parakeetTDT,
                bytesDownloaded: 600_000_000,
                totalBytes: 600_000_000
            ),
            .qwen3_4B: ModelDownloadProgress(
                identifier: .qwen3_4B,
                bytesDownloaded: 2_500_000_000,
                totalBytes: 2_500_000_000
            ),
            .kokoro: ModelDownloadProgress(
                identifier: .kokoro,
                bytesDownloaded: 500_000_000,
                totalBytes: 500_000_000
            )
        ]

        let completeView = DownloadStepView(
            setupState: completeSetupState,
            modelsState: completeModelsState
        )
        _ = completeView.body

        // Test error state
        var errorSetupState = SetupState()
        errorSetupState.currentStep = .download
        errorSetupState.downloadProgress = 0.6
        errorSetupState.downloadError = "Network error"

        var errorModelsState = ModelsState()
        errorModelsState.statuses = [
            .parakeetTDT: .ready,
            .qwen3_4B: .failed("Network error"),
            .kokoro: .notDownloaded
        ]
        errorModelsState.downloadProgress = [
            .parakeetTDT: ModelDownloadProgress(
                identifier: .parakeetTDT,
                bytesDownloaded: 600_000_000,
                totalBytes: 600_000_000
            ),
            .qwen3_4B: ModelDownloadProgress(
                identifier: .qwen3_4B,
                bytesDownloaded: 1_500_000_000,
                totalBytes: 2_500_000_000
            )
        ]

        let errorView = DownloadStepView(
            setupState: errorSetupState,
            modelsState: errorModelsState
        )
        _ = errorView.body
    }

    func test_readyStepView_bodyBuilds() {
        let view = ReadyStepView()
        _ = view.body
    }

    func test_setupProgressView_bodyBuilds_forAllSteps() {
        for step in SetupStep.allCases {
            let view = SetupProgressView(currentStep: step)
            _ = view.body
        }
    }

    func test_setupNavigationView_helpers_coverAllSteps() {
        var baseState = SetupState()
        baseState.permissionsGranted = false
        baseState.downloadProgress = 0.5
        baseState.downloadError = nil

        XCTAssertEqual(SetupNavigationView.nextButtonTitle(for: .welcome), "Get Started")
        XCTAssertEqual(SetupNavigationView.nextButtonTitle(for: .permissions), "Continue")
        XCTAssertEqual(SetupNavigationView.nextButtonTitle(for: .modelExplanation), "Prepare Models")
        XCTAssertEqual(SetupNavigationView.nextButtonTitle(for: .download), "Continue")
        XCTAssertEqual(SetupNavigationView.nextButtonTitle(for: .ready), "Done")

        baseState.currentStep = .welcome
        XCTAssertTrue(SetupNavigationView.canProceed(for: baseState))

        baseState.currentStep = .permissions
        baseState.permissionsGranted = false
        XCTAssertFalse(SetupNavigationView.canProceed(for: baseState))

        baseState.permissionsGranted = true
        XCTAssertTrue(SetupNavigationView.canProceed(for: baseState))

        baseState.currentStep = .modelExplanation
        XCTAssertTrue(SetupNavigationView.canProceed(for: baseState))

        baseState.currentStep = .download
        baseState.downloadProgress = 0.9
        XCTAssertFalse(SetupNavigationView.canProceed(for: baseState))

        baseState.downloadProgress = 1.0
        baseState.downloadError = "Network error"
        XCTAssertFalse(SetupNavigationView.canProceed(for: baseState))

        baseState.downloadError = nil
        XCTAssertTrue(SetupNavigationView.canProceed(for: baseState))

        baseState.currentStep = .ready
        XCTAssertTrue(SetupNavigationView.canProceed(for: baseState))
    }

    func test_setupWindow_bodyBuilds_forAllSteps() {
        for step in SetupStep.allCases {
            let (setupState, _) = self.makeStates(for: step)
            let coordinator = SetupCoordinator.makeForTesting(state: setupState)
            let view = SetupWindow(coordinator: coordinator)
            _ = view.body
        }
    }

    private func makeStates(for step: SetupStep) -> (SetupState, ModelsState) {
        var setupState = SetupState()
        setupState.currentStep = step
        setupState.permissionsGranted = true
        setupState.downloadProgress = step == .download ? 0.4 : 1.0
        setupState.downloadError = nil
        setupState.downloadingModel = step == .download ? "Parakeet ASR" : nil

        var modelsState = ModelsState()
        if step == .download {
            modelsState.statuses = [
                .parakeetTDT: .downloading(progress: 0.4),
                .qwen3_4B: .notDownloaded,
                .kokoro: .notDownloaded
            ]
            modelsState.downloadProgress = [
                .parakeetTDT: ModelDownloadProgress(
                    identifier: .parakeetTDT,
                    bytesDownloaded: 240_000_000,
                    totalBytes: 600_000_000
                )
            ]
            modelsState.isDownloading = true
        } else {
            modelsState.statuses = [
                .parakeetTDT: .ready,
                .qwen3_4B: .ready,
                .kokoro: .ready
            ]
        }

        return (setupState, modelsState)
    }
}
