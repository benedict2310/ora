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
        XCTAssertEqual(received[1].count, baseMessages.count + 1)
        XCTAssertEqual(received[1].last?.role, .user)
        let retryPrompt = received[1].last?.content ?? ""
        XCTAssertTrue(retryPrompt.contains("Your previous response was not valid JSON"))
        XCTAssertTrue(retryPrompt.contains("Previous invalid response"))
        XCTAssertTrue(retryPrompt.contains("not-json"))
    }

    func test_generate_streamsOnlySuccessfulAttemptFragments() async throws {
        let stub = StubLLMService(
            responses: [
                "{\"type\":\"response\",\"text\":\"First\" trailing",
                "{\"type\":\"response\",\"text\":\"Second\"}",
            ]
        )
        let generator = StructuredGenerator(llm: stub)
        let collector = FragmentCollector()

        let output = try await generator.generate(
            messages: [LLMMessage(role: .user, content: "Hello")],
            responseTokenHandler: { token in
                await collector.append(token)
            }
        )

        let streamedFragments = await collector.values()
        XCTAssertEqual(output, .response(text: "Second"))
        XCTAssertEqual(streamedFragments, ["Second"])
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

    func test_generate_streamFailureAfterValidationFailure_resetsToBaseMessages() async throws {
        let scripted = ScriptedStubLLMService(steps: [
            .response("not-json"),
            .requestFailure400("invalid_request_error: Invalid role in input"),
            .response("{\"type\":\"response\",\"text\":\"Recovered\"}"),
        ])
        let generator = StructuredGenerator(llm: scripted)
        let baseMessages = [LLMMessage(role: .user, content: "Hello")]

        let output = try await generator.generate(messages: baseMessages)

        XCTAssertEqual(output, .response(text: "Recovered"))
        let callCount = await scripted.generateCallCount
        let received = await scripted.receivedMessages
        XCTAssertEqual(callCount, 3)
        XCTAssertEqual(received.count, 3)
        XCTAssertEqual(received[0].count, baseMessages.count)
        XCTAssertEqual(received[0].first?.role, .user)
        XCTAssertEqual(received[0].first?.content, "Hello")
        XCTAssertEqual(received[1].count, baseMessages.count + 1)
        XCTAssertEqual(received[1].last?.role, .user)
        XCTAssertEqual(received[2].count, baseMessages.count)
        XCTAssertEqual(received[2].first?.role, .user)
        XCTAssertEqual(received[2].first?.content, "Hello")
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
    func clearCache() async {}
}

private actor FragmentCollector {
    private var fragments: [String] = []

    func append(_ value: String) {
        self.fragments.append(value)
    }

    func values() -> [String] {
        return self.fragments
    }
}

private actor ScriptedStubLLMService: LLMServicing {
    enum Step: Sendable {
        case response(String)
        case requestFailure400(String)
    }

    private let steps: [Step]
    private(set) var generateCallCount = 0
    private(set) var receivedMessages: [[LLMMessage]] = []

    init(steps: [Step]) {
        self.steps = steps
    }

    func generate(messages: [LLMMessage], maxTokens: Int) async -> AsyncThrowingStream<LLMDelta, Error> {
        let index = generateCallCount
        generateCallCount += 1
        receivedMessages.append(messages)

        let step = index < steps.count ? steps[index] : .response("")

        return AsyncThrowingStream { continuation in
            switch step {
            case .response(let text):
                continuation.yield(.token(text))
                continuation.yield(.completed(totalTokens: text.count))
                continuation.finish()
            case .requestFailure400(let body):
                continuation.finish(throwing: CloudProviderError.requestFailed(statusCode: 400, body: body))
            }
        }
    }

    func warmup() async throws {}
    func prepare() async throws {}
    func unload() async {}
    func clearCache() async {}
}
