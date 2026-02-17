//
//  TranscriptRetrievalTests.swift
//  OraTests
//
//  Tests for transcript fallback retrieval behavior and scoping.
//

import XCTest
@testable import Ora

actor RecordingFallbackMemoryIndex: MemoryIndexing {
    private let primaryChunks: [MemoryChunk]
    private let transcriptChunks: [MemoryChunk]
    private(set) var transcriptFallbackCallCount = 0
    private(set) var lastSummarySessionIDs: [UUID] = []

    init(primaryChunks: [MemoryChunk], transcriptChunks: [MemoryChunk]) {
        self.primaryChunks = primaryChunks
        self.transcriptChunks = transcriptChunks
    }

    func rebuild() async {}

    func search(query: String, limit: Int) async -> [MemoryChunk] {
        return Array(self.primaryChunks.prefix(limit))
    }

    func searchTranscriptFallback(
        query: String,
        summarySessionIDs: [UUID],
        recentSessionLimit: Int,
        limit: Int
    ) async -> [MemoryChunk] {
        self.transcriptFallbackCallCount += 1
        self.lastSummarySessionIDs = summarySessionIDs
        return Array(self.transcriptChunks.prefix(limit))
    }

    func snapshot() -> (callCount: Int, summarySessionIDs: [UUID]) {
        return (self.transcriptFallbackCallCount, self.lastSummarySessionIDs)
    }
}

actor TranscriptScopeLoaderRecorder {
    private let summarySnapshots: [MemoryIndex.TranscriptSessionSnapshot]
    private let recentSnapshots: [MemoryIndex.TranscriptSessionSnapshot]

    private(set) var lastSummarySessionIDs: [UUID] = []
    private(set) var lastRecentSessionLimit: Int = 0

    init(
        summarySnapshots: [MemoryIndex.TranscriptSessionSnapshot],
        recentSnapshots: [MemoryIndex.TranscriptSessionSnapshot]
    ) {
        self.summarySnapshots = summarySnapshots
        self.recentSnapshots = recentSnapshots
    }

    func load(summarySessionIDs: [UUID], recentSessionLimit: Int) -> [MemoryIndex.TranscriptSessionSnapshot] {
        self.lastSummarySessionIDs = summarySessionIDs
        self.lastRecentSessionLimit = recentSessionLimit

        if !summarySessionIDs.isEmpty {
            let scoped = Set(summarySessionIDs)
            return self.summarySnapshots.filter { scoped.contains($0.sessionID) }
        }

        return self.recentSnapshots
    }

    func snapshot() -> (summarySessionIDs: [UUID], recentSessionLimit: Int) {
        return (self.lastSummarySessionIDs, self.lastRecentSessionLimit)
    }
}

final class TranscriptRetrievalTests: XCTestCase {

    private var temporaryMemoryFileURL: URL!

    override func setUpWithError() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        self.temporaryMemoryFileURL = temporaryDirectory.appendingPathComponent("MEMORY.md", isDirectory: false)
        try "# Ora Memory\n\n## Profile\n- [fact] Test user\n".write(
            to: self.temporaryMemoryFileURL, atomically: true, encoding: .utf8
        )
    }

    override func tearDownWithError() throws {
        if let url = self.temporaryMemoryFileURL {
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        }
        self.temporaryMemoryFileURL = nil
    }

    func test_prepareRetrieval_primaryScoreLow_usesTranscriptFallbackContext() async {
        // Given
        let now = Date(timeIntervalSince1970: 1_739_600_000)
        let summarySessionID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let primaryChunks = [
            MemoryChunk(
                content: "Decision logged without detailed rationale.",
                documentType: .summary,
                sessionID: summarySessionID,
                sectionName: "Decisions & Commitments",
                lastModified: now,
                score: 0.01
            )
        ]
        let transcriptChunks = [
            MemoryChunk(
                content: "User: why did we choose phoenix\nAssistant: we chose phoenix because rollback risk was lower.",
                documentType: .transcript,
                sessionID: summarySessionID,
                turnNumber: 4,
                sectionName: "Turn 4",
                lastModified: now,
                score: 0.8
            )
        ]
        let index = RecordingFallbackMemoryIndex(primaryChunks: primaryChunks, transcriptChunks: transcriptChunks)
        let coordinator = KeywordMemoryRetrievalCoordinator(
            memoryIndex: index,
            memoryFileURL: self.temporaryMemoryFileURL,
            configuration: .init(
                minTopScore: 1e-7,
                minChunkCount: 1,
                maxChunkCount: 7,
                scoreWindowRatio: 0.70,
                primarySufficiencyScore: 0.25,
                transcriptMinTopScore: 1e-7,
                transcriptResultLimit: 3,
                recentTranscriptSessionLimit: 5
            )
        )
        let triggerResult = MemoryTriggerResult(
            shouldTrigger: true,
            confidence: 0.92,
            triggerType: .linguistic,
            matchedSignals: ["why did we"]
        )
        let conversationManager = ConversationManager.makeTestInstance(maxContextTokens: 6000)
        await conversationManager.startConversation(systemPrompt: "System prompt")

        // When
        await coordinator.prepareRetrievalIfNeeded(
            userText: "why did we choose phoenix",
            triggerResult: triggerResult,
            conversationManager: conversationManager
        )

        // Then
        let snapshot = await index.snapshot()
        XCTAssertEqual(snapshot.callCount, 1)
        XCTAssertEqual(snapshot.summarySessionIDs, [summarySessionID])

        let messages = await conversationManager.getMessagesForLLM()
        XCTAssertEqual(messages.count, 2)
        XCTAssertTrue(messages[1].content.contains("MEMORY.md"))
        XCTAssertTrue(messages[1].content.contains("transcript \(summarySessionID.uuidString) turn 4"))
        XCTAssertTrue(messages[1].content.contains("rollback risk was lower"))
    }

    func test_prepareRetrieval_primaryScoreHigh_skipsTranscriptFallback() async {
        // Given
        let now = Date(timeIntervalSince1970: 1_739_600_500)
        let primaryChunks = [
            MemoryChunk(
                content: "Atlas depends on Phoenix gateway guardrail checklist.",
                documentType: .memory,
                sessionID: nil,
                sectionName: "Projects",
                lastModified: now,
                score: 4.5
            )
        ]
        let transcriptChunks = [
            MemoryChunk(
                content: "User: ignored\nAssistant: ignored",
                documentType: .transcript,
                sessionID: UUID(),
                turnNumber: 1,
                sectionName: "Turn 1",
                lastModified: now,
                score: 0.5
            )
        ]
        let index = RecordingFallbackMemoryIndex(primaryChunks: primaryChunks, transcriptChunks: transcriptChunks)
        let coordinator = KeywordMemoryRetrievalCoordinator(
            memoryIndex: index,
            memoryFileURL: self.temporaryMemoryFileURL,
            configuration: .init(
                minTopScore: 1e-7,
                minChunkCount: 1,
                maxChunkCount: 7,
                scoreWindowRatio: 0.70,
                primarySufficiencyScore: 0.25
            )
        )
        let triggerResult = MemoryTriggerResult(
            shouldTrigger: true,
            confidence: 0.90,
            triggerType: .entityOverlap,
            matchedSignals: ["atlas"]
        )
        let conversationManager = ConversationManager.makeTestInstance(maxContextTokens: 6000)
        await conversationManager.startConversation(systemPrompt: "System prompt")

        // When
        await coordinator.prepareRetrievalIfNeeded(
            userText: "what depends on phoenix",
            triggerResult: triggerResult,
            conversationManager: conversationManager
        )

        // Then
        let snapshot = await index.snapshot()
        XCTAssertEqual(snapshot.callCount, 0)

        let messages = await conversationManager.getMessagesForLLM()
        XCTAssertEqual(messages.count, 2)
        XCTAssertTrue(messages[1].content.contains("MEMORY.md"))
        XCTAssertTrue(messages[1].content.contains("Test user"))
    }

    func test_searchTranscriptFallback_withSummarySessionScope_limitsToSummarySessions() async throws {
        // Given
        let temporaryDirectoryURL = try self.makeTemporaryMemoryDirectory()
        defer {
            try? FileManager.default.removeItem(at: temporaryDirectoryURL)
        }

        let summarySessionID = UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!
        let unrelatedSessionID = UUID(uuidString: "ffffffff-1111-2222-3333-444444444444")!
        let baseDate = Date(timeIntervalSince1970: 1_739_601_000)

        let summaryScopedMessages = [
            self.makeMessage(role: .user, content: "Why did we choose Phoenix?"),
            self.makeMessage(role: .assistant, content: "Because reliability was better under load.")
        ]
        let unrelatedMessages = [
            self.makeMessage(role: .user, content: "What did we ship?"),
            self.makeMessage(role: .assistant, content: "A dashboard patch.")
        ]

        let loader = TranscriptScopeLoaderRecorder(
            summarySnapshots: [
                MemoryIndex.TranscriptSessionSnapshot(
                    sessionID: summarySessionID,
                    lastModified: baseDate,
                    messages: summaryScopedMessages
                ),
                MemoryIndex.TranscriptSessionSnapshot(
                    sessionID: unrelatedSessionID,
                    lastModified: baseDate,
                    messages: unrelatedMessages
                )
            ],
            recentSnapshots: []
        )
        let index = MemoryIndex(
            memoryDirectory: temporaryDirectoryURL,
            transcriptSessionLoader: { summarySessionIDs, recentSessionLimit in
                return await loader.load(
                    summarySessionIDs: summarySessionIDs,
                    recentSessionLimit: recentSessionLimit
                )
            },
            embeddingService: StubEmbeddingService()
        )
        await index.rebuild()

        // When
        let matches = await index.searchTranscriptFallback(
            query: "why choose phoenix reliability",
            summarySessionIDs: [summarySessionID],
            recentSessionLimit: 4,
            limit: 3
        )

        // Then
        let scopeSnapshot = await loader.snapshot()
        XCTAssertEqual(scopeSnapshot.summarySessionIDs, [summarySessionID])
        XCTAssertEqual(scopeSnapshot.recentSessionLimit, 4)
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches[0].documentType, .transcript)
        XCTAssertEqual(matches[0].sessionID, summarySessionID)
        XCTAssertEqual(matches[0].turnNumber, 1)
        XCTAssertTrue(matches[0].content.contains("Because reliability was better under load."))
    }

    func test_searchTranscriptFallback_withoutSummaryScope_usesRecentSessionLimit() async throws {
        // Given
        let temporaryDirectoryURL = try self.makeTemporaryMemoryDirectory()
        defer {
            try? FileManager.default.removeItem(at: temporaryDirectoryURL)
        }

        let recentSessionID = UUID(uuidString: "12345678-1234-5678-9abc-def012345678")!
        let baseDate = Date(timeIntervalSince1970: 1_739_601_500)
        let recentMessages = [
            self.makeMessage(role: .user, content: "Why was Wednesday selected?"),
            self.makeMessage(role: .assistant, content: "It avoided all conflicts.")
        ]

        let loader = TranscriptScopeLoaderRecorder(
            summarySnapshots: [],
            recentSnapshots: [
                MemoryIndex.TranscriptSessionSnapshot(
                    sessionID: recentSessionID,
                    lastModified: baseDate,
                    messages: recentMessages
                )
            ]
        )
        let index = MemoryIndex(
            memoryDirectory: temporaryDirectoryURL,
            transcriptSessionLoader: { summarySessionIDs, recentSessionLimit in
                return await loader.load(
                    summarySessionIDs: summarySessionIDs,
                    recentSessionLimit: recentSessionLimit
                )
            },
            embeddingService: StubEmbeddingService()
        )
        await index.rebuild()

        // When
        let matches = await index.searchTranscriptFallback(
            query: "why selected conflicts",
            summarySessionIDs: [],
            recentSessionLimit: 2,
            limit: 3
        )

        // Then
        let scopeSnapshot = await loader.snapshot()
        XCTAssertTrue(scopeSnapshot.summarySessionIDs.isEmpty)
        XCTAssertEqual(scopeSnapshot.recentSessionLimit, 2)
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches[0].sessionID, recentSessionID)
        XCTAssertEqual(matches[0].turnNumber, 1)
    }

    private func makeTemporaryMemoryDirectory() throws -> URL {
        let temporaryDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let memoryDirectoryURL = temporaryDirectoryURL
            .appendingPathComponent("memory", isDirectory: true)
        try FileManager.default.createDirectory(at: memoryDirectoryURL, withIntermediateDirectories: true)
        return memoryDirectoryURL
    }

    private func makeMessage(role: Session.Message.Role, content: String) -> Session.Message {
        return Session.Message(
            id: UUID(),
            role: role,
            content: content,
            timestamp: Date(),
            metadata: nil
        )
    }
}
