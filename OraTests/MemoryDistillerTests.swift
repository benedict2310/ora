//
//  MemoryDistillerTests.swift
//  OraTests
//
//  Tests for memory distillation pipeline.
//

import XCTest
@testable import Ora

actor MemoryDistillerMockLLMService: LLMServicing {

    private let responses: [String]
    private(set) var generateCallCount = 0
    private(set) var generatedMessages: [[LLMMessage]] = []

    init(responses: [String]) {
        self.responses = responses
    }

    func prepare() async throws {}
    func warmup() async throws {}
    func unload() async {}
    func clearCache() async {}

    func generate(messages: [LLMMessage], maxTokens: Int) async -> AsyncThrowingStream<LLMDelta, Error> {
        let index = self.generateCallCount
        self.generateCallCount += 1
        self.generatedMessages.append(messages)
        let response = index < self.responses.count
            ? self.responses[index]
            : #"{"summary":{"tldr":"","bullets":[],"decisions_and_commitments":[],"open_loops":[]},"memory_entries":[]}"#

        return AsyncThrowingStream { continuation in
            continuation.yield(.token(response))
            continuation.finish()
        }
    }
}

actor MemoryDistillerMockMemoryIndex: MemoryIndexing {
    private(set) var rebuildCallCount = 0

    func rebuild() async {
        self.rebuildCallCount += 1
    }

    func search(query: String, limit: Int) async -> [MemoryChunk] {
        return []
    }
}

final class MemoryDistillerTests: XCTestCase {

    // MARK: - Properties

    private var temporaryDirectoryURL: URL!

    // MARK: - Setup

    override func setUpWithError() throws {
        self.temporaryDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: self.temporaryDirectoryURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let temporaryDirectoryURL = self.temporaryDirectoryURL {
            try? FileManager.default.removeItem(at: temporaryDirectoryURL)
        }
        self.temporaryDirectoryURL = nil
    }

    // MARK: - Tests

    func test_distill_validTranscript_writesSummaryAndAppendsMemoryEntries() async throws {
        // Given
        let sessionID = UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!
        let response = #"{"summary":{"tldr":"User prefers morning meetings.","bullets":["Discussed recurring planning sync."],"decisions_and_commitments":[{"decision":"Move sync to 9am","rationale":"Improves focus time","timestamp":"2026-02-15T09:30:00Z"}],"open_loops":["Confirm Thursday slot with design team."]},"memory_entries":[{"section":"preferences","tag":"preference","content":"User prefers morning meetings.","normalized_key":"pref:meeting:morning"},{"section":"projects","tag":"fact","content":"User starts deep work at 10am."}]}"#

        let mockLLM = MemoryDistillerMockLLMService(responses: [response])
        let memoryDirectory = self.temporaryDirectoryURL.appendingPathComponent("memory", isDirectory: true)
        let verificationManager = MemoryFileManager(memoryDirectory: memoryDirectory)
        let messages = [
            Session.Message(
                id: UUID(),
                role: .user,
                content: "I prefer morning meetings and do deep work at 10 because afternoons are full of interruptions.",
                timestamp: Date(timeIntervalSince1970: 1_739_616_600),
                metadata: nil
            ),
            Session.Message(
                id: UUID(),
                role: .assistant,
                content: "Noted. I'll keep that in mind.",
                timestamp: Date(timeIntervalSince1970: 1_739_616_620),
                metadata: nil
            ),
            Session.Message(
                id: UUID(),
                role: .user,
                content: "Please also remember that I usually start planning sessions at 8:30 on weekdays.",
                timestamp: Date(timeIntervalSince1970: 1_739_616_650),
                metadata: nil
            ),
            Session.Message(
                id: UUID(),
                role: .assistant,
                content: "Understood.",
                timestamp: Date(timeIntervalSince1970: 1_739_616_670),
                metadata: nil
            ),
            Session.Message(
                id: UUID(),
                role: .user,
                content: "That schedule preference has stayed consistent for months and should remain my default.",
                timestamp: Date(timeIntervalSince1970: 1_739_616_700),
                metadata: nil
            )
        ]

        let mockMemoryIndex = MemoryDistillerMockMemoryIndex()
        let distiller = MemoryDistiller(
            llm: mockLLM,
            memoryFileManager: MemoryFileManager(memoryDirectory: memoryDirectory),
            memoryIndex: mockMemoryIndex,
            transcriptLoader: { requestedSessionID in
                return requestedSessionID == sessionID ? messages : nil
            },
            promptLoader: { "Return JSON only." },
            gpuCacheClearer: { }
        )

        // When
        let summary = await distiller.distill(sessionId: sessionID)

        // Then
        XCTAssertEqual(summary?.tldr, "User prefers morning meetings.")
        XCTAssertEqual(summary?.bullets, ["Discussed recurring planning sync."])
        XCTAssertEqual(summary?.openLoops, ["Confirm Thursday slot with design team."])

        let summaryURL = verificationManager.summaryFileURL(for: sessionID)
        XCTAssertTrue(FileManager.default.fileExists(atPath: summaryURL.path))

        let summaryContent = try String(contentsOf: summaryURL, encoding: .utf8)
        XCTAssertTrue(summaryContent.contains("User prefers morning meetings."))
        XCTAssertTrue(summaryContent.contains("## Decisions & Commitments"))

        let memoryContent = try String(contentsOf: verificationManager.memoryFileURL, encoding: .utf8)
        XCTAssertTrue(memoryContent.contains("User prefers morning meetings."))
        XCTAssertTrue(memoryContent.contains("User starts deep work at 10am."))
    }

    func test_distill_transcriptWithToolMessages_excludesToolMessagesFromPrompt() async throws {
        // Given
        let sessionID = UUID(uuidString: "12121212-3434-5656-7878-909090909090")!
        let response = #"{"summary":{"tldr":"Captured durable preferences.","bullets":[],"decisions_and_commitments":[],"open_loops":[]},"memory_entries":[]}"#
        let mockLLM = MemoryDistillerMockLLMService(responses: [response])
        let memoryDirectory = self.temporaryDirectoryURL.appendingPathComponent("memory", isDirectory: true)
        let toolMessage = "[ToolResult: calendar.create] Created event (auditId=abcd)"
        let messages = self.makeEligibleMessages(includeToolMessage: true, toolMessageContent: toolMessage)
        let mockMemoryIndex = MemoryDistillerMockMemoryIndex()
        let distiller = MemoryDistiller(
            llm: mockLLM,
            memoryFileManager: MemoryFileManager(memoryDirectory: memoryDirectory),
            memoryIndex: mockMemoryIndex,
            transcriptLoader: { requestedSessionID in
                return requestedSessionID == sessionID ? messages : nil
            },
            promptLoader: { "Return JSON only." },
            gpuCacheClearer: { }
        )

        // When
        _ = await distiller.distill(sessionId: sessionID)

        // Then
        let generatedMessages = await mockLLM.generatedMessages
        let llmMessages = try XCTUnwrap(generatedMessages.first)
        let userPrompt = try XCTUnwrap(llmMessages.first(where: { $0.role == .user })?.content)
        XCTAssertFalse(userPrompt.contains(toolMessage))
        XCTAssertTrue(userPrompt.contains("Transcript:"))
        XCTAssertTrue(userPrompt.contains("Here is what Ora already remembers (MEMORY.md):"))
    }

    func test_distill_emptyTranscript_returnsNilAndDoesNotWriteSummary() async throws {
        // Given
        let sessionID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let mockLLM = MemoryDistillerMockLLMService(responses: [])
        let memoryDirectory = self.temporaryDirectoryURL.appendingPathComponent("memory", isDirectory: true)
        let setupManager = MemoryFileManager(memoryDirectory: memoryDirectory)
        let verificationManager = MemoryFileManager(memoryDirectory: memoryDirectory)

        try setupManager.ensureMemoryStructureExists()
        let baselineMemory = "# Ora Memory\n\nExisting memory line"
        try baselineMemory.write(to: verificationManager.memoryFileURL, atomically: true, encoding: .utf8)

        let mockMemoryIndex = MemoryDistillerMockMemoryIndex()
        let distiller = MemoryDistiller(
            llm: mockLLM,
            memoryFileManager: MemoryFileManager(memoryDirectory: memoryDirectory),
            memoryIndex: mockMemoryIndex,
            transcriptLoader: { requestedSessionID in
                return requestedSessionID == sessionID ? [] : nil
            },
            promptLoader: { "Return JSON only." },
            gpuCacheClearer: { }
        )

        // When
        let summary = await distiller.distill(sessionId: sessionID)

        // Then
        XCTAssertNil(summary)
        let llmCallCount = await mockLLM.generateCallCount
        XCTAssertEqual(llmCallCount, 0)

        let summaryURL = verificationManager.summaryFileURL(for: sessionID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: summaryURL.path))

        let memoryContent = try String(contentsOf: verificationManager.memoryFileURL, encoding: .utf8)
        XCTAssertTrue(memoryContent.contains("Existing memory line"))
        XCTAssertFalse(memoryContent.contains("(source:"))
    }

    func test_distill_belowThreshold_returnsNilAndDoesNotWriteSummary() async throws {
        // Given
        let sessionID = UUID(uuidString: "abababab-cdcd-efef-0101-121212121212")!
        let mockLLM = MemoryDistillerMockLLMService(responses: [])
        let mockMemoryIndex = MemoryDistillerMockMemoryIndex()
        let memoryDirectory = self.temporaryDirectoryURL.appendingPathComponent("memory", isDirectory: true)
        let distillerManager = MemoryFileManager(memoryDirectory: memoryDirectory)
        let verificationManager = MemoryFileManager(memoryDirectory: memoryDirectory)
        let messages = [
            Session.Message(
                id: UUID(),
                role: .user,
                content: "This is message one with enough characters to matter for testing.",
                timestamp: Date(timeIntervalSince1970: 1_739_700_000),
                metadata: nil
            ),
            Session.Message(
                id: UUID(),
                role: .assistant,
                content: "ack",
                timestamp: Date(timeIntervalSince1970: 1_739_700_005),
                metadata: nil
            ),
            Session.Message(
                id: UUID(),
                role: .user,
                content: "Second message still below count threshold.",
                timestamp: Date(timeIntervalSince1970: 1_739_700_010),
                metadata: nil
            )
        ]
        let distiller = MemoryDistiller(
            llm: mockLLM,
            memoryFileManager: distillerManager,
            memoryIndex: mockMemoryIndex,
            transcriptLoader: { requestedSessionID in
                return requestedSessionID == sessionID ? messages : nil
            },
            promptLoader: { "Return JSON only." },
            gpuCacheClearer: { }
        )

        // When
        let summary = await distiller.distill(sessionId: sessionID)

        // Then
        XCTAssertNil(summary)
        let llmCallCount = await mockLLM.generateCallCount
        XCTAssertEqual(llmCallCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: verificationManager.summaryFileURL(for: sessionID).path))
    }

    func test_distill_promptIncludesExistingMemoryContext() async throws {
        // Given
        let sessionID = UUID(uuidString: "31313131-4242-5353-6464-757575757575")!
        let response = #"{"summary":{"tldr":"","bullets":[],"decisions_and_commitments":[],"open_loops":[]},"memory_entries":[]}"#
        let mockLLM = MemoryDistillerMockLLMService(responses: [response])
        let mockMemoryIndex = MemoryDistillerMockMemoryIndex()
        let memoryDirectory = self.temporaryDirectoryURL.appendingPathComponent("memory", isDirectory: true)
        let manager = MemoryFileManager(memoryDirectory: memoryDirectory)
        try manager.ensureMemoryStructureExists()
        let existingMemory = """
# Ora Memory

## Profile
- [fact] Name is Alex

## Preferences
- [preference] Prefers evening workouts

## People

## Projects

## Ongoing Goals
"""
        try existingMemory.write(to: manager.memoryFileURL, atomically: true, encoding: .utf8)
        let eligibleMessages = self.makeEligibleMessages()

        let distiller = MemoryDistiller(
            llm: mockLLM,
            memoryFileManager: manager,
            memoryIndex: mockMemoryIndex,
            transcriptLoader: { requestedSessionID in
                return requestedSessionID == sessionID ? eligibleMessages : nil
            },
            promptLoader: { "Return JSON only." },
            gpuCacheClearer: { }
        )

        // When
        _ = await distiller.distill(sessionId: sessionID)

        // Then
        let generatedMessages = await mockLLM.generatedMessages
        let llmMessages = try XCTUnwrap(generatedMessages.first)
        let userPrompt = try XCTUnwrap(llmMessages.first(where: { $0.role == .user })?.content)
        XCTAssertTrue(userPrompt.contains("Prefers evening workouts"))
        XCTAssertTrue(userPrompt.contains("Only extract NEW information not already captured above."))
    }

    func test_distill_lowValueEntriesDroppedAndOutputCappedAtEight() async throws {
        // Given
        let sessionID = UUID(uuidString: "91919191-8282-7373-6464-555555555555")!
        let mockMemoryIndex = MemoryDistillerMockMemoryIndex()
        let memoryDirectory = self.temporaryDirectoryURL.appendingPathComponent("memory", isDirectory: true)
        let distillerManager = MemoryFileManager(memoryDirectory: memoryDirectory)
        let verificationManager = MemoryFileManager(memoryDirectory: memoryDirectory)
        let memoryEntries: [[String: String]] = [
            ["section": "profile", "tag": "fact", "content": "Created 3 items using reminders tool"],
            ["section": "profile", "tag": "fact", "content": "Entry references audit ID 123 and should be dropped."],
            ["section": "profile", "tag": "fact", "content": "Contains uuid 123e4567-e89b-12d3-a456-426614174000 in content."],
            ["section": "preferences", "tag": "fact", "content": "User greeted the assistant warmly during onboarding."],
            ["section": "projects", "tag": "fact", "content": "too short"],
            ["section": "profile", "tag": "fact", "content": "Name is Alex Moreno and this should persist as durable profile data."],
            ["section": "preferences", "tag": "preference", "content": "Prefers evening workouts after 7pm and avoids early gym sessions."],
            ["section": "people", "tag": "fact", "content": "Maddie is Alex's partner and regular calendar collaborator for family planning."],
            ["section": "projects", "tag": "fact", "content": "Leading the Atlas migration project focused on replacing legacy onboarding systems."],
            ["section": "ongoing_goals", "tag": "fact", "content": "Training for a half marathon with three scheduled runs every week."],
            ["section": "preferences", "tag": "preference", "content": "Keeps notifications muted during deep work blocks from 9am to noon."],
            ["section": "projects", "tag": "fact", "content": "Preparing a quarterly roadmap review for the leadership team and design org."],
            ["section": "ongoing_goals", "tag": "fact", "content": "Practicing conversational German daily with vocabulary review and speaking drills."]
        ]
        let response = try self.makeResponse(memoryEntries: memoryEntries)
        let mockLLM = MemoryDistillerMockLLMService(responses: [response])
        let eligibleMessages = self.makeEligibleMessages()
        let distiller = MemoryDistiller(
            llm: mockLLM,
            memoryFileManager: distillerManager,
            memoryIndex: mockMemoryIndex,
            transcriptLoader: { requestedSessionID in
                return requestedSessionID == sessionID ? eligibleMessages : nil
            },
            promptLoader: { "Return JSON only." },
            gpuCacheClearer: { }
        )

        // When
        _ = await distiller.distill(sessionId: sessionID)

        // Then
        let memoryContent = try String(contentsOf: verificationManager.memoryFileURL, encoding: .utf8)
        XCTAssertFalse(memoryContent.contains("Created 3 items using reminders tool"))
        XCTAssertFalse(memoryContent.contains("audit ID 123"))
        XCTAssertFalse(memoryContent.contains("123e4567-e89b-12d3-a456-426614174000"))
        XCTAssertFalse(memoryContent.contains("User greeted the assistant"))
        XCTAssertFalse(memoryContent.contains("too short"))

        let entryCount = memoryContent.components(separatedBy: "\n- [").count - 1
        XCTAssertEqual(entryCount, 8)
    }

    func test_distill_emptyTranscript_doesNotTriggerMemoryIndexRebuild() async throws {
        // Given
        let sessionID = UUID(uuidString: "66666666-7777-8888-9999-aaaaaaaaaaaa")!
        let mockLLM = MemoryDistillerMockLLMService(responses: [])
        let mockMemoryIndex = MemoryDistillerMockMemoryIndex()
        let memoryDirectory = self.temporaryDirectoryURL.appendingPathComponent("memory", isDirectory: true)

        let distiller = MemoryDistiller(
            llm: mockLLM,
            memoryFileManager: MemoryFileManager(memoryDirectory: memoryDirectory),
            memoryIndex: mockMemoryIndex,
            transcriptLoader: { requestedSessionID in
                return requestedSessionID == sessionID ? [] : nil
            },
            promptLoader: { "Return JSON only." },
            gpuCacheClearer: { }
        )

        // When
        _ = await distiller.distill(sessionId: sessionID)

        // Then
        let rebuildCallCount = await mockMemoryIndex.rebuildCallCount
        XCTAssertEqual(rebuildCallCount, 0)
    }

    // MARK: - Helpers

    private func makeEligibleMessages(
        includeToolMessage: Bool = false,
        toolMessageContent: String = "[ToolResult: reminder.create] Created item (auditId=123)"
    ) -> [Session.Message] {
        var messages = [
            Session.Message(
                id: UUID(),
                role: .user,
                content: "My name is Alex and I have been organizing my schedule around evening workouts after work.",
                timestamp: Date(timeIntervalSince1970: 1_739_616_600),
                metadata: nil
            ),
            Session.Message(
                id: UUID(),
                role: .assistant,
                content: "Got it.",
                timestamp: Date(timeIntervalSince1970: 1_739_616_620),
                metadata: nil
            ),
            Session.Message(
                id: UUID(),
                role: .user,
                content: "I also prefer planning meetings in the morning because my afternoons are booked most days.",
                timestamp: Date(timeIntervalSince1970: 1_739_616_640),
                metadata: nil
            ),
            Session.Message(
                id: UUID(),
                role: .assistant,
                content: "Noted.",
                timestamp: Date(timeIntervalSince1970: 1_739_616_660),
                metadata: nil
            ),
            Session.Message(
                id: UUID(),
                role: .user,
                content: "Please remember these preferences for future scheduling decisions over the next few months.",
                timestamp: Date(timeIntervalSince1970: 1_739_616_680),
                metadata: nil
            )
        ]

        if includeToolMessage {
            messages.append(
                Session.Message(
                    id: UUID(),
                    role: .tool,
                    content: toolMessageContent,
                    timestamp: Date(timeIntervalSince1970: 1_739_616_700),
                    metadata: nil
                )
            )
        }

        return messages
    }

    private func makeResponse(memoryEntries: [[String: String]]) throws -> String {
        let payload: [String: Any] = [
            "summary": [
                "tldr": "Summary",
                "bullets": [],
                "decisions_and_commitments": [],
                "open_loops": []
            ],
            "memory_entries": memoryEntries
        ]

        let data = try JSONSerialization.data(withJSONObject: payload, options: [])
        return try XCTUnwrap(String(data: data, encoding: .utf8))
    }
}
