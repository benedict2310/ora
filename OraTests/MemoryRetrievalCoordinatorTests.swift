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
    private let transcriptChunks: [MemoryChunk]

    init(chunks: [MemoryChunk], transcriptChunks: [MemoryChunk] = []) {
        self.chunks = chunks
        self.transcriptChunks = transcriptChunks
    }

    func rebuild() async {}

    func search(query: String, limit: Int) async -> [MemoryChunk] {
        return Array(self.chunks.prefix(limit))
    }

    func searchTranscriptFallback(
        query: String,
        summarySessionIDs: [UUID],
        recentSessionLimit: Int,
        limit: Int
    ) async -> [MemoryChunk] {
        return Array(self.transcriptChunks.prefix(limit))
    }
}

final class MemoryRetrievalCoordinatorTests: XCTestCase {

    // MARK: - Properties

    private var temporaryDirectoryURL: URL!
    private var temporaryMemoryFileURL: URL!

    // MARK: - Setup

    override func setUpWithError() throws {
        self.temporaryDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: self.temporaryDirectoryURL, withIntermediateDirectories: true)
        self.temporaryMemoryFileURL = self.temporaryDirectoryURL.appendingPathComponent("MEMORY.md", isDirectory: false)
        try "# Ora Memory\n\n## Profile\n- [fact] User's name is TestUser.\n\n## Preferences\n- [preference] Likes unit tests.\n".write(
            to: self.temporaryMemoryFileURL, atomically: true, encoding: .utf8
        )
    }

    override func tearDownWithError() throws {
        if let url = self.temporaryDirectoryURL {
            try? FileManager.default.removeItem(at: url)
        }
        self.temporaryDirectoryURL = nil
        self.temporaryMemoryFileURL = nil
    }

    // MARK: - Tests

    func test_prepareRetrieval_triggeredAndHighScore_injectsFullMemoryAndSupplementaryChunks() async {
        // Given
        let now = Date(timeIntervalSince1970: 1_739_599_200)
        let chunks: [MemoryChunk] = [
            MemoryChunk(
                content: "Atlas migration timeline is constrained by QA staffing.",
                documentType: .memory,
                sessionID: nil,
                sectionName: "Projects",
                lastModified: now,
                score: 5.20
            ),
            MemoryChunk(
                content: "Decision: move rollout checkpoint to Thursday.",
                documentType: .summary,
                sessionID: UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"),
                sectionName: "Decisions & Commitments",
                lastModified: now,
                score: 4.10
            ),
            MemoryChunk(
                content: "Open loop: confirm Phoenix dependency with infra.",
                documentType: .summary,
                sessionID: UUID(uuidString: "ffffffff-1111-2222-3333-444444444444"),
                sectionName: "Open Loops",
                lastModified: now,
                score: 3.80
            )
        ]

        let conversationManager = ConversationManager.makeTestInstance(maxContextTokens: 6000)
        await conversationManager.startConversation(systemPrompt: "System prompt")

        let coordinator = KeywordMemoryRetrievalCoordinator(
            memoryIndex: StubMemoryIndex(chunks: chunks),
            memoryFileURL: self.temporaryMemoryFileURL,
            configuration: .init(
                minTopScore: 0.30,
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

        // Then — memory is merged into the single system message (Qwen drops extra system messages)
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0].role, .system)

        let context = messages[0].content
        XCTAssertTrue(context.contains("MEMORY.md"))
        XCTAssertTrue(context.contains("TestUser"))
        XCTAssertTrue(context.contains("Additional context from prior sessions"))
        XCTAssertTrue(context.contains("rollout checkpoint"))
    }

    func test_prepareRetrieval_hybridScoresAboveThreshold_injectsFullMemory() async {
        // Given
        let now = Date(timeIntervalSince1970: 1_739_599_200)
        let chunks: [MemoryChunk] = [
            MemoryChunk(
                content: "User prefers morning meetings.",
                documentType: .memory,
                sessionID: nil,
                sectionName: "Preferences",
                lastModified: now,
                score: 0.62
            ),
            MemoryChunk(
                content: "Project Atlas is the current focus.",
                documentType: .memory,
                sessionID: nil,
                sectionName: "Projects",
                lastModified: now,
                score: 0.41
            )
        ]

        let conversationManager = ConversationManager.makeTestInstance(maxContextTokens: 6000)
        await conversationManager.startConversation(systemPrompt: "System prompt")

        let coordinator = KeywordMemoryRetrievalCoordinator(
            memoryIndex: StubMemoryIndex(chunks: chunks),
            memoryFileURL: self.temporaryMemoryFileURL,
            configuration: .default
        )
        let triggerResult = MemoryTriggerResult(
            shouldTrigger: true,
            confidence: 0.90,
            triggerType: .entityOverlap,
            matchedSignals: ["morning"]
        )

        // When
        await coordinator.prepareRetrievalIfNeeded(
            userText: "do I prefer morning or afternoon?",
            triggerResult: triggerResult,
            conversationManager: conversationManager
        )
        let messages = await conversationManager.getMessagesForLLM()

        // Then
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0].role, .system)
        XCTAssertTrue(messages[0].content.contains("MEMORY.md"))
        XCTAssertTrue(messages[0].content.contains("TestUser"))
        XCTAssertTrue(messages[0].content.contains("Likes unit tests"))
    }

    func test_prepareRetrieval_topScoreBelowThreshold_stillInjectsFullMemory() async {
        // Given — search scores are below minTopScore, but MEMORY.md should still be injected
        let now = Date(timeIntervalSince1970: 1_739_599_200)
        let chunks: [MemoryChunk] = [
            MemoryChunk(
                content: "Old note with negligible overlap.",
                documentType: .memory,
                sessionID: nil,
                sectionName: "Projects",
                lastModified: now,
                score: 0.12
            ),
            MemoryChunk(
                content: "Another negligible match.",
                documentType: .summary,
                sessionID: UUID(),
                sectionName: "TL;DR",
                lastModified: now,
                score: 0.08
            )
        ]

        let conversationManager = ConversationManager.makeTestInstance(maxContextTokens: 6000)
        await conversationManager.startConversation(systemPrompt: "System prompt")

        let coordinator = KeywordMemoryRetrievalCoordinator(
            memoryIndex: StubMemoryIndex(chunks: chunks),
            memoryFileURL: self.temporaryMemoryFileURL,
            configuration: .init(
                minTopScore: 0.30,
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

        // Then — full MEMORY.md is injected even though search scores are low
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0].role, .system)
        XCTAssertTrue(messages[0].content.contains("MEMORY.md"))
        XCTAssertTrue(messages[0].content.contains("TestUser"))
        // No supplementary chunks since scores are below threshold
        XCTAssertFalse(messages[0].content.contains("Additional context"))
    }

    func test_prepareRetrieval_oversizedMemoryFile_isTruncated() async {
        // Given — a MEMORY.md that exceeds the character cap
        let oversizedContent = String(repeating: "x", count: KeywordMemoryRetrievalCoordinator.maxMemoryFileCharacters + 500)
        try! oversizedContent.write(to: self.temporaryMemoryFileURL, atomically: true, encoding: .utf8)

        let conversationManager = ConversationManager.makeTestInstance(maxContextTokens: 6000)
        await conversationManager.startConversation(systemPrompt: "System prompt")

        let coordinator = KeywordMemoryRetrievalCoordinator(
            memoryIndex: StubMemoryIndex(chunks: []),
            memoryFileURL: self.temporaryMemoryFileURL,
            configuration: .default
        )
        let triggerResult = MemoryTriggerResult(
            shouldTrigger: true,
            confidence: 0.90,
            triggerType: .linguistic,
            matchedSignals: ["remember"]
        )

        // When
        await coordinator.prepareRetrievalIfNeeded(
            userText: "remember something",
            triggerResult: triggerResult,
            conversationManager: conversationManager
        )
        let messages = await conversationManager.getMessagesForLLM()

        // Then — content is capped with head+tail and omission marker is present
        XCTAssertEqual(messages.count, 1)
        let context = messages[0].content
        XCTAssertTrue(context.contains("characters omitted"))
        // The raw oversized content should NOT appear in full
        XCTAssertFalse(context.contains(oversizedContent))
    }

    func test_prepareRetrieval_notTriggered_stillInjectsMemoryFile() async {
        // Given — trigger doesn't fire, but MEMORY.md should still be injected
        // so the LLM always knows the user's name, preferences, etc.
        let conversationManager = ConversationManager.makeTestInstance(maxContextTokens: 6000)
        await conversationManager.startConversation(systemPrompt: "System prompt")

        let coordinator = KeywordMemoryRetrievalCoordinator(
            memoryIndex: StubMemoryIndex(chunks: []),
            memoryFileURL: self.temporaryMemoryFileURL
        )
        let triggerResult = MemoryTriggerResult(
            shouldTrigger: false,
            confidence: 0.0,
            triggerType: .none,
            matchedSignals: []
        )

        // When
        await coordinator.prepareRetrievalIfNeeded(
            userText: "what's the weather",
            triggerResult: triggerResult,
            conversationManager: conversationManager
        )
        let messages = await conversationManager.getMessagesForLLM()

        // Then — MEMORY.md is merged into system prompt, no supplementary chunks
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0].role, .system)
        XCTAssertTrue(messages[0].content.contains("MEMORY.md"))
        XCTAssertTrue(messages[0].content.contains("TestUser"))
        XCTAssertFalse(messages[0].content.contains("Additional context"))
    }

    func test_prepareRetrieval_multiTurn_memoryPersistsWhenTriggerStops() async {
        // Regression test: the user's name should remain available even when
        // a follow-up turn has no keyword overlap with memory entities.
        // This was the root cause of "Ora doesn't remember my name anymore".
        let now = Date(timeIntervalSince1970: 1_739_599_200)
        let chunks: [MemoryChunk] = [
            MemoryChunk(
                content: "User prefers dark mode.",
                documentType: .summary,
                sessionID: UUID(),
                sectionName: "Preferences",
                lastModified: now,
                score: 4.50
            )
        ]

        let conversationManager = ConversationManager.makeTestInstance(maxContextTokens: 6000)
        await conversationManager.startConversation(systemPrompt: "System prompt")

        let coordinator = KeywordMemoryRetrievalCoordinator(
            memoryIndex: StubMemoryIndex(chunks: chunks),
            memoryFileURL: self.temporaryMemoryFileURL,
            configuration: .default
        )

        // Turn 1: trigger fires (e.g., "do you remember my name?")
        let triggeredResult = MemoryTriggerResult(
            shouldTrigger: true,
            confidence: 0.92,
            triggerType: .linguistic,
            matchedSignals: ["remember"]
        )
        await coordinator.prepareRetrievalIfNeeded(
            userText: "do you remember my name?",
            triggerResult: triggeredResult,
            conversationManager: conversationManager
        )
        let turn1Messages = await conversationManager.getMessagesForLLM()
        XCTAssertTrue(turn1Messages.contains { $0.content.contains("TestUser") },
                       "Turn 1: MEMORY.md with user name should be injected")

        // Turn 2: trigger does NOT fire (e.g., "tell me a joke")
        let notTriggeredResult = MemoryTriggerResult(
            shouldTrigger: false,
            confidence: 0.0,
            triggerType: .none,
            matchedSignals: []
        )
        await coordinator.prepareRetrievalIfNeeded(
            userText: "tell me a joke",
            triggerResult: notTriggeredResult,
            conversationManager: conversationManager
        )
        let turn2Messages = await conversationManager.getMessagesForLLM()
        XCTAssertTrue(turn2Messages.contains { $0.content.contains("TestUser") },
                       "Turn 2: MEMORY.md should still be injected even without trigger")
        XCTAssertFalse(turn2Messages.contains { $0.content.contains("Additional context") },
                        "Turn 2: no supplementary chunks without trigger")
    }

    func test_prepareRetrieval_notTriggered_doesNotQueryIndex() async {
        // Given — trigger doesn't fire; supplementary chunks exist in the index
        // but should NOT be retrieved (avoids unnecessary index queries).
        let now = Date(timeIntervalSince1970: 1_739_599_200)
        let chunks: [MemoryChunk] = [
            MemoryChunk(
                content: "Sensitive project detail from prior session.",
                documentType: .summary,
                sessionID: UUID(),
                sectionName: "Projects",
                lastModified: now,
                score: 5.0
            )
        ]

        let conversationManager = ConversationManager.makeTestInstance(maxContextTokens: 6000)
        await conversationManager.startConversation(systemPrompt: "System prompt")

        let coordinator = KeywordMemoryRetrievalCoordinator(
            memoryIndex: StubMemoryIndex(chunks: chunks),
            memoryFileURL: self.temporaryMemoryFileURL,
            configuration: .default
        )
        let triggerResult = MemoryTriggerResult(
            shouldTrigger: false,
            confidence: 0.0,
            triggerType: .none,
            matchedSignals: []
        )

        // When
        await coordinator.prepareRetrievalIfNeeded(
            userText: "good morning",
            triggerResult: triggerResult,
            conversationManager: conversationManager
        )
        let messages = await conversationManager.getMessagesForLLM()

        // Then — MEMORY.md merged into system prompt, but supplementary chunks NOT included
        XCTAssertEqual(messages.count, 1)
        XCTAssertTrue(messages[0].content.contains("TestUser"))
        XCTAssertFalse(messages[0].content.contains("Sensitive project detail"),
                        "Supplementary chunks should not be included when trigger doesn't fire")
    }

    func test_prepareRetrieval_notTriggered_missingMemoryFile_doesNotInjectContext() async {
        // Given — trigger doesn't fire AND memory file doesn't exist
        let conversationManager = ConversationManager.makeTestInstance(maxContextTokens: 6000)
        await conversationManager.startConversation(systemPrompt: "System prompt")

        let missingURL = self.temporaryDirectoryURL.appendingPathComponent("nonexistent-MEMORY.md")
        let coordinator = KeywordMemoryRetrievalCoordinator(
            memoryIndex: StubMemoryIndex(chunks: []),
            memoryFileURL: missingURL
        )
        let triggerResult = MemoryTriggerResult(
            shouldTrigger: false,
            confidence: 0.0,
            triggerType: .none,
            matchedSignals: []
        )

        // When
        await coordinator.prepareRetrievalIfNeeded(
            userText: "hello",
            triggerResult: triggerResult,
            conversationManager: conversationManager
        )
        let messages = await conversationManager.getMessagesForLLM()

        // Then — no memory file means just the system prompt
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0].role, .system)
        XCTAssertEqual(messages[0].content, "System prompt")
    }

    func test_prepareRetrieval_memoryMergedIntoSystemMessage() async {
        // Regression: Qwen's chat template only processes messages[0] for
        // the system role — additional system messages are silently dropped.
        // Memory context MUST be merged into the first system message.
        let conversationManager = ConversationManager.makeTestInstance(maxContextTokens: 6000)
        await conversationManager.startConversation(systemPrompt: "System prompt")

        let coordinator = KeywordMemoryRetrievalCoordinator(
            memoryIndex: StubMemoryIndex(chunks: []),
            memoryFileURL: self.temporaryMemoryFileURL
        )
        let triggerResult = MemoryTriggerResult(
            shouldTrigger: true,
            confidence: 0.90,
            triggerType: .linguistic,
            matchedSignals: ["name"]
        )

        // When
        await coordinator.prepareRetrievalIfNeeded(
            userText: "what's my name?",
            triggerResult: triggerResult,
            conversationManager: conversationManager
        )
        let messages = await conversationManager.getMessagesForLLM()

        // Then — exactly 1 system message containing BOTH prompt and memory
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0].role, .system)
        XCTAssertTrue(messages[0].content.contains("System prompt"),
                       "System prompt must be present in merged message")
        XCTAssertTrue(messages[0].content.contains("TestUser"),
                       "Memory context must be merged into the same system message")
        // No second system message
        let systemMessages = messages.filter { $0.role == .system }
        XCTAssertEqual(systemMessages.count, 1,
                        "Must be exactly 1 system message — Qwen drops additional ones")
    }
}
