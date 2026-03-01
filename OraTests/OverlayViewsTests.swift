//
//  OverlayViewsTests.swift
//  OraTests
//
//  Tests for overlay SwiftUI views
//

import SwiftUI
import XCTest
@testable import Ora

@MainActor
final class OverlayViewsTests: XCTestCase {

    func test_chatBubbleView_accessibilityLabel_andHint() {
        XCTAssertEqual(
            ChatBubbleView.accessibilityLabel(for: .user, text: "Hello"),
            "You said: Hello"
        )
        XCTAssertEqual(
            ChatBubbleView.accessibilityLabel(for: .assistant, text: ""),
            "Ora said"
        )
        XCTAssertEqual(
            ChatBubbleView.accessibilityLabel(for: .tool, text: nil),
            "Ora tool"
        )

        XCTAssertEqual(ChatBubbleView.accessibilityHint(isPartial: true), "Partial transcription")
        XCTAssertEqual(ChatBubbleView.accessibilityHint(isPartial: false), "")
    }

    func test_chatBubbleView_bodyBuilds_forStatesAndRoles() {
        let userThinking = ChatBubbleView(
            text: "Hello",
            role: .user,
            state: .thinking(nil),
            isPartial: true,
            reduceTransparency: true,
            reduceMotion: true
        )
        _ = userThinking.body

        let assistantThinking = ChatBubbleView(
            text: "Thinking",
            role: .assistant,
            state: .thinking("Thinking"),
            isPartial: false,
            reduceTransparency: false,
            reduceMotion: false
        )
        _ = assistantThinking.body

        let toolMessage = ChatBubbleView(
            text: "Running tool",
            role: .tool,
            state: .tool("Calendar"),
            isPartial: false,
            reduceTransparency: true,
            reduceMotion: false
        )
        _ = toolMessage.body

        let emptyMessage = ChatBubbleView(
            text: nil,
            role: .tool,
            state: nil,
            isPartial: false,
            reduceTransparency: false,
            reduceMotion: true
        )
        _ = emptyMessage.body
    }

    func test_toolStateView_styleMapping() {
        XCTAssertEqual(ToolStateView.style(for: "calendar.delete"), .delete)
        XCTAssertEqual(ToolStateView.style(for: "reminders.create"), .create)
        XCTAssertEqual(ToolStateView.style(for: "calendar.edit"), .edit)
        XCTAssertEqual(ToolStateView.style(for: "reminders.complete"), .complete)
        XCTAssertEqual(ToolStateView.style(for: "contacts.lookup"), .unknown)
    }

    func test_toolStateView_iconAndTitleMappings() {
        XCTAssertEqual(ToolStateView.iconForTool("calendar.delete"), "trash.fill")
        XCTAssertEqual(ToolStateView.iconForTool("reminders.create"), "plus.circle.fill")
        XCTAssertEqual(ToolStateView.iconForTool("calendar.edit"), "pencil.circle.fill")
        XCTAssertEqual(ToolStateView.iconForTool("reminders.complete"), "checkmark.circle.fill")
        XCTAssertEqual(ToolStateView.iconForTool("contacts.lookup"), "questionmark.circle.fill")

        XCTAssertEqual(ToolStateView.titleForTool("calendar.delete"), "Confirm Delete")
        XCTAssertEqual(ToolStateView.titleForTool("reminders.create"), "Confirm Create")
        XCTAssertEqual(ToolStateView.titleForTool("calendar.edit"), "Confirm Edit")
        XCTAssertEqual(ToolStateView.titleForTool("reminders.complete"), "Confirm Complete")
        XCTAssertEqual(ToolStateView.titleForTool("contacts.lookup"), "Confirm Action")
    }

    func test_toolStateView_bodyBuilds_forProposalsAndExecuting() {
        let proposals = [
            ToolProposal(toolName: "calendar.delete", summary: "Delete event", details: "Today at 10"),
            ToolProposal(toolName: "reminders.create", summary: "Create reminder", details: nil),
            ToolProposal(toolName: "calendar.edit", summary: "Edit event", details: "Move to 11"),
            ToolProposal(toolName: "reminders.complete", summary: "Complete reminder", details: nil),
            ToolProposal(toolName: "contacts.lookup", summary: "Lookup", details: nil)
        ]

        for proposal in proposals {
            let view = ToolStateView(
                mode: .proposal(proposal),
                reduceTransparency: true,
                reduceMotion: false,
                onConfirmProposal: {},
                onConfirmAndTrustProposal: {},
                onDenyProposal: {}
            )
            _ = view.body
        }

        let executingMotion = ToolStateView(
            mode: .executing(label: "Executing..."),
            reduceTransparency: false,
            reduceMotion: false,
            onConfirmProposal: {},
            onConfirmAndTrustProposal: {},
            onDenyProposal: {}
        )
        _ = executingMotion.body

        let executingReduced = ToolStateView(
            mode: .executing(label: "Executing..."),
            reduceTransparency: true,
            reduceMotion: true,
            onConfirmProposal: {},
            onConfirmAndTrustProposal: {},
            onDenyProposal: {}
        )
        _ = executingReduced.body
    }

    func test_cloudIndicator_bodyBuilds_forCloudProviders() {
        let anthropic = CloudIndicator(providerType: .anthropic)
        _ = anthropic.body

        let openAI = CloudIndicator(providerType: .openai)
        _ = openAI.body
    }
}
