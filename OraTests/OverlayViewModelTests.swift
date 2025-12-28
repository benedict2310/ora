//
//  OverlayViewModelTests.swift
//  OraTests
//
//  Unit tests for OverlayViewModel
//

import XCTest
@testable import Ora

@MainActor
final class OverlayViewModelTests: XCTestCase {

    // MARK: - Initial State Tests

    // TC-1: Initial state
    func test_initialMode_isHidden() {
        let viewModel = OverlayViewModel()
        XCTAssertEqual(viewModel.mode, .hidden)
        XCTAssertTrue(viewModel.messages.isEmpty)
        XCTAssertNil(viewModel.currentProposal)
    }

    // MARK: - User Message Tests

    // TC-2: Add user message
    func test_addUserMessage_addsMessage() {
        let viewModel = OverlayViewModel()
        viewModel.addUserMessage("Hello", isPartial: false)

        XCTAssertEqual(viewModel.messages.count, 1)
        XCTAssertEqual(viewModel.messages[0].role, .user)
        XCTAssertEqual(viewModel.messages[0].content, "Hello")
        XCTAssertFalse(viewModel.messages[0].isPartial)
    }

    // TC-3: Update partial message
    func test_addUserMessage_updatesPartial() {
        let viewModel = OverlayViewModel()
        viewModel.addUserMessage("Hel", isPartial: true)
        viewModel.addUserMessage("Hello", isPartial: true)
        viewModel.addUserMessage("Hello world", isPartial: false)

        XCTAssertEqual(viewModel.messages.count, 1)
        XCTAssertEqual(viewModel.messages[0].content, "Hello world")
        XCTAssertFalse(viewModel.messages[0].isPartial)
    }

    func test_addUserMessage_partialThenFinal_updatesCorrectly() {
        let viewModel = OverlayViewModel()

        viewModel.addUserMessage("Sched", isPartial: true)
        XCTAssertEqual(viewModel.messages.count, 1)
        XCTAssertTrue(viewModel.messages[0].isPartial)

        viewModel.addUserMessage("Schedule a meeting", isPartial: false)
        XCTAssertEqual(viewModel.messages.count, 1)
        XCTAssertEqual(viewModel.messages[0].content, "Schedule a meeting")
        XCTAssertFalse(viewModel.messages[0].isPartial)
    }

    func test_addUserMessage_afterFinalMessage_addsNewMessage() {
        let viewModel = OverlayViewModel()

        viewModel.addUserMessage("First message", isPartial: false)
        viewModel.addUserMessage("Second message", isPartial: false)

        XCTAssertEqual(viewModel.messages.count, 2)
        XCTAssertEqual(viewModel.messages[0].content, "First message")
        XCTAssertEqual(viewModel.messages[1].content, "Second message")
    }

    // MARK: - Assistant Message Tests

    func test_addAssistantMessage_addsMessage() {
        let viewModel = OverlayViewModel()
        viewModel.addAssistantMessage("Hello! How can I help?", isPartial: false)

        XCTAssertEqual(viewModel.messages.count, 1)
        XCTAssertEqual(viewModel.messages[0].role, .assistant)
        XCTAssertEqual(viewModel.messages[0].content, "Hello! How can I help?")
        XCTAssertFalse(viewModel.messages[0].isPartial)
    }

    func test_addAssistantMessage_updatesPartial() {
        let viewModel = OverlayViewModel()

        viewModel.addAssistantMessage("I'll", isPartial: true)
        viewModel.addAssistantMessage("I'll create", isPartial: true)
        viewModel.addAssistantMessage("I'll create a meeting for you.", isPartial: false)

        XCTAssertEqual(viewModel.messages.count, 1)
        XCTAssertEqual(viewModel.messages[0].content, "I'll create a meeting for you.")
        XCTAssertFalse(viewModel.messages[0].isPartial)
    }

    // MARK: - Mixed Messages Tests

    func test_mixedMessages_alternateCorrectly() {
        let viewModel = OverlayViewModel()

        viewModel.addUserMessage("Schedule a meeting", isPartial: false)
        viewModel.addAssistantMessage("I'll create a meeting.", isPartial: false)
        viewModel.addUserMessage("Make it at 2pm", isPartial: false)
        viewModel.addAssistantMessage("Updated to 2pm.", isPartial: false)

        XCTAssertEqual(viewModel.messages.count, 4)
        XCTAssertEqual(viewModel.messages[0].role, .user)
        XCTAssertEqual(viewModel.messages[1].role, .assistant)
        XCTAssertEqual(viewModel.messages[2].role, .user)
        XCTAssertEqual(viewModel.messages[3].role, .assistant)
    }

    // MARK: - Tool Proposal Tests

    func test_showProposal_setsProposalAndMode() {
        let viewModel = OverlayViewModel()
        let proposal = ToolProposal(
            toolName: "calendar.create",
            summary: "Create a meeting tomorrow at 2pm",
            details: "Title: Team Standup"
        )

        viewModel.showProposal(proposal)

        XCTAssertEqual(viewModel.currentProposal, proposal)
        if case .proposing(let mode) = viewModel.mode {
            XCTAssertEqual(mode, proposal)
        } else {
            XCTFail("Expected proposing mode")
        }
    }

    func test_toolProposal_equality() {
        let proposal1 = ToolProposal(toolName: "calendar.create", summary: "Test", details: nil)
        let proposal2 = ToolProposal(toolName: "calendar.create", summary: "Test", details: nil)
        let proposal3 = ToolProposal(toolName: "calendar.delete", summary: "Test", details: nil)

        XCTAssertEqual(proposal1, proposal2)
        XCTAssertNotEqual(proposal1, proposal3)
    }

    // MARK: - Reset Tests

    // TC-4: Reset clears state
    func test_reset_clearsAll() {
        let viewModel = OverlayViewModel()
        viewModel.addUserMessage("Test", isPartial: false)
        viewModel.mode = .listening
        viewModel.currentProposal = ToolProposal(toolName: "test", summary: "test", details: nil)

        viewModel.reset()

        XCTAssertEqual(viewModel.mode, .hidden)
        XCTAssertTrue(viewModel.messages.isEmpty)
        XCTAssertNil(viewModel.currentProposal)
    }

    // MARK: - Mode Tests

    func test_modeEquality() {
        XCTAssertEqual(OverlayMode.hidden, OverlayMode.hidden)
        XCTAssertEqual(OverlayMode.listening, OverlayMode.listening)
        XCTAssertEqual(OverlayMode.thinking, OverlayMode.thinking)
        XCTAssertEqual(OverlayMode.responding, OverlayMode.responding)
        XCTAssertEqual(OverlayMode.executing, OverlayMode.executing)
        XCTAssertEqual(OverlayMode.completed, OverlayMode.completed)
        XCTAssertNotEqual(OverlayMode.listening, OverlayMode.thinking)
    }

    func test_modeEquality_error() {
        XCTAssertEqual(OverlayMode.error("same"), OverlayMode.error("same"))
        XCTAssertNotEqual(OverlayMode.error("one"), OverlayMode.error("two"))
    }

    func test_modeEquality_proposing() {
        let proposal1 = ToolProposal(toolName: "test", summary: "summary", details: nil)
        let proposal2 = ToolProposal(toolName: "test", summary: "summary", details: nil)
        let proposal3 = ToolProposal(toolName: "other", summary: "summary", details: nil)

        XCTAssertEqual(OverlayMode.proposing(proposal1), OverlayMode.proposing(proposal2))
        XCTAssertNotEqual(OverlayMode.proposing(proposal1), OverlayMode.proposing(proposal3))
    }

    func test_allModes_areReachable() {
        let viewModel = OverlayViewModel()

        viewModel.mode = .hidden
        XCTAssertEqual(viewModel.mode, .hidden)

        viewModel.mode = .listening
        XCTAssertEqual(viewModel.mode, .listening)

        viewModel.mode = .thinking
        XCTAssertEqual(viewModel.mode, .thinking)

        viewModel.mode = .responding
        XCTAssertEqual(viewModel.mode, .responding)

        viewModel.mode = .executing
        XCTAssertEqual(viewModel.mode, .executing)

        viewModel.mode = .completed
        XCTAssertEqual(viewModel.mode, .completed)

        viewModel.mode = .error("Test error")
        if case .error(let message) = viewModel.mode {
            XCTAssertEqual(message, "Test error")
        } else {
            XCTFail("Expected error mode")
        }

        let proposal = ToolProposal(toolName: "test", summary: "test", details: nil)
        viewModel.mode = .proposing(proposal)
        if case .proposing(let p) = viewModel.mode {
            XCTAssertEqual(p, proposal)
        } else {
            XCTFail("Expected proposing mode")
        }
    }

    // MARK: - Message Tests

    func test_overlayMessage_hasUniqueIds() {
        let message1 = OverlayMessage(role: .user, content: "Test")
        let message2 = OverlayMessage(role: .user, content: "Test")

        XCTAssertNotEqual(message1.id, message2.id)
    }

    func test_overlayMessage_hasTimestamp() {
        let before = Date()
        let message = OverlayMessage(role: .user, content: "Test")
        let after = Date()

        XCTAssertGreaterThanOrEqual(message.timestamp, before)
        XCTAssertLessThanOrEqual(message.timestamp, after)
    }

    func test_overlayMessage_equality() {
        let message1 = OverlayMessage(role: .user, content: "Test")
        let message2 = OverlayMessage(role: .user, content: "Test")

        // Different IDs mean they're not equal
        XCTAssertNotEqual(message1, message2)

        // Same message equals itself
        XCTAssertEqual(message1, message1)
    }
}
