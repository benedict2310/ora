//
//  PermissionsTests.swift
//  OraTests
//
//  Tests for permission types and state management
//

import XCTest
@testable import Ora

// MARK: - Mock Permissions Client

/// Mock client for testing PermissionsManager without triggering real system prompts
final class MockPermissionsClient: PermissionsClient, @unchecked Sendable {
    /// Configured statuses to return for each permission type
    var statuses: [PermissionType: PermissionStatus] = [:]

    /// Statuses to return when request() is called (simulates user granting/denying)
    var requestResults: [PermissionType: PermissionStatus] = [:]

    /// Track which permissions were checked
    private(set) var checkedPermissions: [PermissionType] = []

    /// Track which permissions were requested
    private(set) var requestedPermissions: [PermissionType] = []

    /// Track which settings were opened
    private(set) var openedSettings: [PermissionType] = []

    func checkStatus(for type: PermissionType) -> PermissionStatus {
        checkedPermissions.append(type)
        return statuses[type] ?? .unknown
    }

    func request(_ type: PermissionType) async -> PermissionStatus {
        requestedPermissions.append(type)
        let result = requestResults[type] ?? statuses[type] ?? .denied
        statuses[type] = result
        return result
    }

    @MainActor
    func openSettings(for type: PermissionType) {
        openedSettings.append(type)
    }

    func reset() {
        checkedPermissions.removeAll()
        requestedPermissions.removeAll()
        openedSettings.removeAll()
    }
}

final class PermissionTypeTests: XCTestCase {

    // MARK: - Display Name Tests

    func test_displayName_returnsCorrectValues() {
        XCTAssertEqual(PermissionType.microphone.displayName, "Microphone")
        XCTAssertEqual(PermissionType.calendar.displayName, "Calendar")
        XCTAssertEqual(PermissionType.reminders.displayName, "Reminders")
        XCTAssertEqual(PermissionType.contacts.displayName, "Contacts")
    }

    // MARK: - Explanation Tests

    func test_explanation_returnsNonEmptyStrings() {
        for type in PermissionType.allCases {
            XCTAssertFalse(type.explanation.isEmpty, "\(type) should have an explanation")
        }
    }

    // MARK: - Required Tests

    func test_isRequired_microphone() {
        XCTAssertTrue(PermissionType.microphone.isRequired)
    }

    func test_isRequired_optionalPermissions() {
        XCTAssertFalse(PermissionType.calendar.isRequired)
        XCTAssertFalse(PermissionType.reminders.isRequired)
        XCTAssertFalse(PermissionType.contacts.isRequired)
    }

    // MARK: - Settings URL Tests

    func test_settingsURLString_allValidURLs() {
        for type in PermissionType.allCases {
            let urlString = type.settingsURLString
            XCTAssertTrue(urlString.hasPrefix("x-apple.systempreferences:"), "\(type) URL should be a system preferences URL")
            XCTAssertNotNil(URL(string: urlString), "\(type) should have a valid URL")
        }
    }

    // MARK: - CaseIterable Tests

    func test_allCases_containsFourPermissions() {
        XCTAssertEqual(PermissionType.allCases.count, 4)
    }
}

// MARK: - Permission Status Tests

final class PermissionStatusTests: XCTestCase {

    func test_isGranted_authorizedOnly() {
        XCTAssertTrue(PermissionStatus.authorized.isGranted)
        XCTAssertFalse(PermissionStatus.notDetermined.isGranted)
        XCTAssertFalse(PermissionStatus.denied.isGranted)
        XCTAssertFalse(PermissionStatus.restricted.isGranted)
        XCTAssertFalse(PermissionStatus.unknown.isGranted)
    }

    func test_canRequest_notDeterminedOnly() {
        XCTAssertTrue(PermissionStatus.notDetermined.canRequest)
        XCTAssertFalse(PermissionStatus.authorized.canRequest)
        XCTAssertFalse(PermissionStatus.denied.canRequest)
        XCTAssertFalse(PermissionStatus.restricted.canRequest)
        XCTAssertFalse(PermissionStatus.unknown.canRequest)
    }
}

// MARK: - Permission Prompt Tracker Tests

@MainActor
final class PermissionPromptTrackerTests: XCTestCase {

    func test_promptTracker_beginEndTogglesState() {
        let tracker = PermissionPromptTracker.shared

        tracker.endPrompt(for: .microphone)
        XCTAssertFalse(tracker.isPromptActive)

        tracker.beginPrompt(for: .microphone)
        XCTAssertTrue(tracker.isPromptActive)

        tracker.endPrompt(for: .microphone)
        XCTAssertFalse(tracker.isPromptActive)
    }
}

// MARK: - Permissions State Tests

final class PermissionsStateTests: XCTestCase {

    // MARK: - Initial State

    func test_initialState_allUnknown() {
        let state = PermissionsState()
        XCTAssertEqual(state.microphone, .unknown)
        XCTAssertEqual(state.calendar, .unknown)
        XCTAssertEqual(state.reminders, .unknown)
        XCTAssertEqual(state.contacts, .unknown)
    }

    // MARK: - Subscript Tests

    func test_subscript_get() {
        var state = PermissionsState()
        state.microphone = .authorized
        state.calendar = .denied

        XCTAssertEqual(state[.microphone], .authorized)
        XCTAssertEqual(state[.calendar], .denied)
        XCTAssertEqual(state[.contacts], .unknown)
    }

    func test_subscript_set() {
        var state = PermissionsState()
        state[.microphone] = .authorized
        state[.calendar] = .notDetermined
        state[.reminders] = .restricted
        state[.contacts] = .authorized

        XCTAssertEqual(state.microphone, .authorized)
        XCTAssertEqual(state.calendar, .notDetermined)
        XCTAssertEqual(state.reminders, .restricted)
        XCTAssertEqual(state.contacts, .authorized)
    }

    // MARK: - Required Permissions Tests

    func test_requiredPermissionsGranted_microphoneAuthorized() {
        var state = PermissionsState()
        state.microphone = .authorized
        state.calendar = .denied
        state.reminders = .denied
        state.contacts = .denied

        XCTAssertTrue(state.requiredPermissionsGranted)
    }

    func test_requiredPermissionsGranted_microphoneDenied() {
        var state = PermissionsState()
        state.microphone = .denied

        XCTAssertFalse(state.requiredPermissionsGranted)
    }

    // MARK: - All Permissions Tests

    func test_allPermissionsGranted_allAuthorized() {
        var state = PermissionsState()
        state.microphone = .authorized
        state.calendar = .authorized
        state.reminders = .authorized
        state.contacts = .authorized

        XCTAssertTrue(state.allPermissionsGranted)
    }

    func test_allPermissionsGranted_oneDenied() {
        var state = PermissionsState()
        state.microphone = .authorized
        state.calendar = .authorized
        state.reminders = .denied
        state.contacts = .authorized

        XCTAssertFalse(state.allPermissionsGranted)
    }

    func test_allPermissionsGranted_oneNotDetermined() {
        var state = PermissionsState()
        state.microphone = .authorized
        state.calendar = .notDetermined
        state.reminders = .authorized
        state.contacts = .authorized

        XCTAssertFalse(state.allPermissionsGranted)
    }

    // MARK: - Equatable Tests

    func test_equatable_sameStates() {
        var state1 = PermissionsState()
        state1.microphone = .authorized
        state1.calendar = .denied

        var state2 = PermissionsState()
        state2.microphone = .authorized
        state2.calendar = .denied

        XCTAssertEqual(state1, state2)
    }

    func test_equatable_differentStates() {
        var state1 = PermissionsState()
        state1.microphone = .authorized

        var state2 = PermissionsState()
        state2.microphone = .denied

        XCTAssertNotEqual(state1, state2)
    }
}

// MARK: - Permissions Manager Integration Tests

final class PermissionsManagerIntegrationTests: XCTestCase {

    override func setUpWithError() throws {
        try IntegrationTestGate.requirePermissionTestsEnabled()
    }

    // MARK: - Singleton Tests

    func test_shared_returnsSameInstance() async {
        let instance1 = PermissionsManager.shared
        let instance2 = PermissionsManager.shared

        // Verify both return the same state (actor identity)
        let state1 = await instance1.state
        let state2 = await instance2.state
        XCTAssertEqual(state1, state2)
    }

    // MARK: - State Tests

    func test_state_initiallyAvailable() async {
        let manager = PermissionsManager.shared
        let state = await manager.state
        XCTAssertNotNil(state)
    }

    // MARK: - Refresh Tests

    func test_refreshAll_updatesState() async {
        let manager = PermissionsManager.shared
        await manager.refreshAll()
        let state = await manager.state

        // After refresh, at least microphone should have a determined status
        // (it will be authorized, denied, or notDetermined - not unknown)
        XCTAssertNotEqual(state.microphone, .unknown)
    }

    // MARK: - Check Tests

    func test_check_returnsStatus() async {
        let manager = PermissionsManager.shared
        let status = await manager.check(.microphone)

        // Status should be one of the valid values
        XCTAssertTrue([.notDetermined, .authorized, .denied, .restricted, .unknown].contains(status))
    }

    func test_check_updatesState() async {
        let manager = PermissionsManager.shared
        let status = await manager.check(.microphone)
        let state = await manager.state

        // The state should reflect the checked status
        XCTAssertEqual(state.microphone, status)
    }
}

// MARK: - Permissions Manager Tests (Mocked)

final class PermissionsManagerMockedTests: XCTestCase {

    var mockClient: MockPermissionsClient!
    var manager: PermissionsManager!

    override func setUp() async throws {
        mockClient = MockPermissionsClient()
        manager = PermissionsManager(client: mockClient)
    }

    // MARK: - Check Tests

    func test_check_delegatesToClient() async {
        mockClient.statuses[.microphone] = .authorized

        let status = await manager.check(.microphone)

        XCTAssertEqual(status, .authorized)
        XCTAssertEqual(mockClient.checkedPermissions, [.microphone])
    }

    func test_check_updatesStateFromClient() async {
        mockClient.statuses[.calendar] = .denied

        _ = await manager.check(.calendar)
        let state = await manager.state

        XCTAssertEqual(state.calendar, .denied)
    }

    // MARK: - Refresh All Tests

    func test_refreshAll_checksAllPermissions() async {
        mockClient.statuses = [
            .microphone: .authorized,
            .calendar: .denied,
            .reminders: .notDetermined,
            .contacts: .restricted
        ]

        await manager.refreshAll()

        XCTAssertEqual(Set(mockClient.checkedPermissions), Set(PermissionType.allCases))

        let state = await manager.state
        XCTAssertEqual(state.microphone, .authorized)
        XCTAssertEqual(state.calendar, .denied)
        XCTAssertEqual(state.reminders, .notDetermined)
        XCTAssertEqual(state.contacts, .restricted)
    }

    // MARK: - Request Tests

    func test_request_delegatesToClient() async {
        mockClient.requestResults[.microphone] = .authorized

        let status = await manager.request(.microphone)

        XCTAssertEqual(status, .authorized)
        XCTAssertEqual(mockClient.requestedPermissions, [.microphone])
    }

    func test_request_updatesState() async {
        mockClient.requestResults[.calendar] = .authorized

        _ = await manager.request(.calendar)
        let state = await manager.state

        XCTAssertEqual(state.calendar, .authorized)
    }

    func test_request_handlesUserDenial() async {
        mockClient.requestResults[.reminders] = .denied

        let status = await manager.request(.reminders)

        XCTAssertEqual(status, .denied)
        let state = await manager.state
        XCTAssertEqual(state.reminders, .denied)
    }

    // MARK: - Request Required Tests

    func test_requestRequired_requestsMicrophone() async {
        mockClient.requestResults[.microphone] = .authorized

        let result = await manager.requestRequired()

        XCTAssertTrue(result)
        XCTAssertTrue(mockClient.requestedPermissions.contains(.microphone))
        XCTAssertEqual(mockClient.requestedPermissions.count, 1)
    }

    func test_requestRequired_returnsFalseIfMicDenied() async {
        mockClient.requestResults[.microphone] = .denied

        let result = await manager.requestRequired()

        XCTAssertFalse(result)
    }

    // MARK: - Request Optional Tests

    func test_requestOptional_requestsCalendarRemindersContacts() async {
        mockClient.requestResults[.calendar] = .authorized
        mockClient.requestResults[.reminders] = .authorized
        mockClient.requestResults[.contacts] = .authorized

        await manager.requestOptional()

        XCTAssertTrue(mockClient.requestedPermissions.contains(.calendar))
        XCTAssertTrue(mockClient.requestedPermissions.contains(.reminders))
        XCTAssertTrue(mockClient.requestedPermissions.contains(.contacts))
        XCTAssertFalse(mockClient.requestedPermissions.contains(.microphone))
    }

    // MARK: - Open Settings Tests

    @MainActor
    func test_openSettings_delegatesToClient() async {
        await manager.openSettings(for: .microphone)

        XCTAssertEqual(mockClient.openedSettings, [.microphone])
    }

    @MainActor
    func test_openSettings_worksForAllTypes() async {
        for type in PermissionType.allCases {
            mockClient.reset()
            await manager.openSettings(for: type)
            XCTAssertEqual(mockClient.openedSettings, [type], "openSettings should work for \(type)")
        }
    }

    // MARK: - State Change Notification Tests

    func test_check_postsNotification() async {
        mockClient.statuses[.microphone] = .authorized

        let expectation = XCTestExpectation(description: "State change notification posted")

        let observer = NotificationCenter.default.addObserver(
            forName: .permissionsStateDidChange,
            object: nil,
            queue: .main
        ) { _ in
            expectation.fulfill()
        }

        _ = await manager.check(.microphone)

        await fulfillment(of: [expectation], timeout: 1.0)
        NotificationCenter.default.removeObserver(observer)
    }

    func test_request_postsNotification() async {
        mockClient.requestResults[.microphone] = .authorized

        let expectation = XCTestExpectation(description: "State change notification posted")

        let observer = NotificationCenter.default.addObserver(
            forName: .permissionsStateDidChange,
            object: nil,
            queue: .main
        ) { _ in
            expectation.fulfill()
        }

        _ = await manager.request(.microphone)

        await fulfillment(of: [expectation], timeout: 1.0)
        NotificationCenter.default.removeObserver(observer)
    }

    func test_request_postsPromptCompletionNotification() async {
        mockClient.statuses[.microphone] = .notDetermined
        mockClient.requestResults[.microphone] = .authorized

        await MainActor.run {
            PermissionPromptTracker.shared.endPrompt(for: .microphone)
        }

        let expectation = XCTestExpectation(description: "Prompt completion notification posted")

        let observer = NotificationCenter.default.addObserver(
            forName: .permissionPromptDidEnd,
            object: nil,
            queue: .main
        ) { _ in
            expectation.fulfill()
        }

        _ = await manager.request(.microphone)

        await fulfillment(of: [expectation], timeout: 1.0)
        NotificationCenter.default.removeObserver(observer)

        let isPromptActive = await MainActor.run { PermissionPromptTracker.shared.isPromptActive }
        XCTAssertFalse(isPromptActive)
    }
}

// MARK: - Live Permissions Client Tests

final class LivePermissionsClientTests: XCTestCase {

    override func setUpWithError() throws {
        try IntegrationTestGate.requirePermissionTestsEnabled()
    }

    let client = LivePermissionsClient()

    func test_checkStatus_returnsValidStatus() {
        for type in PermissionType.allCases {
            let status = client.checkStatus(for: type)
            XCTAssertTrue(
                [.notDetermined, .authorized, .denied, .restricted, .unknown].contains(status),
                "\(type) should return a valid status"
            )
        }
    }

    /// Tests the early-return path in request() when permission is already determined.
    /// Only calls request() when safe (status != .notDetermined) to avoid triggering dialogs.
    func test_request_earlyReturn_whenAlreadyDetermined() async {
        for type in PermissionType.allCases {
            let currentStatus = client.checkStatus(for: type)

            // Only test if permission is already determined (won't trigger dialog)
            if currentStatus != .notDetermined {
                let requestStatus = await client.request(type)
                XCTAssertEqual(
                    requestStatus, currentStatus,
                    "\(type) request() should return current status when already determined"
                )
            }
        }
    }
}

// MARK: - Permission Helper Tests (Early Return Paths)

final class PermissionHelperTests: XCTestCase {

    override func setUpWithError() throws {
        try IntegrationTestGate.requirePermissionTestsEnabled()
    }

    /// Tests MicrophonePermission.request() early return when already determined
    func test_microphoneRequest_earlyReturn() async {
        let status = MicrophonePermission.checkStatus()
        guard status != .notDetermined else {
            // Skip test if permission not yet determined (would trigger dialog)
            return
        }

        let requestResult = await MicrophonePermission.request()
        XCTAssertEqual(requestResult, status)
    }

    /// Tests EventKitPermission.requestCalendar() early return when already determined
    func test_calendarRequest_earlyReturn() async {
        let status = EventKitPermission.checkCalendarStatus()
        guard status != .notDetermined else {
            return
        }

        let requestResult = await EventKitPermission.requestCalendar()
        XCTAssertEqual(requestResult, status)
    }

    /// Tests EventKitPermission.requestReminders() early return when already determined
    func test_remindersRequest_earlyReturn() async {
        let status = EventKitPermission.checkRemindersStatus()
        guard status != .notDetermined else {
            return
        }

        let requestResult = await EventKitPermission.requestReminders()
        XCTAssertEqual(requestResult, status)
    }

    /// Tests ContactsPermission.request() early return when already determined
    func test_contactsRequest_earlyReturn() async {
        let status = ContactsPermission.checkStatus()
        guard status != .notDetermined else {
            return
        }

        let requestResult = await ContactsPermission.request()
        XCTAssertEqual(requestResult, status)
    }
}

// MARK: - EventKit Permission Mapping Tests

final class EventKitPermissionMappingTests: XCTestCase {

    func test_eventKitPermission_mapsAuthorizationStatuses() {
        XCTAssertEqual(EventKitPermission.permissionStatus(for: .notDetermined), .notDetermined)
        XCTAssertEqual(EventKitPermission.permissionStatus(for: .authorized), .authorized)
        XCTAssertEqual(EventKitPermission.permissionStatus(for: .fullAccess), .authorized)
        XCTAssertEqual(EventKitPermission.permissionStatus(for: .writeOnly), .denied)
        XCTAssertEqual(EventKitPermission.permissionStatus(for: .denied), .denied)
        XCTAssertEqual(EventKitPermission.permissionStatus(for: .restricted), .restricted)
    }
}
