//
//  AgentLoopPersistenceTests.swift
//  OraTests
//
//  Tests for AgentLoop persistence integration
//

import XCTest
@testable import Ora

enum AgentLoopPersistenceEvent: Equatable, Sendable {
    case persisted(role: Session.Message.Role, content: String)
    case generationStarted
}

actor AgentLoopPersistenceEventRecorder {
    private var events: [AgentLoopPersistenceEvent] = []

    func record(_ event: AgentLoopPersistenceEvent) {
        self.events.append(event)
    }

    func snapshot() -> [AgentLoopPersistenceEvent] {
        return self.events
    }
}

actor AgentLoopRecordingSessionLifecycleSink: AgentLoopSessionLifecycleSink {
    private let completedSessionID: UUID?
    private var callCount = 0

    init(completedSessionID: UUID?) {
        self.completedSessionID = completedSessionID
    }

    func completeActiveSession() async -> UUID? {
        self.callCount += 1
        return self.completedSessionID
    }

    func completionCallCount() -> Int {
        return self.callCount
    }
}

actor AgentLoopRecordingMemoryDistiller: MemoryDistilling {
    private var distilledSessionIDs: [UUID] = []

    func distill(sessionId: UUID) async -> SessionSummary? {
        self.distilledSessionIDs.append(sessionId)
        return SessionSummary()
    }

    func snapshot() -> [UUID] {
        return self.distilledSessionIDs
    }
}

struct PersistedMessageSnapshot: Equatable, Sendable {
    let role: Session.Message.Role
    let content: String
}

actor AgentLoopRecordingPersistenceSink: AgentLoopPersistenceSink {
    private var messages: [PersistedMessageSnapshot] = []
    private let eventRecorder: AgentLoopPersistenceEventRecorder?

    init(eventRecorder: AgentLoopPersistenceEventRecorder? = nil) {
        self.eventRecorder = eventRecorder
    }

    func appendMessage(role: Session.Message.Role, content: String) async throws {
        self.messages.append(PersistedMessageSnapshot(role: role, content: content))
        if let eventRecorder = self.eventRecorder {
            await eventRecorder.record(.persisted(role: role, content: content))
        }
    }

    func persistedMessages() -> [PersistedMessageSnapshot] {
        return self.messages
    }
}

actor AgentLoopPersistenceMockLLMService: LLMServicing {
    private let responsePayload: String
    private let shouldFail: Bool
    private let eventRecorder: AgentLoopPersistenceEventRecorder?

    init(
        responsePayload: String = #"{"type":"response","text":"Default"}"#,
        shouldFail: Bool = false,
        eventRecorder: AgentLoopPersistenceEventRecorder? = nil
    ) {
        self.responsePayload = responsePayload
        self.shouldFail = shouldFail
        self.eventRecorder = eventRecorder
    }

    func warmup() async throws {}
    func prepare() async throws {}
    func unload() async {}
    func clearCache() async {}

    func generate(messages: [LLMMessage], maxTokens: Int) async -> AsyncThrowingStream<LLMDelta, Error> {
        if let eventRecorder = self.eventRecorder {
            await eventRecorder.record(.generationStarted)
        }

        if self.shouldFail {
            return AsyncThrowingStream { continuation in
                continuation.finish(throwing: ProviderError.noCredential(.openai))
            }
        }

        let responsePayload = self.responsePayload
        return AsyncThrowingStream { continuation in
            continuation.yield(.token(responsePayload))
            continuation.finish()
        }
    }
}

final class AgentLoopPersistenceTests: XCTestCase {

    func test_process_userMessagePersistenceBeforeGeneration_persistsBeforeLLMInference() async throws {
        // Given
        let userText = "user-\(UUID().uuidString)"
        let eventRecorder = AgentLoopPersistenceEventRecorder()
        let persistenceSink = AgentLoopRecordingPersistenceSink(eventRecorder: eventRecorder)
        let llmService = AgentLoopPersistenceMockLLMService(
            responsePayload: #"{"type":"response","text":"Assistant"}"#,
            eventRecorder: eventRecorder
        )
        let loop = self.makeLoop(llmService: llmService, persistenceSink: persistenceSink)

        // When
        _ = try await loop.process(userText: userText)

        // Then
        let events = await eventRecorder.snapshot()
        let persistedUserIndex = events.firstIndex(of: .persisted(role: .user, content: userText))
        let generationStartIndex = events.firstIndex(of: .generationStarted)

        XCTAssertNotNil(persistedUserIndex, "User message should be persisted")
        XCTAssertNotNil(generationStartIndex, "LLM generation should start")

        if let persistedUserIndex, let generationStartIndex {
            XCTAssertLessThan(
                persistedUserIndex,
                generationStartIndex,
                "User message must persist before LLM inference begins"
            )
        }
    }

    func test_process_llmFailure_persistsUserMessageWithoutAssistantMessage() async throws {
        // Given
        let userText = "user-\(UUID().uuidString)"
        let persistenceSink = AgentLoopRecordingPersistenceSink()
        let llmService = AgentLoopPersistenceMockLLMService(shouldFail: true)
        let loop = self.makeLoop(llmService: llmService, persistenceSink: persistenceSink)

        // When
        _ = try await loop.process(userText: userText)

        // Then
        let persistedMessages = await persistenceSink.persistedMessages()
        XCTAssertEqual(persistedMessages.count, 1)
        XCTAssertEqual(persistedMessages.first?.role, .user)
        XCTAssertEqual(persistedMessages.first?.content, userText)
    }

    func test_process_success_persistsAssistantAfterGenerationCompletes() async throws {
        // Given
        let userText = "user-\(UUID().uuidString)"
        let assistantText = "assistant-\(UUID().uuidString)"
        let eventRecorder = AgentLoopPersistenceEventRecorder()
        let persistenceSink = AgentLoopRecordingPersistenceSink(eventRecorder: eventRecorder)
        let llmService = AgentLoopPersistenceMockLLMService(
            responsePayload: #"{"type":"response","text":"\#(assistantText)"}"#,
            eventRecorder: eventRecorder
        )
        let loop = self.makeLoop(llmService: llmService, persistenceSink: persistenceSink)

        // When
        _ = try await loop.process(userText: userText)

        // Then
        let persistedMessages = await persistenceSink.persistedMessages()
        XCTAssertEqual(
            persistedMessages,
            [
                PersistedMessageSnapshot(role: .user, content: userText),
                PersistedMessageSnapshot(role: .assistant, content: assistantText)
            ]
        )

        let events = await eventRecorder.snapshot()
        let generationStartIndex = events.firstIndex(of: .generationStarted)
        let persistedAssistantIndex = events.firstIndex(of: .persisted(role: .assistant, content: assistantText))

        XCTAssertNotNil(generationStartIndex, "LLM generation should start")
        XCTAssertNotNil(persistedAssistantIndex, "Assistant message should be persisted")

        if let generationStartIndex, let persistedAssistantIndex {
            XCTAssertGreaterThan(
                persistedAssistantIndex,
                generationStartIndex,
                "Assistant message should persist only after generation completes"
            )
        }
    }

    func test_endSession_completesActiveSession_andTriggersMemoryDistillation() async throws {
        // Given
        let expectedSessionID = UUID()
        let sessionLifecycleSink = AgentLoopRecordingSessionLifecycleSink(completedSessionID: expectedSessionID)
        let memoryDistiller = AgentLoopRecordingMemoryDistiller()
        let loop = self.makeLoop(
            llmService: AgentLoopPersistenceMockLLMService(),
            persistenceSink: AgentLoopRecordingPersistenceSink(),
            sessionLifecycleSink: sessionLifecycleSink,
            memoryDistiller: memoryDistiller
        )

        await loop.startSession()

        // When
        await loop.endSession()
        try await Task.sleep(for: .milliseconds(50))

        // Then
        let callCount = await sessionLifecycleSink.completionCallCount()
        XCTAssertEqual(callCount, 1)

        let distilledSessionIDs = await memoryDistiller.snapshot()
        XCTAssertEqual(distilledSessionIDs, [expectedSessionID])
    }

    private func makeLoop(
        llmService: LLMServicing,
        persistenceSink: AgentLoopPersistenceSink,
        sessionLifecycleSink: AgentLoopSessionLifecycleSink = AgentLoopRecordingSessionLifecycleSink(completedSessionID: nil),
        memoryDistiller: any MemoryDistilling = AgentLoopRecordingMemoryDistiller()
    ) -> AgentLoop {
        return AgentLoop(
            maxStepsPerTurn: 4,
            maxToolCallsPerTurn: 2,
            maxTokensPerTurn: 800,
            structuredGenerator: StructuredGenerator(llm: llmService),
            toolHost: .shared,
            toolRegistry: ToolRegistry.makeTestInstance(),
            conversationManager: ConversationManager.makeTestInstance(maxContextTokens: 6000),
            persistenceSink: persistenceSink,
            sessionLifecycleSink: sessionLifecycleSink,
            memoryDistiller: memoryDistiller
        )
    }
}
