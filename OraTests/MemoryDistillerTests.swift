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
        let response = index < self.responses.count
            ? self.responses[index]
            : #"{"summary":{"tldr":"","bullets":[],"decisions_and_commitments":[],"open_loops":[]},"memory_entries":[]}"#

        return AsyncThrowingStream { continuation in
            continuation.yield(.token(response))
            continuation.finish()
        }
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
        let documentsDirectory = self.temporaryDirectoryURL.appendingPathComponent("Documents", isDirectory: true)
        let verificationManager = MemoryFileManager(documentsDirectory: documentsDirectory)
        let messages = [
            Session.Message(
                id: UUID(),
                role: .user,
                content: "I prefer morning meetings and do deep work at 10.",
                timestamp: Date(timeIntervalSince1970: 1_739_616_600),
                metadata: nil
            ),
            Session.Message(
                id: UUID(),
                role: .assistant,
                content: "Noted. I'll keep that in mind.",
                timestamp: Date(timeIntervalSince1970: 1_739_616_620),
                metadata: nil
            )
        ]

        let distiller = MemoryDistiller(
            llm: mockLLM,
            memoryFileManager: MemoryFileManager(documentsDirectory: documentsDirectory),
            transcriptLoader: { requestedSessionID in
                return requestedSessionID == sessionID ? messages : nil
            },
            promptLoader: { "Return JSON only." }
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

    func test_distill_emptyTranscript_writesSummaryAndDoesNotAppendMemoryEntries() async throws {
        // Given
        let sessionID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let mockLLM = MemoryDistillerMockLLMService(responses: [])
        let documentsDirectory = self.temporaryDirectoryURL.appendingPathComponent("Documents", isDirectory: true)
        let setupManager = MemoryFileManager(documentsDirectory: documentsDirectory)
        let verificationManager = MemoryFileManager(documentsDirectory: documentsDirectory)

        try setupManager.ensureMemoryStructureExists()
        let baselineMemory = "# Ora Memory\n\nExisting memory line"
        try baselineMemory.write(to: verificationManager.memoryFileURL, atomically: true, encoding: .utf8)

        let distiller = MemoryDistiller(
            llm: mockLLM,
            memoryFileManager: MemoryFileManager(documentsDirectory: documentsDirectory),
            transcriptLoader: { requestedSessionID in
                return requestedSessionID == sessionID ? [] : nil
            },
            promptLoader: { "Return JSON only." }
        )

        // When
        let summary = await distiller.distill(sessionId: sessionID)

        // Then
        XCTAssertEqual(summary, SessionSummary())
        let llmCallCount = await mockLLM.generateCallCount
        XCTAssertEqual(llmCallCount, 0)

        let summaryURL = verificationManager.summaryFileURL(for: sessionID)
        XCTAssertTrue(FileManager.default.fileExists(atPath: summaryURL.path))

        let memoryContent = try String(contentsOf: verificationManager.memoryFileURL, encoding: .utf8)
        XCTAssertEqual(memoryContent, baselineMemory)
    }
}
