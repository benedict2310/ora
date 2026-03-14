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
    var openProviderSetupCallCount = 0
    var quitCallCount = 0

    func handlePreferences() {
        self.preferencesCallCount += 1
    }

    func handleOpenProviderSetup() {
        self.openProviderSetupCallCount += 1
    }

    func handleQuit() {
        self.quitCallCount += 1
    }
}

@MainActor
final class MockUpdateChecker: UpdateChecking {
    var canCheckForUpdates: Bool
    var checkCallCount = 0

    init(canCheckForUpdates: Bool) {
        self.canCheckForUpdates = canCheckForUpdates
    }

    func checkForUpdates() {
        self.checkCallCount += 1
    }
}

actor StatusBarCredentialStoreMock: CredentialStore {
    private var storage: [CloudProvider: String] = [:]

    func save(provider: CloudProvider, apiKey: String) throws {
        self.storage[provider] = apiKey
    }

    func retrieve(provider: CloudProvider) throws -> String? {
        return self.storage[provider]
    }

    func delete(provider: CloudProvider) throws {
        self.storage.removeValue(forKey: provider)
    }

    func hasCredential(for provider: CloudProvider) -> Bool {
        return self.storage[provider] != nil
    }
}

actor StatusBarDiscoveryServiceMock: OpenAIModelDiscovering {
    private var state: OpenAIModelDiscoveryState = .unavailable(.missingCredential)

    func fetchModelAvailability(forceRefresh: Bool) async -> OpenAIModelDiscoveryState {
        return self.state
    }
}

actor StatusBarCodexOAuthManagerMock: CodexOAuthManaging {
    private var credential: CodexOAuthCredential?

    func authorize() async throws -> CodexOAuthCredential {
        guard let credential else {
            throw CodexOAuthError.invalidTokenResponse("No credential")
        }
        return credential
    }

    func disconnect() async throws {
        self.credential = nil
    }

    func currentCredential() async throws -> CodexOAuthCredential? {
        return self.credential
    }

    func validCredentialIfAvailable() async throws -> CodexOAuthCredential? {
        return self.credential
    }

    func importCLIAuthIfNeeded() async {}
}

// MARK: - StatusBarController Tests

@MainActor
final class StatusBarControllerTests: XCTestCase {

    override func setUp() async throws {
        UserDefaults.standard.removeObject(forKey: "com.ora.selectedLLMProvider")
        UserDefaults.standard.removeObject(forKey: "com.ora.selectedOpenAIModel")
        UserDefaults.standard.removeObject(forKey: "com.ora.selectedOpenAIModelIdentifier")
        UserDefaults.standard.removeObject(forKey: "com.ora.openAI.discoveredModelIdentifiers")
        UserDefaults.standard.removeObject(forKey: "com.ora.openAI.discoveredModels")
    }

    override func tearDown() async throws {
        UserDefaults.standard.removeObject(forKey: "com.ora.selectedLLMProvider")
        UserDefaults.standard.removeObject(forKey: "com.ora.selectedOpenAIModel")
        UserDefaults.standard.removeObject(forKey: "com.ora.selectedOpenAIModelIdentifier")
        UserDefaults.standard.removeObject(forKey: "com.ora.openAI.discoveredModelIdentifiers")
        UserDefaults.standard.removeObject(forKey: "com.ora.openAI.discoveredModels")
        try await super.tearDown()
    }

    // MARK: - State Tests

    func test_initialState_isIdle() {
        let controller = self.makeController()
        XCTAssertEqual(controller.state, .idle)
        controller.shutdown()
    }

    func test_setState_updatesState() {
        let controller = self.makeController()
        controller.setState(.listening)
        XCTAssertEqual(controller.state, .listening)
        controller.shutdown()
    }

    func test_setState_sameState_noChange() {
        let controller = self.makeController()
        controller.setState(.idle)
        XCTAssertEqual(controller.state, .idle)
        controller.shutdown()
    }

    func test_errorState_hasMessage() {
        let controller = self.makeController()
        controller.setState(.error("Test error"))
        if case .error(let message) = controller.state {
            XCTAssertEqual(message, "Test error")
        } else {
            XCTFail("Expected error state")
        }
        controller.shutdown()
    }

    func test_allStates_areReachable() {
        let controller = self.makeController()

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
        let controller = self.makeController()
        let titles = controller.menuItemTitles

        XCTAssertTrue(titles.contains("LLM Model"), "Menu should contain LLM Model submenu")
        XCTAssertTrue(titles.contains("Preferences..."), "Menu should contain Preferences...")
        XCTAssertTrue(titles.contains("Check for Updates..."), "Menu should contain Check for Updates...")
        XCTAssertTrue(titles.contains("Conversation Mode"), "Menu should contain Conversation Mode")
        XCTAssertTrue(titles.contains("Quit Ora"), "Menu should contain Quit Ora")

        controller.shutdown()
    }

    func test_statusBarMenu_showsActiveProviderAndModel() async {
        UserDefaults.standard.selectedLLMProvider = .local
        UserDefaults.standard.selectedAnthropicModel = .sonnet
        UserDefaults.standard.selectedOpenAIModelIdentifier = OpenAIModel.preferredDefault.rawValue
        UserDefaults.standard.removeObject(forKey: "com.ora.openAI.discoveredModelIdentifiers")
        UserDefaults.standard.removeObject(forKey: "com.ora.openAI.discoveredModels")

        let controller = self.makeController()
        try? await Task.sleep(for: .milliseconds(80))
        controller.triggerMenuUpdate()

        let titles = controller.menuItemTitles
        let headerItems = titles.filter { $0.starts(with: "Local (On-Device): ") }
        XCTAssertEqual(headerItems.count, 1, "Submenu should show active provider and model")

        controller.shutdown()
    }

    func test_statusBarMenu_openAIWithoutCredential_showsSetUpConnection() async {
        UserDefaults.standard.removeObject(forKey: "com.ora.openAI.discoveredModelIdentifiers")
        UserDefaults.standard.removeObject(forKey: "com.ora.openAI.discoveredModels")

        let controller = self.makeController()
        try? await Task.sleep(for: .milliseconds(80))
        controller.triggerMenuUpdate()

        XCTAssertTrue(controller.hasSetUpConnectionMenuItem)

        controller.shutdown()
    }

    func test_statusBarMenu_modelStateNotificationAddsLargestLocalModelOption() async {
        let controller = self.makeController()

        var state = ModelsState()
        state.primaryLLM = .qwen35_32B_Vision
        state.statuses[.qwen35_4B_Vision] = .ready
        state.statuses[.qwen35_8B_Vision] = .ready
        state.statuses[.qwen35_32B_Vision] = .ready

        NotificationCenter.default.post(name: .modelStateDidChange, object: state)
        try? await Task.sleep(for: .milliseconds(50))

        XCTAssertTrue(
            controller.menuItemTitles.contains("Local: Qwen3 VL 32B"),
            "Menu should surface the largest ready local VL model after model-state updates"
        )

        controller.shutdown()
    }

    func test_menuKeyEquivalents_areCorrect() {
        let controller = self.makeController()
        let keyEquivalents = controller.menuItemKeyEquivalents

        XCTAssertEqual(keyEquivalents["Preferences..."], ",", "Preferences should have ',' shortcut")
        XCTAssertEqual(keyEquivalents["Quit Ora"], "q", "Quit should have 'q' shortcut")

        controller.shutdown()
    }

    // MARK: - Action Handler Tests

    func test_showPreferences_callsActionHandler() {
        let mockHandler = MockStatusBarActionHandler()
        let controller = self.makeController(actionHandler: mockHandler)

        XCTAssertEqual(mockHandler.preferencesCallCount, 0)
        controller.showPreferences()
        XCTAssertEqual(mockHandler.preferencesCallCount, 1)

        controller.shutdown()
    }

    func test_showPreferences_calledMultipleTimes_incrementsCount() {
        let mockHandler = MockStatusBarActionHandler()
        let controller = self.makeController(actionHandler: mockHandler)

        controller.showPreferences()
        controller.showPreferences()
        controller.showPreferences()

        XCTAssertEqual(mockHandler.preferencesCallCount, 3)

        controller.shutdown()
    }

    func test_setUpConnection_routesToProvidersTab() {
        let mockHandler = MockStatusBarActionHandler()
        let controller = self.makeController(actionHandler: mockHandler)

        XCTAssertEqual(mockHandler.openProviderSetupCallCount, 0)
        controller.simulateSetUpConnectionClick()
        XCTAssertEqual(mockHandler.openProviderSetupCallCount, 1)

        controller.shutdown()
    }

    func test_checkForUpdates_callsUpdateChecker() {
        let updateChecker = MockUpdateChecker(canCheckForUpdates: true)
        let controller = StatusBarController(updateChecker: updateChecker)

        XCTAssertEqual(updateChecker.checkCallCount, 0)
        controller.simulateCheckForUpdates()
        XCTAssertEqual(updateChecker.checkCallCount, 1)

        controller.shutdown()
    }

    func test_checkForUpdatesMenuItemEnabled_reflectsUpdaterState() {
        let updateChecker = MockUpdateChecker(canCheckForUpdates: false)
        let controller = StatusBarController(updateChecker: updateChecker)

        controller.triggerMenuUpdate()
        XCTAssertEqual(controller.checkForUpdatesMenuItemEnabled, false)

        updateChecker.canCheckForUpdates = true
        controller.triggerMenuUpdate()
        XCTAssertEqual(controller.checkForUpdatesMenuItemEnabled, true)

        controller.shutdown()
    }

    // MARK: - Shutdown Tests

    func test_shutdown_canBeCalledSafely() {
        let controller = self.makeController()

        // Should not crash
        controller.shutdown()

        // Should be safe to call multiple times
        controller.shutdown()
    }

    func test_shutdown_clearsMenuItems() {
        let controller = self.makeController()
        XCTAssertFalse(controller.menuItemTitles.isEmpty, "Menu should have items before shutdown")

        controller.shutdown()

        XCTAssertTrue(controller.menuItemTitles.isEmpty, "Menu should be empty after shutdown")
    }

    // MARK: - Conversation Mode Tests

    func test_conversationModeMenuItemState_reflectsSetting() {
        let controller = self.makeController()

        // Get initial state from persistence
        let initialEnabled = PersistenceManager.shared.settings.conversationModeEnabled
        let expectedState: NSControl.StateValue = initialEnabled ? .on : .off

        XCTAssertEqual(controller.conversationModeMenuItemState, expectedState)

        controller.shutdown()
    }

    func test_simulateConversationModeToggle_togglesSetting() {
        let controller = self.makeController()

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
        let controller = self.makeController()

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
        let controller = self.makeController()

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
        let controller = self.makeController()
        XCTAssertNotNil(controller.conversationModeMenuItemState)

        controller.shutdown()

        XCTAssertNil(controller.conversationModeMenuItemState)
    }

    // MARK: - Helpers

    private func makeController(
        actionHandler: StatusBarActionHandler? = nil,
        canCheckForUpdates: Bool = true
    ) -> StatusBarController {
        let updateChecker = MockUpdateChecker(canCheckForUpdates: canCheckForUpdates)
        let credentialStore = StatusBarCredentialStoreMock()
        let codexOAuthManager = StatusBarCodexOAuthManagerMock()
        let providerManager = LLMProviderManager(
            credentialStore: credentialStore,
            codexOAuthManager: codexOAuthManager
        )
        let discoveryService = StatusBarDiscoveryServiceMock()
        let viewModel = ProviderPreferencesViewModel(
            credentialStore: credentialStore,
            providerManager: providerManager,
            codexOAuthManager: codexOAuthManager,
            modelDiscoveryService: discoveryService
        )
        return StatusBarController(
            actionHandler: actionHandler,
            updateChecker: updateChecker,
            providerPreferencesViewModel: viewModel
        )
    }
}
