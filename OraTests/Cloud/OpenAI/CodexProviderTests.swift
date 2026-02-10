//
//  CodexProviderTests.swift
//  OraTests
//
//  Tests for Codex OAuth-backed provider behavior.
//

import Foundation
import XCTest
@testable import Ora

final class CodexProviderTests: XCTestCase {
    override func tearDown() async throws {
        CodexProviderMockURLProtocol.reset()
    }

    func test_codexProvider_setsCorrectHeaders() async throws {
        // Given
        var capturedAuthorization: String?
        var capturedAccountID: String?
        var capturedOriginator: String?
        var capturedVersion: String?
        var capturedUserAgent: String?
        var capturedURL: URL?
        CodexProviderMockURLProtocol.setHandler { request, _ in
            capturedAuthorization = request.value(forHTTPHeaderField: "Authorization")
            capturedAccountID = request.value(forHTTPHeaderField: "chatgpt-account-id")
            capturedOriginator = request.value(forHTTPHeaderField: "originator")
            capturedVersion = request.value(forHTTPHeaderField: "version")
            capturedUserAgent = request.value(forHTTPHeaderField: "User-Agent")
            capturedURL = request.url
            return .sse(events: ["[DONE]"])
        }
        let provider = self.makeProvider()

        // When
        _ = try await self.collectDeltas(
            from: await provider.generate(
                messages: [LLMMessage(role: .user, content: "Hello")],
                maxTokens: 32
            )
        )

        // Then
        XCTAssertEqual(capturedAuthorization, "Bearer access_token")
        XCTAssertEqual(capturedAccountID, "acct_123")
        XCTAssertEqual(capturedOriginator, CodexOAuthManager.originator)
        XCTAssertNotNil(capturedVersion)
        XCTAssertTrue((capturedUserAgent ?? "").contains(CodexOAuthManager.originator))
        XCTAssertEqual(capturedURL?.absoluteString, "https://chatgpt.com/backend-api/codex/responses")
    }

    func test_codexProvider_usesResponsesRequestShape() async throws {
        // Given
        var capturedBody: [String: Any]?
        CodexProviderMockURLProtocol.setHandler { request, _ in
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
                    LLMMessage(role: .user, content: "Hello"),
                ],
                maxTokens: 32
            )
        )

        // Then
        XCTAssertEqual(capturedBody?["model"] as? String, OpenAIModel.gpt4o.rawValue)
        XCTAssertEqual(capturedBody?["instructions"] as? String, "System instruction")
        XCTAssertEqual(capturedBody?["stream"] as? Bool, true)
        XCTAssertEqual(capturedBody?["tool_choice"] as? String, "auto")
        XCTAssertEqual(capturedBody?["parallel_tool_calls"] as? Bool, true)
        XCTAssertEqual(capturedBody?["store"] as? Bool, false)
        XCTAssertNil(capturedBody?["max_output_tokens"])

        let input = try XCTUnwrap(capturedBody?["input"] as? [[String: Any]])
        XCTAssertEqual(input.count, 1)
        XCTAssertEqual(input[0]["type"] as? String, "message")
        XCTAssertEqual(input[0]["role"] as? String, "user")
    }

    func test_codexProvider_streamsTokens() async throws {
        // Given
        CodexProviderMockURLProtocol.setHandler { _, _ in
            return .sse(events: [
                #"{"type":"response.output_text.delta","delta":"Hello"}"#,
                #"{"type":"response.output_text.delta","delta":" world"}"#,
                #"{"type":"response.completed","response":{"id":"resp_1","usage":{"input_tokens":10,"output_tokens":5,"total_tokens":15}}}"#,
            ])
        }
        let provider = self.makeProvider()

        // When
        let deltas = try await self.collectDeltas(
            from: await provider.generate(
                messages: [LLMMessage(role: .user, content: "Hello")],
                maxTokens: 32
            )
        )

        // Then
        XCTAssertEqual(self.tokenTexts(in: deltas), ["Hello", " world"])
    }

    func test_codexProvider_mapsMultiTurnHistoryToUserInputMessages() async throws {
        // Given
        var capturedBody: [String: Any]?
        CodexProviderMockURLProtocol.setHandler { request, _ in
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
                    LLMMessage(role: .user, content: "What is on my calendar?"),
                    LLMMessage(role: .assistant, content: "{\"type\":\"tool_call\",\"tool\":\"calendar.query\",\"args\":{}}"),
                    LLMMessage(role: .tool, content: "Tool calendar.query returned: {...}"),
                    LLMMessage(role: .assistant, content: "{\"type\":\"response\",\"text\":\"You have two meetings.\"}"),
                    LLMMessage(role: .user, content: "And tomorrow?"),
                ],
                maxTokens: 64
            )
        )

        // Then
        let input = try XCTUnwrap(capturedBody?["input"] as? [[String: Any]])
        XCTAssertEqual(input.count, 5)
        XCTAssertTrue(input.allSatisfy { ($0["role"] as? String) == "user" })

        let inputTexts: [String] = input.compactMap { message in
            guard
                let content = message["content"] as? [[String: Any]],
                let first = content.first,
                let text = first["text"] as? String
            else { return nil }
            return text
        }
        XCTAssertEqual(inputTexts.count, 5)
        XCTAssertTrue(inputTexts.contains(where: { $0.contains("Previous assistant response:") }))
        XCTAssertTrue(inputTexts.contains(where: { $0.contains("Tool result context:") }))
    }

    private func makeProvider() -> CodexProvider {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CodexProviderMockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        return CodexProvider(
            model: OpenAIModel.gpt4o.rawValue,
            credentialProvider: {
                return CodexOAuthCredential(
                    accessToken: "access_token",
                    refreshToken: "refresh_token",
                    accountID: "acct_123",
                    accountEmail: "user@example.com",
                    expiresAt: Date().addingTimeInterval(3600),
                    updatedAt: Date()
                )
            },
            session: session,
            maxRetries: 1,
            baseRetryDelay: 0.01
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
            if case .token(let token) = delta {
                return token
            }
            return nil
        }
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

private struct CodexProviderMockResponse {
    let statusCode: Int
    let headers: [String: String]
    let bodyChunks: [Data]

    static func sse(events: [String]) -> CodexProviderMockResponse {
        let chunks = events.map { Data("data: \($0)\n\n".utf8) }
        return CodexProviderMockResponse(
            statusCode: 200,
            headers: ["Content-Type": "text/event-stream"],
            bodyChunks: chunks
        )
    }
}

private final class CodexProviderMockURLProtocol: URLProtocol {
    nonisolated(unsafe) private static var lock = NSLock()
    nonisolated(unsafe) private static var handler: ((URLRequest, Int) throws -> CodexProviderMockResponse)?
    nonisolated(unsafe) private static var _requestCount = 0

    static func setHandler(_ handler: @escaping (URLRequest, Int) throws -> CodexProviderMockResponse) {
        self.lock.withLock {
            self.handler = handler
            self._requestCount = 0
        }
    }

    static func reset() {
        self.lock.withLock {
            self.handler = nil
            self._requestCount = 0
        }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        return true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        return request
    }

    override func startLoading() {
        let index = Self.lock.withLock { () -> Int in
            let current = Self._requestCount
            Self._requestCount += 1
            return current
        }

        let handler = Self.lock.withLock { Self.handler }
        guard let handler else {
            self.client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        do {
            let response = try handler(self.request, index)
            let httpResponse = HTTPURLResponse(
                url: self.request.url ?? URL(string: "https://chatgpt.com/backend-api/codex/responses")!,
                statusCode: response.statusCode,
                httpVersion: nil,
                headerFields: response.headers
            )!
            self.client?.urlProtocol(self, didReceive: httpResponse, cacheStoragePolicy: .notAllowed)
            for chunk in response.bodyChunks {
                self.client?.urlProtocol(self, didLoad: chunk)
            }
            self.client?.urlProtocolDidFinishLoading(self)
        } catch {
            self.client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
