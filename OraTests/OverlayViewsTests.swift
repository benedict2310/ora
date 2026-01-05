//
//  OverlayViewsTests.swift
//  OraTests
//
//  Tests for overlay SwiftUI views and helpers
//

import SwiftUI
import XCTest
@testable import Ora

@MainActor
final class OverlayViewsTests: XCTestCase {

    func test_chatBubbleView_bodyBuilds_forRolesAndStates() {
        let userView = ChatBubbleView(
            text: "Hello",
            role: .user,
            state: nil,
            isPartial: false,
            reduceTransparency: true,
            reduceMotion: true
        )
        _ = userView.body

        let assistantView = ChatBubbleView(
            text: "Hi there",
            role: .assistant,
            state: .thinking,
            isPartial: false,
            reduceTransparency: false,
            reduceMotion: false
        )
        _ = assistantView.body

        let toolView = ChatBubbleView(
            text: nil,
            role: .tool,
            state: .tool("Calendar"),
            isPartial: true,
            reduceTransparency: true,
            reduceMotion: false
        )
        _ = toolView.body
    }

    func test_chatBubbleView_accessibility_helpers() {
        XCTAssertEqual(ChatBubbleView.roleLabel(for: .user), "You said")
        XCTAssertEqual(ChatBubbleView.roleLabel(for: .assistant), "Ora said")
        XCTAssertEqual(ChatBubbleView.roleLabel(for: .tool), "Ora tool")

        XCTAssertEqual(ChatBubbleView.accessibilityLabel(text: "Hello", role: .assistant), "Ora said: Hello")
        XCTAssertEqual(ChatBubbleView.accessibilityLabel(text: nil, role: .tool), "Ora tool")
        XCTAssertEqual(ChatBubbleView.accessibilityLabel(text: "", role: .user), "You said")

        XCTAssertEqual(ChatBubbleView.accessibilityHint(isPartial: true), "Partial transcription")
        XCTAssertEqual(ChatBubbleView.accessibilityHint(isPartial: false), "")
    }

    func test_toolStateView_bodyBuilds_forProposalAndExecuting() {
        let proposal = ToolProposal(
            toolName: "calendar.create",
            summary: "Create a meeting",
            details: "Tomorrow at 1 PM"
        )
        let proposalView = ToolStateView(
            mode: .proposal(proposal),
            reduceTransparency: true,
            reduceMotion: true
        )
        _ = proposalView.body

        let executingView = ToolStateView(
            mode: .executing(label: "Creating event"),
            reduceTransparency: false,
            reduceMotion: false
        )
        _ = executingView.body
    }

    func test_toolStateView_styleMapping() {
        XCTAssertEqual(ToolStateView.style(for: "calendar.delete"), .delete)
        XCTAssertEqual(ToolStateView.style(for: "calendar.create"), .create)
        XCTAssertEqual(ToolStateView.style(for: "calendar.edit"), .edit)
        XCTAssertEqual(ToolStateView.style(for: "reminders.complete"), .complete)
        XCTAssertEqual(ToolStateView.style(for: "system.open"), .fallback)

        XCTAssertEqual(ToolStateView.iconForTool("calendar.delete"), "trash.fill")
        XCTAssertEqual(ToolStateView.titleForTool("calendar.create"), "Confirm Create")
        _ = ToolStateView.colorForTool("calendar.edit")
    }
}
