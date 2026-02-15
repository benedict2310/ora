//
//  TranscriptChunkerTests.swift
//  OraTests
//
//  Tests for transcript chunking into Q/A turn pairs.
//

import XCTest
@testable import Ora

final class TranscriptChunkerTests: XCTestCase {

    func test_chunk_pairsUserAndAssistantMessages_groupsIntoSequentialTurns() {
        // Given
        let sessionID = UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!
        let baseDate = Date(timeIntervalSince1970: 1_700_000_000)
        let chunker = TranscriptChunker()
        let messages = [
            self.makeMessage(role: .user, content: "Why did we choose Phoenix?", timestamp: baseDate),
            self.makeMessage(role: .assistant, content: "Because rollout risk was lower.", timestamp: baseDate.addingTimeInterval(2)),
            self.makeMessage(role: .user, content: "What was the backup plan?", timestamp: baseDate.addingTimeInterval(4)),
            self.makeMessage(role: .assistant, content: "Atlas fallback with staged gates.", timestamp: baseDate.addingTimeInterval(5))
        ]

        // When
        let chunks = chunker.chunk(sessionID: sessionID, messages: messages, lastModified: baseDate)

        // Then
        XCTAssertEqual(chunks.count, 2)
        XCTAssertEqual(chunks[0].sessionID, sessionID)
        XCTAssertEqual(chunks[0].turnNumber, 1)
        XCTAssertTrue(chunks[0].content.contains("User: Why did we choose Phoenix?"))
        XCTAssertTrue(chunks[0].content.contains("Assistant: Because rollout risk was lower."))

        XCTAssertEqual(chunks[1].turnNumber, 2)
        XCTAssertTrue(chunks[1].content.contains("User: What was the backup plan?"))
        XCTAssertTrue(chunks[1].content.contains("Assistant: Atlas fallback with staged gates."))
    }

    func test_chunk_includesToolMessagesWithinTurn_preservesReasoningContext() {
        // Given
        let sessionID = UUID()
        let baseDate = Date(timeIntervalSince1970: 1_700_000_500)
        let chunker = TranscriptChunker()
        let messages = [
            self.makeMessage(role: .user, content: "Why did we pick Wednesday?", timestamp: baseDate),
            self.makeMessage(role: .assistant, content: "Checking conflicts now.", timestamp: baseDate.addingTimeInterval(1)),
            self.makeMessage(role: .tool, content: "[ToolResult: calendar.query] Tuesday blocked", timestamp: baseDate.addingTimeInterval(2)),
            self.makeMessage(role: .assistant, content: "Wednesday had the cleanest slot.", timestamp: baseDate.addingTimeInterval(3))
        ]

        // When
        let chunks = chunker.chunk(sessionID: sessionID, messages: messages, lastModified: baseDate)

        // Then
        XCTAssertEqual(chunks.count, 1)
        XCTAssertTrue(chunks[0].content.contains("Assistant: Checking conflicts now."))
        XCTAssertTrue(chunks[0].content.contains("Tool: [ToolResult: calendar.query] Tuesday blocked"))
        XCTAssertTrue(chunks[0].content.contains("Assistant: Wednesday had the cleanest slot."))
    }

    func test_chunk_consecutiveUserMessages_startsNewTurnForEachQuestion() {
        // Given
        let sessionID = UUID()
        let baseDate = Date(timeIntervalSince1970: 1_700_001_000)
        let chunker = TranscriptChunker()
        let messages = [
            self.makeMessage(role: .user, content: "First question", timestamp: baseDate),
            self.makeMessage(role: .user, content: "Second question", timestamp: baseDate.addingTimeInterval(1)),
            self.makeMessage(role: .assistant, content: "Answer to second", timestamp: baseDate.addingTimeInterval(2))
        ]

        // When
        let chunks = chunker.chunk(sessionID: sessionID, messages: messages, lastModified: baseDate)

        // Then
        XCTAssertEqual(chunks.count, 2)
        XCTAssertEqual(chunks[0].turnNumber, 1)
        XCTAssertEqual(chunks[0].content, "User: First question")
        XCTAssertEqual(chunks[1].turnNumber, 2)
        XCTAssertTrue(chunks[1].content.contains("User: Second question"))
        XCTAssertTrue(chunks[1].content.contains("Assistant: Answer to second"))
    }

    func test_chunk_assistantBeforeFirstUser_ignoresOrphanedAssistantContent() {
        // Given
        let sessionID = UUID()
        let baseDate = Date(timeIntervalSince1970: 1_700_001_500)
        let chunker = TranscriptChunker()
        let messages = [
            self.makeMessage(role: .assistant, content: "Orphan answer", timestamp: baseDate),
            self.makeMessage(role: .tool, content: "Orphan tool", timestamp: baseDate.addingTimeInterval(1))
        ]

        // When
        let chunks = chunker.chunk(sessionID: sessionID, messages: messages, lastModified: baseDate)

        // Then
        XCTAssertTrue(chunks.isEmpty)
    }

    private func makeMessage(
        role: Session.Message.Role,
        content: String,
        timestamp: Date
    ) -> Session.Message {
        return Session.Message(
            id: UUID(),
            role: role,
            content: content,
            timestamp: timestamp,
            metadata: nil
        )
    }
}
