//
//  StatusBarControllerTests.swift
//  OraTests
//
//  Unit tests for StatusBarController
//

import XCTest
@testable import Ora

// MARK: - Mock Action Handler

@MainActor
final class MockStatusBarActionHandler: StatusBarActionHandler {
    var preferencesCallCount = 0
    var quitCallCount = 0

    func handlePreferences() {
        self.preferencesCallCount += 1
    }

    func handleQuit() {
        self.quitCallCount += 1
    }
}

// MARK: - StatusBarController Tests

@MainActor
final class StatusBarControllerTests: XCTestCase {

    // MARK: - State Tests

    func test_initialState_isIdle() {
        let controller = StatusBarController()
        XCTAssertEqual(controller.state, .idle)
        controller.shutdown()
    }

    func test_setState_updatesState() {
        let controller = StatusBarController()
        controller.setState(.listening)
        XCTAssertEqual(controller.state, .listening)
        controller.shutdown()
    }

    func test_setState_sameState_noChange() {
        let controller = StatusBarController()
        controller.setState(.idle)
        XCTAssertEqual(controller.state, .idle)
        controller.shutdown()
    }

    func test_errorState_hasMessage() {
        let controller = StatusBarController()
        controller.setState(.error("Test error"))
        if case .error(let message) = controller.state {
            XCTAssertEqual(message, "Test error")
        } else {
            XCTFail("Expected error state")
        }
        controller.shutdown()
    }

    func test_allStates_areReachable() {
        let controller = StatusBarController()

        controller.setState(.idle)
        XCTAssertEqual(controller.state, .idle)

        controller.setState(.listening)
        XCTAssertEqual(controller.state, .listening)

        controller.setState(.thinking)
        XCTAssertEqual(controller.state, .thinking)

        controller.setState(.speaking)
        XCTAssertEqual(controller.state, .speaking)

        controller.setState(.error("Error message"))
        if case .error = controller.state {
            // Pass
        } else {
            XCTFail("Expected error state")
        }

        controller.setState(.setupRequired)
        XCTAssertEqual(controller.state, .setupRequired)

        controller.shutdown()
    }

    func test_stateEquality() {
        XCTAssertEqual(StatusBarController.State.idle, StatusBarController.State.idle)
        XCTAssertEqual(StatusBarController.State.listening, StatusBarController.State.listening)
        XCTAssertNotEqual(StatusBarController.State.idle, StatusBarController.State.listening)

        XCTAssertEqual(
            StatusBarController.State.error("same"),
            StatusBarController.State.error("same")
        )

        XCTAssertNotEqual(
            StatusBarController.State.error("one"),
            StatusBarController.State.error("two")
        )
    }

    // MARK: - Icon Mapping Tests

    func test_symbolName_idle_returnsCircle() {
        XCTAssertEqual(StatusBarController.symbolName(for: .idle), "circle")
    }

    func test_symbolName_listening_returnsCircleFill() {
        XCTAssertEqual(StatusBarController.symbolName(for: .listening), "circle.fill")
    }

    func test_symbolName_thinking_returnsCircleDotted() {
        XCTAssertEqual(StatusBarController.symbolName(for: .thinking), "circle.dotted")
    }

    func test_symbolName_speaking_returnsSpeakerWave() {
        XCTAssertEqual(StatusBarController.symbolName(for: .speaking), "speaker.wave.2.fill")
    }

    func test_symbolName_error_returnsExclamationTriangle() {
        XCTAssertEqual(StatusBarController.symbolName(for: .error("any")), "exclamationmark.triangle")
    }

    func test_symbolName_setupRequired_returnsArrowDownCircle() {
        XCTAssertEqual(StatusBarController.symbolName(for: .setupRequired), "arrow.down.circle")
    }

    // MARK: - Asset Name Tests

    func test_assetName_idle_returnsMenubarIdle() {
        XCTAssertEqual(StatusBarController.assetName(for: .idle), "menubar-idle")
    }

    func test_assetName_listening_returnsMenubarListening() {
        XCTAssertEqual(StatusBarController.assetName(for: .listening), "menubar-listening")
    }

    func test_assetName_thinking_returnsMenubarThinking() {
        XCTAssertEqual(StatusBarController.assetName(for: .thinking), "menubar-thinking")
    }

    func test_assetName_speaking_returnsMenubarSpeaking() {
        XCTAssertEqual(StatusBarController.assetName(for: .speaking), "menubar-speaking")
    }

    func test_assetName_error_returnsMenubarError() {
        XCTAssertEqual(StatusBarController.assetName(for: .error("any")), "menubar-error")
    }

    func test_assetName_setupRequired_returnsMenubarSetup() {
        XCTAssertEqual(StatusBarController.assetName(for: .setupRequired), "menubar-setup")
    }

    // MARK: - Menu Construction Tests

    func test_menuItemTitles_containsPreferencesAndQuit() {
        let controller = StatusBarController()
        let titles = controller.menuItemTitles

        XCTAssertTrue(titles.contains("Preferences..."), "Menu should contain Preferences...")
        XCTAssertTrue(titles.contains("Conversation Mode"), "Menu should contain Conversation Mode")
        XCTAssertTrue(titles.contains("Quit Ora"), "Menu should contain Quit Ora")
        XCTAssertEqual(titles.count, 3, "Menu should have exactly 3 non-separator items")

        controller.shutdown()
    }

    func test_menuKeyEquivalents_areCorrect() {
        let controller = StatusBarController()
        let keyEquivalents = controller.menuItemKeyEquivalents

        XCTAssertEqual(keyEquivalents["Preferences..."], ",", "Preferences should have ',' shortcut")
        XCTAssertEqual(keyEquivalents["Quit Ora"], "q", "Quit should have 'q' shortcut")

        controller.shutdown()
    }

    // MARK: - Action Handler Tests

    func test_showPreferences_callsActionHandler() {
        let mockHandler = MockStatusBarActionHandler()
        let controller = StatusBarController(actionHandler: mockHandler)

        XCTAssertEqual(mockHandler.preferencesCallCount, 0)
        controller.showPreferences()
        XCTAssertEqual(mockHandler.preferencesCallCount, 1)

        controller.shutdown()
    }

    func test_showPreferences_calledMultipleTimes_incrementsCount() {
        let mockHandler = MockStatusBarActionHandler()
        let controller = StatusBarController(actionHandler: mockHandler)

        controller.showPreferences()
        controller.showPreferences()
        controller.showPreferences()

        XCTAssertEqual(mockHandler.preferencesCallCount, 3)

        controller.shutdown()
    }

    // MARK: - Shutdown Tests

    func test_shutdown_canBeCalledSafely() {
        let controller = StatusBarController()

        // Should not crash
        controller.shutdown()

        // Should be safe to call multiple times
        controller.shutdown()
    }

    func test_shutdown_clearsMenuItems() {
        let controller = StatusBarController()
        XCTAssertFalse(controller.menuItemTitles.isEmpty, "Menu should have items before shutdown")

        controller.shutdown()

        XCTAssertTrue(controller.menuItemTitles.isEmpty, "Menu should be empty after shutdown")
    }

    // MARK: - Conversation Mode Tests

    func test_conversationModeMenuItemState_reflectsSetting() {
        let controller = StatusBarController()

        // Get initial state from persistence
        let initialEnabled = PersistenceManager.shared.settings.conversationModeEnabled
        let expectedState: NSControl.StateValue = initialEnabled ? .on : .off

        XCTAssertEqual(controller.conversationModeMenuItemState, expectedState)

        controller.shutdown()
    }

    func test_simulateConversationModeToggle_togglesSetting() {
        let controller = StatusBarController()

        // Get initial state
        let initialEnabled = PersistenceManager.shared.settings.conversationModeEnabled

        // Toggle
        controller.simulateConversationModeToggle()

        // Verify setting changed
        let newEnabled = PersistenceManager.shared.settings.conversationModeEnabled
        XCTAssertNotEqual(initialEnabled, newEnabled, "Setting should toggle")

        // Verify menu item state updated
        let expectedState: NSControl.StateValue = newEnabled ? .on : .off
        XCTAssertEqual(controller.conversationModeMenuItemState, expectedState)

        // Toggle back to restore original state
        controller.simulateConversationModeToggle()
        XCTAssertEqual(PersistenceManager.shared.settings.conversationModeEnabled, initialEnabled)

        controller.shutdown()
    }

    func test_simulateConversationModeToggle_multipleTimes_alternatesState() {
        let controller = StatusBarController()

        let initial = PersistenceManager.shared.settings.conversationModeEnabled

        controller.simulateConversationModeToggle()
        XCTAssertEqual(PersistenceManager.shared.settings.conversationModeEnabled, !initial)

        controller.simulateConversationModeToggle()
        XCTAssertEqual(PersistenceManager.shared.settings.conversationModeEnabled, initial)

        controller.simulateConversationModeToggle()
        XCTAssertEqual(PersistenceManager.shared.settings.conversationModeEnabled, !initial)

        // Restore original
        if PersistenceManager.shared.settings.conversationModeEnabled != initial {
            controller.simulateConversationModeToggle()
        }

        controller.shutdown()
    }

    func test_triggerMenuUpdate_updatesMenuItemState() {
        let controller = StatusBarController()

        // Change the setting directly via PersistenceManager
        let initialEnabled = PersistenceManager.shared.settings.conversationModeEnabled
        PersistenceManager.shared.updateSettings { settings in
            settings.conversationModeEnabled = !initialEnabled
        }

        // Trigger menu update
        controller.triggerMenuUpdate()

        // Verify menu item state matches new setting
        let expectedState: NSControl.StateValue = !initialEnabled ? .on : .off
        XCTAssertEqual(controller.conversationModeMenuItemState, expectedState)

        // Restore original
        PersistenceManager.shared.updateSettings { settings in
            settings.conversationModeEnabled = initialEnabled
        }

        controller.shutdown()
    }

    func test_conversationModeMenuItemState_afterShutdown_isNil() {
        let controller = StatusBarController()
        XCTAssertNotNil(controller.conversationModeMenuItemState)

        controller.shutdown()

        XCTAssertNil(controller.conversationModeMenuItemState)
    }
}
