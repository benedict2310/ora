//
//  MemoryRetrievalCoordinatorTests.swift
//  OraTests
//
//  Tests for keyword memory retrieval context injection.
//

import XCTest
@testable import Ora

actor StubMemoryIndex: MemoryIndexing {
    private let chunks: [MemoryChunk]

    init(chunks: [MemoryChunk]) {
        self.chunks = chunks
    }

    func rebuild() async {}

    func search(query: String, limit: Int) async -> [MemoryChunk] {
        return Array(self.chunks.prefix(limit))
    }
}

final class MemoryRetrievalCoordinatorTests: XCTestCase {

    func test_prepareRetrieval_triggeredAndHighScore_injectsThreeToSevenChunks() async {
        // Given
        let now = Date(timeIntervalSince1970: 1_739_599_200)
        let chunks: [MemoryChunk] = [
            MemoryChunk(
                content: "Atlas migration timeline is constrained by QA staffing.",
                documentType: .memory,
                sessionID: nil,
                sectionName: "Projects",
                lastModified: now,
                score: -0.14
            ),
            MemoryChunk(
                content: "Decision: move rollout checkpoint to Thursday.",
                documentType: .summary,
                sessionID: UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"),
                sectionName: "Decisions & Commitments",
                lastModified: now,
                score: -0.18
            ),
            MemoryChunk(
                content: "Open loop: confirm Phoenix dependency with infra.",
                documentType: .summary,
                sessionID: UUID(uuidString: "ffffffff-1111-2222-3333-444444444444"),
                sectionName: "Open Loops",
                lastModified: now,
                score: -0.21
            ),
            MemoryChunk(
                content: "Preference: keep migration notes concise.",
                documentType: .memory,
                sessionID: nil,
                sectionName: "Preferences",
                lastModified: now,
                score: -0.29
            ),
            MemoryChunk(
                content: "TL;DR: weekly migration checkpoint accepted.",
                documentType: .summary,
                sessionID: UUID(uuidString: "12345678-1234-5678-9abc-def012345678"),
                sectionName: "TL;DR",
                lastModified: now,
                score: -0.34
            )
        ]

        let conversationManager = ConversationManager.makeTestInstance(maxContextTokens: 6000)
        await conversationManager.startConversation(systemPrompt: "System prompt")

        let coordinator = KeywordMemoryRetrievalCoordinator(
            memoryIndex: StubMemoryIndex(chunks: chunks),
            configuration: .init(
                minTopScore: -0.30,
                minChunkCount: 3,
                maxChunkCount: 7,
                scoreWindowRatio: 0.70
            )
        )
        let triggerResult = MemoryTriggerResult(
            shouldTrigger: true,
            confidence: 0.92,
            triggerType: .linguistic,
            matchedSignals: ["remember"]
        )

        // When
        await coordinator.prepareRetrievalIfNeeded(
            userText: "remember atlas migration",
            triggerResult: triggerResult,
            conversationManager: conversationManager
        )
        let messages = await conversationManager.getMessagesForLLM()

        // Then
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[1].role, .system)

        let context = messages[1].content
        let numberedLines = context
            .components(separatedBy: .newlines)
            .filter { line in
                return line.range(of: #"^\d+\."#, options: .regularExpression) != nil
            }
        XCTAssertGreaterThanOrEqual(numberedLines.count, 3)
        XCTAssertLessThanOrEqual(numberedLines.count, 7)
    }

    func test_prepareRetrieval_topScoreBelowThreshold_doesNotInjectContext() async {
        // Given
        let now = Date(timeIntervalSince1970: 1_739_599_200)
        let chunks: [MemoryChunk] = [
            MemoryChunk(
                content: "Old note with weak overlap.",
                documentType: .memory,
                sessionID: nil,
                sectionName: "Projects",
                lastModified: now,
                score: -0.62
            ),
            MemoryChunk(
                content: "Another weak match.",
                documentType: .summary,
                sessionID: UUID(),
                sectionName: "TL;DR",
                lastModified: now,
                score: -0.75
            )
        ]

        let conversationManager = ConversationManager.makeTestInstance(maxContextTokens: 6000)
        await conversationManager.startConversation(systemPrompt: "System prompt")

        let coordinator = KeywordMemoryRetrievalCoordinator(
            memoryIndex: StubMemoryIndex(chunks: chunks),
            configuration: .init(
                minTopScore: -0.30,
                minChunkCount: 3,
                maxChunkCount: 7,
                scoreWindowRatio: 0.70
            )
        )
        let triggerResult = MemoryTriggerResult(
            shouldTrigger: true,
            confidence: 0.90,
            triggerType: .linguistic,
            matchedSignals: ["remember"]
        )

        // When
        await coordinator.prepareRetrievalIfNeeded(
            userText: "remember old note",
            triggerResult: triggerResult,
            conversationManager: conversationManager
        )
        let messages = await conversationManager.getMessagesForLLM()

        // Then
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0].role, .system)
        XCTAssertEqual(messages[0].content, "System prompt")
    }
}
