//
//  StructuredGeneratorTests.swift
//  OraTests
//
//  Tests for StructuredGenerator retry logic
//

import XCTest
@testable import Ora

final class StructuredGeneratorTests: XCTestCase {

    func test_generate_successOnFirstAttempt() async throws {
        let stub = StubLLMService(responses: ["{\"type\":\"response\",\"text\":\"Hi\"}"])
        let generator = StructuredGenerator(llm: stub)

        let output = try await generator.generate(messages: [LLMMessage(role: .user, content: "Hello")])

        XCTAssertEqual(output, .response(text: "Hi"))
        let callCount = await stub.generateCallCount
        XCTAssertEqual(callCount, 1)
    }

    func test_generate_retriesAfterInvalidJSON() async throws {
        let stub = StubLLMService(responses: ["not-json", "{\"type\":\"response\",\"text\":\"Retry\"}"])
        let generator = StructuredGenerator(llm: stub)
        let baseMessages = [LLMMessage(role: .user, content: "Hello")]

        let output = try await generator.generate(messages: baseMessages)

        XCTAssertEqual(output, .response(text: "Retry"))
        let callCount = await stub.generateCallCount
        let received = await stub.receivedMessages
        XCTAssertEqual(callCount, 2)
        XCTAssertEqual(received.count, 2)
        XCTAssertEqual(received[1].count, baseMessages.count + 2)
        XCTAssertEqual(received[1].suffix(2).first?.role, .assistant)
        XCTAssertEqual(received[1].suffix(2).first?.content, "not-json")
        XCTAssertEqual(received[1].suffix(2).last?.role, .user)
        let retryPrompt = received[1].suffix(2).last?.content ?? ""
        XCTAssertTrue(retryPrompt.contains("Your previous response was not valid JSON"))
    }

    func test_generate_throwsAfterMaxRetries() async {
        let stub = StubLLMService(responses: ["bad", "still bad", "nope"])
        let generator = StructuredGenerator(llm: stub)

        do {
            _ = try await generator.generate(messages: [LLMMessage(role: .user, content: "Hello")])
            XCTFail("Expected error")
        } catch let error as StructuredGeneratorError {
            if case .validationFailed(let attempts, let lastError) = error {
                XCTAssertEqual(attempts, 3)
                XCTAssertFalse(lastError.isEmpty)
            } else {
                XCTFail("Expected validationFailed")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let callCount = await stub.generateCallCount
        XCTAssertEqual(callCount, 3)
    }

    func test_structuredGeneratorError_description() {
        let error = StructuredGeneratorError.validationFailed(attempts: 2, lastError: "Missing field")
        XCTAssertEqual(
            error.errorDescription,
            "Failed to generate valid JSON after 2 attempts. Last error: Missing field"
        )
    }
}

private actor StubLLMService: LLMServicing {
    private let responses: [String]
    private(set) var generateCallCount = 0
    private(set) var receivedMessages: [[LLMMessage]] = []

    init(responses: [String]) {
        self.responses = responses
    }

    func generate(messages: [LLMMessage], maxTokens: Int) async -> AsyncThrowingStream<LLMDelta, Error> {
        let responseIndex = generateCallCount
        generateCallCount += 1
        receivedMessages.append(messages)

        let response = responseIndex < responses.count ? responses[responseIndex] : ""

        return AsyncThrowingStream { continuation in
            continuation.yield(.token(response))
            continuation.yield(.completed(totalTokens: response.count))
            continuation.finish()
        }
    }

    func warmup() async throws {}
    func prepare() async throws {}
    func unload() async {}
}
