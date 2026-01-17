//
//  ChatBubbleCopyTests.swift
//  OraTests
//
//  Tests for ChatBubbleView copy functionality
//

import SwiftUI
import XCTest
@testable import Ora

/// Mock pasteboard for testing copy functionality
final class MockPasteboard: PasteboardWriting, @unchecked Sendable {
    private var _lastCopiedString: String?
    private let lock = NSLock()

    var lastCopiedString: String? {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self._lastCopiedString
    }

    @MainActor func setString(_ string: String) {
        self.lock.lock()
        defer { self.lock.unlock() }
        self._lastCopiedString = string
    }

    func reset() {
        self.lock.lock()
        defer { self.lock.unlock() }
        self._lastCopiedString = nil
    }
}

@MainActor
final class ChatBubbleCopyTests: XCTestCase {

    func test_copyButton_notShownForEmptyText() {
        // Empty text should not show copy button
        let bubble = ChatBubbleView(
            text: nil,
            role: .user,
            state: nil,
            isPartial: false,
            reduceTransparency: false,
            reduceMotion: false
        )
        XCTAssertFalse(bubble.hasCopyableContent)

        let emptyStringBubble = ChatBubbleView(
            text: "",
            role: .assistant,
            state: nil,
            isPartial: false,
            reduceTransparency: false,
            reduceMotion: false
        )
        XCTAssertFalse(emptyStringBubble.hasCopyableContent)
    }

    func test_copyButton_shownForNonEmptyText() {
        let userBubble = ChatBubbleView(
            text: "Hello world",
            role: .user,
            state: nil,
            isPartial: false,
            reduceTransparency: false,
            reduceMotion: false
        )
        XCTAssertTrue(userBubble.hasCopyableContent)

        let assistantBubble = ChatBubbleView(
            text: "Response text",
            role: .assistant,
            state: nil,
            isPartial: false,
            reduceTransparency: false,
            reduceMotion: false
        )
        XCTAssertTrue(assistantBubble.hasCopyableContent)

        let toolBubble = ChatBubbleView(
            text: "Tool result",
            role: .tool,
            state: nil,
            isPartial: false,
            reduceTransparency: false,
            reduceMotion: false
        )
        XCTAssertTrue(toolBubble.hasCopyableContent)
    }

    func test_copyButton_notShownForStateOnlyBubble() {
        // State-only bubbles (thinking/tool states without text) should not show copy
        let thinkingBubble = ChatBubbleView(
            text: nil,
            role: .assistant,
            state: .thinking("Planning"),
            isPartial: false,
            reduceTransparency: false,
            reduceMotion: false
        )
        XCTAssertFalse(thinkingBubble.hasCopyableContent)

        let toolStateBubble = ChatBubbleView(
            text: nil,
            role: .tool,
            state: .tool("Calendar"),
            isPartial: false,
            reduceTransparency: false,
            reduceMotion: false
        )
        XCTAssertFalse(toolStateBubble.hasCopyableContent)
    }

    func test_copyButton_shownForBubbleWithStateAndText() {
        // Bubbles with both state and text should show copy button for the text
        let bubbleWithStateAndText = ChatBubbleView(
            text: "Created event",
            role: .assistant,
            state: .tool("Calendar"),
            isPartial: false,
            reduceTransparency: false,
            reduceMotion: false
        )
        XCTAssertTrue(bubbleWithStateAndText.hasCopyableContent)
    }

    func test_copyToClipboard_copiesText() {
        let mockPasteboard = MockPasteboard()
        var bubble = ChatBubbleView(
            text: "Test message to copy",
            role: .user,
            state: nil,
            isPartial: false,
            reduceTransparency: false,
            reduceMotion: false
        )
        bubble.pasteboard = mockPasteboard

        bubble.performCopy()

        XCTAssertEqual(mockPasteboard.lastCopiedString, "Test message to copy")
    }

    func test_copyToClipboard_doesNotCopyEmptyText() {
        let mockPasteboard = MockPasteboard()
        var bubble = ChatBubbleView(
            text: nil,
            role: .user,
            state: nil,
            isPartial: false,
            reduceTransparency: false,
            reduceMotion: false
        )
        bubble.pasteboard = mockPasteboard

        bubble.performCopy()

        XCTAssertNil(mockPasteboard.lastCopiedString)
    }

    func test_copyToClipboard_copiesPartialText() {
        // Even partial bubbles should be copyable (user may want current snapshot)
        let mockPasteboard = MockPasteboard()
        var bubble = ChatBubbleView(
            text: "Partial message...",
            role: .user,
            state: nil,
            isPartial: true,
            reduceTransparency: false,
            reduceMotion: false
        )
        bubble.pasteboard = mockPasteboard

        bubble.performCopy()

        XCTAssertEqual(mockPasteboard.lastCopiedString, "Partial message...")
    }

    func test_copyButton_accessibilityLabel() {
        let bubble = ChatBubbleView(
            text: "Hello",
            role: .user,
            state: nil,
            isPartial: false,
            reduceTransparency: false,
            reduceMotion: false
        )
        XCTAssertEqual(bubble.copyButtonAccessibilityLabel(copied: false), "Copy to clipboard")
        XCTAssertEqual(bubble.copyButtonAccessibilityLabel(copied: true), "Copied")
    }

    func test_systemPasteboard_setsString() {
        let pasteboard = SystemPasteboard()
        pasteboard.setString("Test clipboard content")

        let result = NSPasteboard.general.string(forType: .string)
        XCTAssertEqual(result, "Test clipboard content")
    }
}
