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

    func test_downloadStepView_bodyBuilds_forStates() {
        var downloadingState = SetupState()
        downloadingState.currentStep = .download
        downloadingState.downloadProgress = 0.35
        downloadingState.downloadingModel = "Parakeet ASR"
        downloadingState.modelProgresses = [
            .parakeetTDT: 0.35,
            .qwen3_4B: 0.1,
            .kokoro: 0
        ]
        let downloadingView = DownloadStepView(state: downloadingState, onRetry: {})
        _ = downloadingView.body

        var completeState = SetupState()
        completeState.currentStep = .download
        completeState.downloadProgress = 1.0
        completeState.modelProgresses = [
            .parakeetTDT: 1.0,
            .qwen3_4B: 1.0,
            .kokoro: 1.0
        ]
        let completeView = DownloadStepView(state: completeState, onRetry: {})
        _ = completeView.body

        var errorState = SetupState()
        errorState.currentStep = .download
        errorState.downloadProgress = 0.6
        errorState.downloadError = "Network error"
        errorState.modelProgresses = [
            .parakeetTDT: 0.6,
            .qwen3_4B: 0.3,
            .kokoro: 0.0
        ]
        let errorView = DownloadStepView(state: errorState, onRetry: {})
        _ = errorView.body
    }

    func test_modelDownloadRow_bodyBuilds_forProgressStates() {
        let empty = ModelDownloadRow(name: "Model", size: "~1 GB", progress: 0)
        _ = empty.body

        let partial = ModelDownloadRow(name: "Model", size: "~1 GB", progress: 0.4)
        _ = partial.body

        let complete = ModelDownloadRow(name: "Model", size: "~1 GB", progress: 1.0)
        _ = complete.body
    }

    func test_readyStepView_bodyBuilds() {
        let view = ReadyStepView()
        _ = view.body
    }

    func test_tutorialStep_bodyBuilds() {
        let view = TutorialStep(number: 1, icon: "keyboard", title: "Press", description: "Option+Space")
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
        XCTAssertEqual(SetupNavigationView.nextButtonTitle(for: .download), "Continue")
        XCTAssertEqual(SetupNavigationView.nextButtonTitle(for: .ready), "Done")

        baseState.currentStep = .welcome
        XCTAssertTrue(SetupNavigationView.canProceed(for: baseState))

        baseState.currentStep = .permissions
        baseState.permissionsGranted = false
        XCTAssertFalse(SetupNavigationView.canProceed(for: baseState))

        baseState.permissionsGranted = true
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
            let coordinator = SetupCoordinator.makeForTesting(state: self.makeState(for: step))
            let view = SetupWindow(coordinator: coordinator)
            _ = view.body
        }
    }

    private func makeState(for step: SetupStep) -> SetupState {
        var state = SetupState()
        state.currentStep = step
        state.permissionsGranted = true
        state.downloadProgress = step == .download ? 0.4 : 1.0
        state.downloadError = nil
        state.downloadingModel = step == .download ? "Parakeet ASR" : nil
        state.modelProgresses = [
            .parakeetTDT: step == .download ? 0.4 : 1.0,
            .qwen3_4B: step == .download ? 0.2 : 1.0,
            .kokoro: step == .download ? 0.0 : 1.0
        ]
        return state
    }
}
