//
//  CodexOAuthManagerTests.swift
//  OraTests
//
//  Tests for Codex OAuth flow and token refresh behavior.
//

import Foundation
import XCTest
@testable import Ora

final class CodexOAuthManagerTests: XCTestCase {
    override func tearDown() async throws {
        CodexOAuthMockURLProtocol.reset()
    }

    func test_oauthPKCE_generatesCorrectChallenge() {
        // Given
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"

        // When
        let challenge = CodexOAuthManager.codeChallenge(for: verifier)

        // Then
        XCTAssertEqual(challenge, "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    func test_authorize_tokenExchange_parsesResponse() async throws {
        // Given
        let token = self.makeJWT(
            expiry: Date(timeIntervalSince1970: 1_892_160_000),
            email: "user@example.com",
            subject: "acct_authorize"
        )
        CodexOAuthMockURLProtocol.setHandler { request, _ in
            XCTAssertEqual(request.url?.absoluteString, "https://auth.openai.com/oauth/token")
            return .json(
                statusCode: 200,
                body: """
                {
                  "access_token": "\(token)",
                  "refresh_token": "rt_new",
                  "account_id": "acct_authorize",
                  "expires_in": 3600
                }
                """
            )
        }

        let session = self.makeSession()
        let store = CodexTestCredentialStore()
        let manager = CodexOAuthManager(
            credentialStore: store,
            credentialReader: CodexReaderStub(credential: nil),
            authenticator: CallbackAuthenticator(code: "auth_code"),
            session: session
        )

        // When
        let credential = try await manager.authorize()

        // Then
        XCTAssertEqual(credential.accountID, "acct_authorize")
        XCTAssertEqual(credential.accountEmail, "user@example.com")
        XCTAssertEqual(credential.refreshToken, "rt_new")
        let stored = try await manager.currentCredential()
        XCTAssertEqual(stored?.accessToken, token)
    }

    func test_authorize_prefersChatGPTAccountIDFromIDTokenClaims() async throws {
        let accessToken = self.makeJWT(
            expiry: Date(timeIntervalSince1970: 1_892_160_000),
            email: "user@example.com",
            subject: "sub_fallback"
        )
        let idToken = self.makeJWT(
            expiry: Date(timeIntervalSince1970: 1_892_160_000),
            email: "id@example.com",
            subject: "sub_id",
            chatGPTAccountID: "acct_from_claims"
        )

        CodexOAuthMockURLProtocol.setHandler { _, _ in
            return .json(
                statusCode: 200,
                body: """
                {
                  "access_token": "\(accessToken)",
                  "id_token": "\(idToken)",
                  "refresh_token": "rt_new",
                  "expires_in": 3600
                }
                """
            )
        }

        let manager = CodexOAuthManager(
            credentialStore: CodexTestCredentialStore(),
            credentialReader: CodexReaderStub(credential: nil),
            authenticator: CallbackAuthenticator(code: "auth_code"),
            session: self.makeSession()
        )

        let credential = try await manager.authorize()
        XCTAssertEqual(credential.accountID, "acct_from_claims")
        XCTAssertEqual(credential.accountEmail, "user@example.com")
    }

    func test_authorize_buildsCodexCompatibleAuthorizationURL() async throws {
        let token = self.makeJWT(
            expiry: Date(timeIntervalSince1970: 1_892_160_000),
            email: "user@example.com",
            subject: "acct_authorize"
        )

        let authenticator = CapturingCallbackAuthenticator(code: "auth_code")
        CodexOAuthMockURLProtocol.setHandler { _, _ in
            return .json(
                statusCode: 200,
                body: """
                {
                  "access_token": "\(token)",
                  "refresh_token": "rt_new",
                  "account_id": "acct_authorize",
                  "expires_in": 3600
                }
                """
            )
        }

        let manager = CodexOAuthManager(
            credentialStore: CodexTestCredentialStore(),
            credentialReader: CodexReaderStub(credential: nil),
            authenticator: authenticator,
            session: self.makeSession()
        )

        _ = try await manager.authorize()

        let capturedURL = await authenticator.capturedURL()
        let unwrappedURL = try XCTUnwrap(capturedURL)
        let components = try XCTUnwrap(URLComponents(url: unwrappedURL, resolvingAgainstBaseURL: false))
        let items = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })

        XCTAssertEqual(items["response_type"], "code")
        XCTAssertEqual(items["client_id"], CodexOAuthManager.clientID)
        XCTAssertEqual(items["redirect_uri"], CodexOAuthManager.redirectURI)
        XCTAssertEqual(items["scope"], "openid profile email offline_access")
        XCTAssertEqual(items["code_challenge_method"], "S256")
        XCTAssertEqual(items["id_token_add_organizations"], "true")
        XCTAssertEqual(items["codex_cli_simplified_flow"], "true")
        XCTAssertEqual(items["originator"], CodexOAuthManager.originator)
        XCTAssertFalse((items["state"] ?? "").isEmpty)
        XCTAssertFalse((items["code_challenge"] ?? "").isEmpty)
    }

    func test_tokenRefresh_updatesKeychain() async throws {
        // Given
        let expiringToken = self.makeJWT(
            expiry: Date(timeIntervalSince1970: 1_700_000_000),
            email: "old@example.com",
            subject: "acct_refresh"
        )
        let refreshedToken = self.makeJWT(
            expiry: Date(timeIntervalSince1970: 1_900_000_000),
            email: "new@example.com",
            subject: "acct_refresh"
        )

        let now = Date(timeIntervalSince1970: 1_700_000_100)
        let store = CodexTestCredentialStore()
        try await store.save(
            provider: .openaiCodex,
            apiKey: self.encodeCredential(
                accessToken: expiringToken,
                refreshToken: "rt_old",
                accountID: "acct_refresh",
                accountEmail: "old@example.com",
                expiresAt: Date(timeIntervalSince1970: 1_700_000_120),
                updatedAt: now
            )
        )

        CodexOAuthMockURLProtocol.setHandler { _, _ in
            return .json(
                statusCode: 200,
                body: """
                {
                  "access_token": "\(refreshedToken)",
                  "refresh_token": "rt_new",
                  "account_id": "acct_refresh",
                  "expires_in": 7200
                }
                """
            )
        }

        let manager = CodexOAuthManager(
            credentialStore: store,
            credentialReader: CodexReaderStub(credential: nil),
            authenticator: CallbackAuthenticator(code: "unused"),
            session: self.makeSession(),
            now: { now }
        )

        // When
        let credential = try await manager.validCredentialIfAvailable()

        // Then
        XCTAssertEqual(credential?.refreshToken, "rt_new")
        XCTAssertEqual(credential?.accountEmail, "new@example.com")
        let stored = try await manager.currentCredential()
        XCTAssertEqual(stored?.refreshToken, "rt_new")
    }

    func test_tokenRefresh_expiryCheck_skipsRefreshWhenTokenIsValid() async throws {
        // Given
        let now = Date(timeIntervalSince1970: 1_700_000_100)
        let token = self.makeJWT(
            expiry: now.addingTimeInterval(10_000),
            email: "user@example.com",
            subject: "acct_stable"
        )
        let store = CodexTestCredentialStore()
        try await store.save(
            provider: .openaiCodex,
            apiKey: self.encodeCredential(
                accessToken: token,
                refreshToken: "rt_stable",
                accountID: "acct_stable",
                accountEmail: "user@example.com",
                expiresAt: now.addingTimeInterval(10_000),
                updatedAt: now
            )
        )

        CodexOAuthMockURLProtocol.setHandler { _, _ in
            XCTFail("Token refresh should not be called for a non-expiring token")
            return .json(statusCode: 500, body: "{}")
        }

        let manager = CodexOAuthManager(
            credentialStore: store,
            credentialReader: CodexReaderStub(credential: nil),
            authenticator: CallbackAuthenticator(code: "unused"),
            session: self.makeSession(),
            now: { now }
        )

        // When
        let credential = try await manager.validCredentialIfAvailable()

        // Then
        XCTAssertEqual(credential?.accessToken, token)
        XCTAssertEqual(CodexOAuthMockURLProtocol.requestCount, 0)
    }

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CodexOAuthMockURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func encodeCredential(
        accessToken: String,
        refreshToken: String,
        accountID: String,
        accountEmail: String?,
        expiresAt: Date,
        updatedAt: Date
    ) -> String {
        let credential = CodexOAuthCredential(
            accessToken: accessToken,
            refreshToken: refreshToken,
            accountID: accountID,
            accountEmail: accountEmail,
            expiresAt: expiresAt,
            updatedAt: updatedAt
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try! encoder.encode(credential)
        return String(decoding: data, as: UTF8.self)
    }

    private func makeJWT(
        expiry: Date,
        email: String,
        subject: String,
        chatGPTAccountID: String? = nil
    ) -> String {
        let header = #"{"alg":"HS256","typ":"JWT"}"#
        let payloadData: [String: Any]
        if let chatGPTAccountID {
            payloadData = [
                "exp": Int(expiry.timeIntervalSince1970),
                "email": email,
                "sub": subject,
                "https://api.openai.com/auth": [
                    "chatgpt_account_id": chatGPTAccountID,
                ],
                "https://api.openai.com/profile": [
                    "email": email,
                ],
            ]
        } else {
            payloadData = [
                "exp": Int(expiry.timeIntervalSince1970),
                "email": email,
                "sub": subject,
            ]
        }
        let payload = String(
            data: try! JSONSerialization.data(withJSONObject: payloadData),
            encoding: .utf8
        )!
        return [
            self.base64URLEncode(header),
            self.base64URLEncode(payload),
            self.base64URLEncode("signature"),
        ].joined(separator: ".")
    }

    private func base64URLEncode(_ string: String) -> String {
        return Data(string.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

private actor CodexTestCredentialStore: CredentialStore {
    private var storage: [CloudProvider: String] = [:]

    func save(provider: CloudProvider, apiKey: String) throws {
        self.storage[provider] = apiKey
    }

    func retrieve(provider: CloudProvider) throws -> String? {
        return self.storage[provider]
    }

    func delete(provider: CloudProvider) throws {
        self.storage.removeValue(forKey: provider)
    }

    func hasCredential(for provider: CloudProvider) -> Bool {
        return self.storage[provider] != nil
    }
}

private struct CodexReaderStub: CodexCredentialReading {
    let credential: CodexOAuthCredential?

    func readCredential() throws -> CodexOAuthCredential? {
        return self.credential
    }
}

private final class CallbackAuthenticator: CodexWebAuthenticating {
    private let code: String

    init(code: String) {
        self.code = code
    }

    func authenticate(url: URL, redirectURI: String) async throws -> URL {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let state = components?.queryItems?.first(where: { $0.name == "state" })?.value ?? ""
        var callbackComponents = URLComponents(string: redirectURI)!
        callbackComponents.queryItems = [
            URLQueryItem(name: "code", value: self.code),
            URLQueryItem(name: "state", value: state),
        ]
        return callbackComponents.url!
    }
}

private actor CapturingCallbackAuthenticator: CodexWebAuthenticating {
    private var lastURL: URL?
    private let code: String

    init(code: String) {
        self.code = code
    }

    func authenticate(url: URL, redirectURI: String) async throws -> URL {
        self.lastURL = url
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let state = components?.queryItems?.first(where: { $0.name == "state" })?.value ?? ""
        var callbackComponents = URLComponents(string: redirectURI)!
        callbackComponents.queryItems = [
            URLQueryItem(name: "code", value: self.code),
            URLQueryItem(name: "state", value: state),
        ]
        return callbackComponents.url!
    }

    func capturedURL() -> URL? {
        return self.lastURL
    }
}

private struct CodexOAuthMockResponse {
    let statusCode: Int
    let headers: [String: String]
    let body: Data

    static func json(statusCode: Int, body: String) -> CodexOAuthMockResponse {
        return CodexOAuthMockResponse(
            statusCode: statusCode,
            headers: ["Content-Type": "application/json"],
            body: Data(body.utf8)
        )
    }
}

private final class CodexOAuthMockURLProtocol: URLProtocol {
    nonisolated(unsafe) private static var lock = NSLock()
    nonisolated(unsafe) private static var handler: ((URLRequest, Int) throws -> CodexOAuthMockResponse)?
    nonisolated(unsafe) private static var _requestCount = 0

    static var requestCount: Int {
        return self.lock.withLock { self._requestCount }
    }

    static func setHandler(_ handler: @escaping (URLRequest, Int) throws -> CodexOAuthMockResponse) {
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
                url: self.request.url ?? URL(string: "https://auth.openai.com/oauth/token")!,
                statusCode: response.statusCode,
                httpVersion: nil,
                headerFields: response.headers
            )!
            self.client?.urlProtocol(self, didReceive: httpResponse, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: response.body)
            self.client?.urlProtocolDidFinishLoading(self)
        } catch {
            self.client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
