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
        var capturedURL: URL?
        CodexProviderMockURLProtocol.setHandler { request, _ in
            capturedAuthorization = request.value(forHTTPHeaderField: "Authorization")
            capturedAccountID = request.value(forHTTPHeaderField: "chatgpt-account-id")
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
        XCTAssertEqual(capturedURL?.absoluteString, "https://chatgpt.com/backend-api/conversation")
    }

    func test_codexProvider_streamsTokens() async throws {
        // Given
        CodexProviderMockURLProtocol.setHandler { _, _ in
            return .sse(events: [
                #"{"message":{"content":{"parts":["Hello"]}}}"#,
                #"{"message":{"content":{"parts":["Hello world"]}}}"#,
                "[DONE]",
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
                url: self.request.url ?? URL(string: "https://chatgpt.com/backend-api/conversation")!,
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
