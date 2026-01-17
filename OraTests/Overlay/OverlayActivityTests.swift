//
//  OverlayActivityTests.swift
//  OraTests
//
//  Tests for OverlayActivity enum and label mapping
//

import XCTest
@testable import Ora

final class OverlayActivityTests: XCTestCase {

    // MARK: - Display Label Tests

    func test_listening_displayLabel() {
        let activity = OverlayActivity.listening
        XCTAssertEqual(activity.displayLabel, "Listening")
    }

    func test_planning_displayLabel() {
        let activity = OverlayActivity.planning
        XCTAssertEqual(activity.displayLabel, "Planning response")
    }

    func test_toolCall_displayLabel() {
        let activity = OverlayActivity.toolCall(label: "Calendar")
        XCTAssertEqual(activity.displayLabel, "Calling Calendar")
    }

    func test_toolResult_displayLabel() {
        let activity = OverlayActivity.toolResult(label: "Calendar")
        XCTAssertEqual(activity.displayLabel, "Processing Calendar result")
    }

    func test_composing_displayLabel() {
        let activity = OverlayActivity.composing
        XCTAssertEqual(activity.displayLabel, "Composing response")
    }

    func test_speaking_displayLabel() {
        let activity = OverlayActivity.speaking
        XCTAssertEqual(activity.displayLabel, "Speaking")
    }

    func test_waiting_displayLabel() {
        let activity = OverlayActivity.waiting
        XCTAssertEqual(activity.displayLabel, "Waiting for your reply")
    }

    func test_none_displayLabel_isEmpty() {
        let activity = OverlayActivity.none
        XCTAssertEqual(activity.displayLabel, "")
    }

    // MARK: - Tool Label Mapping Tests

    func test_toolLabel_calendarPrefix() {
        XCTAssertEqual(OverlayActivity.toolLabel(for: "calendar.query"), "Calendar")
        XCTAssertEqual(OverlayActivity.toolLabel(for: "calendar.create"), "Calendar")
        XCTAssertEqual(OverlayActivity.toolLabel(for: "calendar.delete"), "Calendar")
        XCTAssertEqual(OverlayActivity.toolLabel(for: "calendar.edit"), "Calendar")
        XCTAssertEqual(OverlayActivity.toolLabel(for: "calendar.find_slots"), "Calendar")
    }

    func test_toolLabel_remindersPrefix() {
        XCTAssertEqual(OverlayActivity.toolLabel(for: "reminders.list"), "Reminders")
        XCTAssertEqual(OverlayActivity.toolLabel(for: "reminders.create"), "Reminders")
        XCTAssertEqual(OverlayActivity.toolLabel(for: "reminders.complete"), "Reminders")
        XCTAssertEqual(OverlayActivity.toolLabel(for: "reminders.edit"), "Reminders")
    }

    func test_toolLabel_contactsPrefix() {
        XCTAssertEqual(OverlayActivity.toolLabel(for: "contacts.search"), "Contacts")
    }

    func test_toolLabel_systemShortcuts() {
        XCTAssertEqual(OverlayActivity.toolLabel(for: "system.run_shortcut"), "Shortcuts")
        XCTAssertEqual(OverlayActivity.toolLabel(for: "system.list_shortcuts"), "Shortcuts")
    }

    func test_toolLabel_systemOther() {
        XCTAssertEqual(OverlayActivity.toolLabel(for: "system.open_app"), "System")
        XCTAssertEqual(OverlayActivity.toolLabel(for: "system.open_url"), "System")
        XCTAssertEqual(OverlayActivity.toolLabel(for: "system.search_files"), "System")
    }

    func test_toolLabel_unknownPrefix_fallsBackToTool() {
        XCTAssertEqual(OverlayActivity.toolLabel(for: "unknown.action"), "Tool")
        XCTAssertEqual(OverlayActivity.toolLabel(for: "custom.something"), "Tool")
    }

    func test_toolLabel_noPrefix_fallsBackToTool() {
        XCTAssertEqual(OverlayActivity.toolLabel(for: "someaction"), "Tool")
    }

    // MARK: - Equality Tests

    func test_equality_sameCase() {
        XCTAssertEqual(OverlayActivity.listening, OverlayActivity.listening)
        XCTAssertEqual(OverlayActivity.planning, OverlayActivity.planning)
        XCTAssertEqual(OverlayActivity.composing, OverlayActivity.composing)
        XCTAssertEqual(OverlayActivity.speaking, OverlayActivity.speaking)
        XCTAssertEqual(OverlayActivity.waiting, OverlayActivity.waiting)
        XCTAssertEqual(OverlayActivity.none, OverlayActivity.none)
    }

    func test_equality_toolCallWithSameLabel() {
        let a = OverlayActivity.toolCall(label: "Calendar")
        let b = OverlayActivity.toolCall(label: "Calendar")
        XCTAssertEqual(a, b)
    }

    func test_equality_toolCallWithDifferentLabel() {
        let a = OverlayActivity.toolCall(label: "Calendar")
        let b = OverlayActivity.toolCall(label: "Reminders")
        XCTAssertNotEqual(a, b)
    }

    func test_equality_toolResultWithSameLabel() {
        let a = OverlayActivity.toolResult(label: "Calendar")
        let b = OverlayActivity.toolResult(label: "Calendar")
        XCTAssertEqual(a, b)
    }

    func test_equality_differentCases() {
        XCTAssertNotEqual(OverlayActivity.listening, OverlayActivity.planning)
        XCTAssertNotEqual(OverlayActivity.composing, OverlayActivity.speaking)
        XCTAssertNotEqual(OverlayActivity.toolCall(label: "X"), OverlayActivity.toolResult(label: "X"))
    }

    // MARK: - OverlayViewModel Activity Tests

    @MainActor
    func test_viewModel_activityDefaultsToNone() {
        let viewModel = OverlayViewModel()
        XCTAssertEqual(viewModel.activity, .none)
    }

    @MainActor
    func test_viewModel_setActivity_updatesActivity() {
        let viewModel = OverlayViewModel()

        viewModel.setActivity(.listening)
        XCTAssertEqual(viewModel.activity, .listening)

        viewModel.setActivity(.planning)
        XCTAssertEqual(viewModel.activity, .planning)

        viewModel.setActivity(.toolCall(label: "Calendar"))
        XCTAssertEqual(viewModel.activity, .toolCall(label: "Calendar"))
    }

    @MainActor
    func test_viewModel_reset_clearsActivity() {
        let viewModel = OverlayViewModel()
        viewModel.setActivity(.speaking)
        XCTAssertEqual(viewModel.activity, .speaking)

        viewModel.reset()

        XCTAssertEqual(viewModel.activity, .none)
    }
}
