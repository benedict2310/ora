//
//  OpenAIModelDiscoveryServiceTests.swift
//  OraTests
//
//  Tests for OpenAI model discovery parsing, filtering, and caching.
//

import Foundation
import XCTest
@testable import Ora

final class OpenAIModelDiscoveryServiceTests: XCTestCase {

    override func tearDown() async throws {
        OpenAIModelDiscoveryURLProtocol.reset()
        UserDefaults.standard.removeObject(forKey: "com.ora.openAI.discoveredModelIdentifiers")
    }

    func test_openAIModelDiscovery_withCredential_returnsFilteredList() async throws {
        let credentialStore = OpenAIModelDiscoveryCredentialStore(apiKey: "sk-test")
        OpenAIModelDiscoveryURLProtocol.setHandler { _ in
            return .json(
                statusCode: 200,
                body: """
                {
                  "data": [
                    { "id": "gpt-5.2" },
                    { "id": "gpt-4o" },
                    { "id": "o3-mini" },
                    { "id": "text-embedding-3-large" },
                    { "id": "whisper-1" }
                  ]
                }
                """
            )
        }

        let service = OpenAIModelDiscoveryService(
            credentialStore: credentialStore,
            session: self.makeSession(),
            cacheTTL: 300
        )

        let state = await service.fetchModelAvailability(forceRefresh: true)

        guard case .available(let models, let isStale) = state else {
            return XCTFail("Expected available models")
        }
        XCTAssertFalse(isStale)
        XCTAssertEqual(models.map(\.identifier), ["gpt-5.2", "gpt-4o", "o3-mini"])
    }

    func test_openAIModelDiscovery_withoutCredential_returnsUnavailableState() async {
        let credentialStore = OpenAIModelDiscoveryCredentialStore(apiKey: nil)
        let service = OpenAIModelDiscoveryService(
            credentialStore: credentialStore,
            session: self.makeSession(),
            cacheTTL: 300
        )

        let state = await service.fetchModelAvailability(forceRefresh: true)

        XCTAssertEqual(state, .unavailable(.missingCredential))
    }

    func test_openAIModelDiscovery_requestFailure_returnsCachedStaleModels() async throws {
        let credentialStore = OpenAIModelDiscoveryCredentialStore(apiKey: "sk-test")
        OpenAIModelDiscoveryURLProtocol.setHandler { _ in
            return .json(
                statusCode: 200,
                body: """
                {
                  "data": [
                    { "id": "gpt-5.2" },
                    { "id": "gpt-4o" }
                  ]
                }
                """
            )
        }

        let service = OpenAIModelDiscoveryService(
            credentialStore: credentialStore,
            session: self.makeSession(),
            cacheTTL: 300
        )

        let first = await service.fetchModelAvailability(forceRefresh: true)
        guard case .available(let firstModels, let firstStale) = first else {
            return XCTFail("Expected first fetch to succeed")
        }
        XCTAssertFalse(firstStale)
        XCTAssertEqual(firstModels.count, 2)

        OpenAIModelDiscoveryURLProtocol.setHandler { _ in
            return .json(statusCode: 500, body: "{\"error\":\"server\"}")
        }

        let second = await service.fetchModelAvailability(forceRefresh: true)
        guard case .available(let secondModels, let isStale) = second else {
            return XCTFail("Expected stale cache fallback")
        }
        XCTAssertTrue(isStale)
        XCTAssertEqual(secondModels.map(\.identifier), firstModels.map(\.identifier))
    }

    func test_openAIModelDiscovery_withCodexCredential_fetchesCodexModels() async throws {
        let credentialStore = OpenAIModelDiscoveryCredentialStore(apiKey: nil)
        let codexOAuthManager = OpenAIModelDiscoveryCodexOAuthManagerMock()
        await codexOAuthManager.setCredential(
            CodexOAuthCredential(
                accessToken: "codex-access",
                refreshToken: "codex-refresh",
                accountID: "acct_codex",
                accountEmail: "codex@example.com",
                expiresAt: Date().addingTimeInterval(3600),
                updatedAt: Date()
            )
        )

        var capturedAuthorization: String?
        var capturedAccountID: String?
        var capturedOriginator: String?
        var capturedVersion: String?
        var capturedUserAgent: String?
        var capturedURL: URL?
        OpenAIModelDiscoveryURLProtocol.setHandler { request in
            capturedAuthorization = request.value(forHTTPHeaderField: "Authorization")
            capturedAccountID = request.value(forHTTPHeaderField: "chatgpt-account-id")
            capturedOriginator = request.value(forHTTPHeaderField: "originator")
            capturedVersion = request.value(forHTTPHeaderField: "version")
            capturedUserAgent = request.value(forHTTPHeaderField: "User-Agent")
            capturedURL = request.url
            return .json(
                statusCode: 200,
                body: """
                {
                  "models": [
                    { "slug": "gpt-5.2-codex" },
                    { "slug": "gpt-5.2" },
                    { "slug": "whisper-1" }
                  ]
                }
                """
            )
        }

        let service = OpenAIModelDiscoveryService(
            credentialStore: credentialStore,
            codexOAuthManager: codexOAuthManager,
            session: self.makeSession(),
            cacheTTL: 300
        )

        let state = await service.fetchModelAvailability(forceRefresh: true)

        guard case .available(let models, let isStale) = state else {
            return XCTFail("Expected available models")
        }
        XCTAssertFalse(isStale)
        XCTAssertEqual(capturedAuthorization, "Bearer codex-access")
        XCTAssertEqual(capturedAccountID, "acct_codex")
        XCTAssertEqual(capturedOriginator, CodexOAuthManager.originator)
        XCTAssertNotNil(capturedVersion)
        XCTAssertTrue((capturedUserAgent ?? "").contains(CodexOAuthManager.originator))
        let url = try XCTUnwrap(capturedURL)
        XCTAssertEqual(url.host, "chatgpt.com")
        XCTAssertEqual(url.path, "/backend-api/codex/models")
        let queryItems = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertNotNil(queryItems.first(where: { $0.name == "client_version" && ($0.value?.isEmpty == false) }))
        XCTAssertEqual(models.map(\.identifier), ["gpt-5.2", "gpt-5.2-codex"])
    }

    // MARK: - Helpers

    private func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [OpenAIModelDiscoveryURLProtocol.self]
        return URLSession(configuration: config)
    }
}

// MARK: - Mocks

actor OpenAIModelDiscoveryCredentialStore: CredentialStore {
    private var apiKey: String?

    init(apiKey: String?) {
        self.apiKey = apiKey
    }

    func save(provider: CloudProvider, apiKey: String) throws {
        self.apiKey = apiKey
    }

    func retrieve(provider: CloudProvider) throws -> String? {
        return provider == .openai ? self.apiKey : nil
    }

    func delete(provider: CloudProvider) throws {
        if provider == .openai {
            self.apiKey = nil
        }
    }

    func hasCredential(for provider: CloudProvider) -> Bool {
        return provider == .openai && self.apiKey != nil
    }
}

private struct OpenAIModelDiscoveryResponse {
    let statusCode: Int
    let body: Data

    static func json(statusCode: Int, body: String) -> OpenAIModelDiscoveryResponse {
        return OpenAIModelDiscoveryResponse(statusCode: statusCode, body: Data(body.utf8))
    }
}

private final class OpenAIModelDiscoveryURLProtocol: URLProtocol {
    nonisolated(unsafe) private static var lock = NSLock()
    nonisolated(unsafe) private static var handler: ((URLRequest) throws -> OpenAIModelDiscoveryResponse)?

    static func setHandler(_ handler: @escaping (URLRequest) throws -> OpenAIModelDiscoveryResponse) {
        self.lock.withLock {
            self.handler = handler
        }
    }

    static func reset() {
        self.lock.withLock {
            self.handler = nil
        }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        return true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        return request
    }

    override func startLoading() {
        do {
            guard let handler = Self.lock.withLock({ Self.handler }) else {
                throw URLError(.badServerResponse)
            }
            let response = try handler(self.request)
            let urlResponse = HTTPURLResponse(
                url: self.request.url!,
                statusCode: response.statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            self.client?.urlProtocol(self, didReceive: urlResponse, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: response.body)
            self.client?.urlProtocolDidFinishLoading(self)
        } catch {
            self.client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        self.lock()
        defer { self.unlock() }
        return try body()
    }
}

private actor OpenAIModelDiscoveryCodexOAuthManagerMock: CodexOAuthManaging {
    private var credential: CodexOAuthCredential?

    func authorize() async throws -> CodexOAuthCredential {
        guard let credential else {
            throw CodexOAuthError.invalidTokenResponse("No credential available")
        }
        return credential
    }

    func disconnect() async throws {
        self.credential = nil
    }

    func currentCredential() async throws -> CodexOAuthCredential? {
        return self.credential
    }

    func validCredentialIfAvailable() async throws -> CodexOAuthCredential? {
        return self.credential
    }

    func importCLIAuthIfNeeded() async {}

    func setCredential(_ credential: CodexOAuthCredential?) {
        self.credential = credential
    }
}
