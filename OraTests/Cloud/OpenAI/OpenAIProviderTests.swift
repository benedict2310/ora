//
//  OpenAIProviderTests.swift
//  OraTests
//
//  Tests for OpenAI Chat Completions provider
//

import Foundation
import XCTest
@testable import Ora

final class OpenAIProviderTests: XCTestCase {

    // MARK: - XCTest

    override func tearDown() async throws {
        OpenAIMockURLProtocol.reset()
    }

    // MARK: - Tests

    func test_factory_createsProvider() throws {
        // Given
        let factory = OpenAIProviderFactory(model: OpenAIModel.gpt4oMini.rawValue)

        // When
        let provider = try factory.create(apiKey: "sk-test-key")

        // Then
        XCTAssertTrue(provider is OpenAIProvider)
    }

    func test_models_haveCorrectDisplayNames() {
        // Given/When/Then
        XCTAssertEqual(OpenAIModel.gpt52.displayName, "GPT-5.2")
        XCTAssertEqual(OpenAIModel.gpt4o.displayName, "GPT-4o")
        XCTAssertEqual(OpenAIModel.gpt4oMini.displayName, "GPT-4o Mini")
        XCTAssertEqual(OpenAIModel.o3Mini.displayName, "o3-mini")
    }

    func test_generate_streams_tokens() async throws {
        // Given
        OpenAIMockURLProtocol.setHandler { _, _ in
            .sse(events: [
                #"{"id":"r1","choices":[{"delta":{"role":"assistant"}}]}"#,
                #"{"id":"r1","choices":[{"delta":{"content":"Hello"}}]}"#,
                #"{"id":"r1","choices":[{"delta":{"content":" world"}}]}"#,
                #"{"id":"r1","choices":[{"finish_reason":"stop"}],"usage":{"completion_tokens":5}}"#,
                "[DONE]",
            ])
        }
        let provider = self.makeProvider()

        // When
        let deltas = try await self.collectDeltas(
            from: await provider.generate(
                messages: [LLMMessage(role: .user, content: "Say hello")],
                maxTokens: 32
            )
        )

        // Then
        XCTAssertEqual(self.tokenTexts(in: deltas), ["Hello", " world"])
        XCTAssertEqual(self.completionTokens(in: deltas), 5)
    }

    func test_systemMessage_inlineInMessages() async throws {
        // Given
        var capturedBody: [String: Any]?
        OpenAIMockURLProtocol.setHandler { request, _ in
            if let body = self.requestBodyData(from: request) {
                capturedBody = try JSONSerialization.jsonObject(with: body) as? [String: Any]
            }
            return .sse(events: ["[DONE]"])
        }
        let provider = self.makeProvider()

        // When
        _ = try await self.collectDeltas(
            from: await provider.generate(
                messages: [
                    LLMMessage(role: .system, content: "System instruction"),
                    LLMMessage(role: .user, content: "Hi"),
                ],
                maxTokens: 32
            )
        )

        // Then
        XCTAssertNil(capturedBody?["system"])
        let messages = try XCTUnwrap(capturedBody?["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[0]["role"] as? String, "system")
        XCTAssertEqual(messages[1]["role"] as? String, "user")
    }

    func test_generate_usesMaxCompletionTokens() async throws {
        // Given
        var capturedBody: [String: Any]?
        OpenAIMockURLProtocol.setHandler { request, _ in
            if let body = self.requestBodyData(from: request) {
                capturedBody = try JSONSerialization.jsonObject(with: body) as? [String: Any]
            }
            return .sse(events: ["[DONE]"])
        }
        let provider = self.makeProvider()

        // When
        _ = try await self.collectDeltas(
            from: await provider.generate(
                messages: [LLMMessage(role: .user, content: "Hi")],
                maxTokens: 128
            )
        )

        // Then
        XCTAssertEqual(capturedBody?["max_completion_tokens"] as? Int, 128)
        XCTAssertNil(capturedBody?["max_tokens"])
    }

    func test_toolRole_mappedToUser() async throws {
        // Given
        var capturedBody: [String: Any]?
        OpenAIMockURLProtocol.setHandler { request, _ in
            if let body = self.requestBodyData(from: request) {
                capturedBody = try JSONSerialization.jsonObject(with: body) as? [String: Any]
            }
            return .sse(events: ["[DONE]"])
        }
        let provider = self.makeProvider()

        // When
        _ = try await self.collectDeltas(
            from: await provider.generate(
                messages: [LLMMessage(role: .tool, content: #"{"result":"ok"}"#)],
                maxTokens: 32
            )
        )

        // Then
        let messages = try XCTUnwrap(capturedBody?["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0]["role"] as? String, "user")
    }

    func test_done_sentinel_completesStream() async throws {
        // Given
        OpenAIMockURLProtocol.setHandler { _, _ in
            .sse(events: ["[DONE]"])
        }
        let provider = self.makeProvider()

        // When
        let deltas = try await self.collectDeltas(
            from: await provider.generate(
                messages: [LLMMessage(role: .user, content: "Hi")],
                maxTokens: 32
            )
        )

        // Then
        XCTAssertEqual(deltas.count, 1)
        XCTAssertEqual(self.completionTokens(in: deltas), 0)
    }

    func test_usage_in_final_chunk() async throws {
        // Given
        OpenAIMockURLProtocol.setHandler { _, _ in
            .sse(events: [
                #"{"choices":[{"delta":{"content":"A"}}]}"#,
                #"{"choices":[{"finish_reason":"stop"}],"usage":{"completion_tokens":42}}"#,
                "[DONE]",
            ])
        }
        let provider = self.makeProvider()

        // When
        let deltas = try await self.collectDeltas(
            from: await provider.generate(
                messages: [LLMMessage(role: .user, content: "Count tokens")],
                maxTokens: 64
            )
        )

        // Then
        XCTAssertEqual(self.tokenTexts(in: deltas), ["A"])
        XCTAssertEqual(self.completionTokens(in: deltas), 42)
    }

    func test_401_throwsAuthError() async throws {
        // Given
        OpenAIMockURLProtocol.setHandler { _, _ in
            .json(
                statusCode: 401,
                body: #"{"error":{"message":"invalid_api_key"}}"#
            )
        }
        let provider = self.makeProvider()

        // When/Then
        do {
            _ = try await self.collectDeltas(
                from: await provider.generate(
                    messages: [LLMMessage(role: .user, content: "Hi")],
                    maxTokens: 32
                )
            )
            XCTFail("Expected authentication error")
        } catch let error as CloudProviderError {
            guard case .authenticationFailed(let message) = error else {
                return XCTFail("Unexpected CloudProviderError: \(error)")
            }
            XCTAssertTrue(message.contains("invalid_api_key"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func test_429_retriesWithBackoff() async throws {
        // Given
        OpenAIMockURLProtocol.setHandler { _, requestIndex in
            if requestIndex == 0 {
                return .json(
                    statusCode: 429,
                    body: #"{"error":{"message":"rate_limited"}}"#
                )
            }
            return .sse(events: [
                #"{"choices":[{"delta":{"content":"Retry success"}}]}"#,
                "[DONE]",
            ])
        }
        let provider = self.makeProvider(baseRetryDelay: 0.01)

        // When
        let start = Date()
        let deltas = try await self.collectDeltas(
            from: await provider.generate(
                messages: [LLMMessage(role: .user, content: "Retry please")],
                maxTokens: 32
            )
        )
        let elapsed = Date().timeIntervalSince(start)

        // Then
        XCTAssertEqual(OpenAIMockURLProtocol.requestCount, 2)
        XCTAssertGreaterThanOrEqual(elapsed, 0.01)
        XCTAssertEqual(self.tokenTexts(in: deltas), ["Retry success"])
    }

    func test_cancelled_terminatesStream() async throws {
        // Given
        OpenAIMockURLProtocol.setHandler { _, _ in
            .sse(
                events: [
                    #"{"choices":[{"delta":{"content":"first"}}]}"#,
                    #"{"choices":[{"delta":{"content":"second"}}]}"#,
                    #"{"choices":[{"delta":{"content":"third"}}]}"#,
                    "[DONE]",
                ],
                chunkDelay: 0.2
            )
        }
        let provider = self.makeProvider()
        let firstTokenExpectation = expectation(description: "first token")

        // When
        let stream = await provider.generate(
            messages: [LLMMessage(role: .user, content: "cancel me")],
            maxTokens: 64
        )
        let consumerTask = Task<Int, Never> {
            var didSignal = false
            var tokenCount = 0
            do {
                for try await delta in stream {
                    if case .token = delta, !didSignal {
                        didSignal = true
                        firstTokenExpectation.fulfill()
                    }
                    if case .token = delta {
                        tokenCount += 1
                    }
                }
            } catch {
                // Expected when the consumer task is cancelled.
            }
            return tokenCount
        }

        await fulfillment(of: [firstTokenExpectation], timeout: 2.0)
        let cancelStart = Date()
        consumerTask.cancel()
        let consumedTokenCount = await consumerTask.value
        let cancellationElapsed = Date().timeIntervalSince(cancelStart)

        // Then
        XCTAssertLessThan(cancellationElapsed, 1.0)
        XCTAssertLessThan(consumedTokenCount, 3)
    }

    func test_structuredGenerator_withOpenAIProvider_streamParsesToolCall() async throws {
        // Given
        OpenAIMockURLProtocol.setHandler { _, _ in
            .sse(events: [
                #"{"choices":[{"delta":{"content":"{\"type\":\"tool_call\",\"tool\":\"calendar.query\",\"args\":{\"range\":\"tomorrow\"}}"}}]}"#,
                "[DONE]",
            ])
        }
        let provider = self.makeProvider()
        let generator = StructuredGenerator(llm: provider)

        // When
        let output = try await generator.generate(
            messages: [LLMMessage(role: .user, content: "What's on my calendar tomorrow?")]
        )

        // Then
        XCTAssertEqual(
            output,
            .toolCall(tool: "calendar.query", args: ["range": .string("tomorrow")])
        )
    }

    // MARK: - Helpers

    private func makeProvider(baseRetryDelay: TimeInterval = 0.01) -> OpenAIProvider {
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [OpenAIMockURLProtocol.self]
        let session = URLSession(configuration: sessionConfiguration)
        return OpenAIProvider(
            apiKey: "sk-test-key",
            model: OpenAIModel.gpt4o.rawValue,
            session: session,
            maxRetries: 2,
            baseRetryDelay: baseRetryDelay
        )
    }

    private func collectDeltas(from stream: AsyncThrowingStream<LLMDelta, Error>) async throws -> [LLMDelta] {
        var deltas: [LLMDelta] = []
        for try await delta in stream {
            deltas.append(delta)
        }
        return deltas
    }

    private func tokenTexts(in deltas: [LLMDelta]) -> [String] {
        return deltas.compactMap { delta in
            if case .token(let text) = delta {
                return text
            }
            return nil
        }
    }

    private func completionTokens(in deltas: [LLMDelta]) -> Int? {
        return deltas.compactMap { delta in
            if case .completed(let totalTokens) = delta {
                return totalTokens
            }
            return nil
        }.last
    }

    private func requestBodyData(from request: URLRequest) -> Data? {
        if let httpBody = request.httpBody {
            return httpBody
        }

        guard let stream = request.httpBodyStream else {
            return nil
        }

        stream.open()
        defer { stream.close() }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)

        while stream.hasBytesAvailable {
            let bytesRead = stream.read(&buffer, maxLength: buffer.count)
            if bytesRead <= 0 {
                break
            }
            data.append(buffer, count: bytesRead)
        }

        return data.isEmpty ? nil : data
    }
}

// MARK: - URLProtocol Mock

private struct MockHTTPResponse {
    let statusCode: Int
    let headers: [String: String]
    let bodyChunks: [Data]
    let chunkDelay: TimeInterval

    static func sse(
        events: [String],
        chunkDelay: TimeInterval = 0
    ) -> MockHTTPResponse {
        let chunks = events.map { Data("data: \($0)\n\n".utf8) }
        return MockHTTPResponse(
            statusCode: 200,
            headers: ["Content-Type": "text/event-stream"],
            bodyChunks: chunks,
            chunkDelay: chunkDelay
        )
    }

    static func json(statusCode: Int, body: String) -> MockHTTPResponse {
        return MockHTTPResponse(
            statusCode: statusCode,
            headers: ["Content-Type": "application/json"],
            bodyChunks: [Data(body.utf8)],
            chunkDelay: 0
        )
    }
}

private final class OpenAIMockURLProtocol: URLProtocol {
    nonisolated(unsafe) private static var lock = NSLock()
    nonisolated(unsafe) private static var handler: ((URLRequest, Int) throws -> MockHTTPResponse)?
    nonisolated(unsafe) private static var _requestCount = 0
    nonisolated(unsafe) private static var _stopLoadingCount = 0

    private let stateLock = NSLock()
    private var isStopped = false

    static var requestCount: Int {
        return self.lock.withLock { self._requestCount }
    }

    static var stopLoadingCount: Int {
        return self.lock.withLock { self._stopLoadingCount }
    }

    static func setHandler(_ handler: @escaping (URLRequest, Int) throws -> MockHTTPResponse) {
        self.lock.withLock {
            self.handler = handler
            self._requestCount = 0
            self._stopLoadingCount = 0
        }
    }

    static func reset() {
        self.lock.withLock {
            self.handler = nil
            self._requestCount = 0
            self._stopLoadingCount = 0
        }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        return true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        return request
    }

    override func startLoading() {
        let responseIndex = Self.lock.withLock { () -> Int in
            let current = Self._requestCount
            Self._requestCount += 1
            return current
        }

        let responseHandler = Self.lock.withLock { Self.handler }
        guard let responseHandler else {
            self.client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        do {
            let mockResponse = try responseHandler(self.request, responseIndex)
            let httpResponse = HTTPURLResponse(
                url: self.request.url ?? URL(string: "https://api.openai.com/v1/chat/completions")!,
                statusCode: mockResponse.statusCode,
                httpVersion: nil,
                headerFields: mockResponse.headers
            )!

            self.client?.urlProtocol(self, didReceive: httpResponse, cacheStoragePolicy: .notAllowed)

            self.emit(chunks: mockResponse.bodyChunks, delay: mockResponse.chunkDelay)
        } catch {
            self.client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {
        self.stateLock.withLock {
            self.isStopped = true
        }
        Self.lock.withLock {
            Self._stopLoadingCount += 1
        }
    }

    private func shouldStop() -> Bool {
        return self.stateLock.withLock { self.isStopped }
    }

    private func emit(chunks: [Data], delay: TimeInterval) {
        for chunk in chunks {
            if self.shouldStop() {
                return
            }
            self.client?.urlProtocol(self, didLoad: chunk)
            if delay > 0 {
                Thread.sleep(forTimeInterval: delay)
            }
        }

        if self.shouldStop() {
            return
        }
        self.client?.urlProtocolDidFinishLoading(self)
    }
}
