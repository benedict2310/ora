//
//  CodexOAuthManager.swift
//  Ora
//
//  Handles Codex OAuth authentication, token refresh, and secure persistence.
//

import AppKit
import AuthenticationServices
import CryptoKit
import Foundation
import Security
import os

struct CodexOAuthCredential: Codable, Equatable, Sendable {
    let accessToken: String
    let refreshToken: String
    let accountID: String
    let accountEmail: String?
    let expiresAt: Date
    let updatedAt: Date

    var displayIdentifier: String {
        return self.accountEmail ?? self.accountID
    }

    func isExpiringSoon(relativeTo now: Date, threshold: TimeInterval = 300) -> Bool {
        return self.expiresAt.timeIntervalSince(now) <= threshold
    }
}

protocol CodexOAuthManaging: Sendable {
    func authorize() async throws -> CodexOAuthCredential
    func disconnect() async throws
    func currentCredential() async throws -> CodexOAuthCredential?
    func validCredentialIfAvailable() async throws -> CodexOAuthCredential?
    func importCLIAuthIfNeeded() async
}

enum CodexOAuthError: LocalizedError {
    case authorizationCancelled
    case authorizationFailed(String)
    case missingAuthorizationCode
    case stateMismatch
    case tokenExchangeFailed(statusCode: Int, message: String)
    case invalidTokenResponse(String)
    case missingRefreshToken
    case missingAccountIdentifier
    case credentialEncodingFailed
    case credentialDecodingFailed

    var errorDescription: String? {
        switch self {
        case .authorizationCancelled:
            return "Codex authorization was cancelled."
        case .authorizationFailed(let message):
            return "Codex authorization failed: \(message)"
        case .missingAuthorizationCode:
            return "Codex authorization callback did not contain a code."
        case .stateMismatch:
            return "Codex authorization state mismatch."
        case .tokenExchangeFailed(let statusCode, let message):
            return "Codex token exchange failed (\(statusCode)): \(message)"
        case .invalidTokenResponse(let message):
            return "Codex token response is invalid: \(message)"
        case .missingRefreshToken:
            return "Codex refresh token is missing."
        case .missingAccountIdentifier:
            return "Codex account identifier is missing."
        case .credentialEncodingFailed:
            return "Failed to encode Codex credential for storage."
        case .credentialDecodingFailed:
            return "Failed to decode stored Codex credential."
        }
    }
}

protocol CodexWebAuthenticating: Sendable {
    func authenticate(url: URL, callbackURLScheme: String) async throws -> URL
}

final class ASWebAuthenticationSessionAuthenticator: CodexWebAuthenticating, @unchecked Sendable {
    func authenticate(url: URL, callbackURLScheme: String) async throws -> URL {
        return try await self.authenticateOnMainActor(url: url, callbackURLScheme: callbackURLScheme)
    }

    @MainActor
    private func authenticateOnMainActor(url: URL, callbackURLScheme: String) async throws -> URL {
        return try await withCheckedThrowingContinuation { continuation in
            let presentationContextProvider = AuthenticationPresentationContextProvider()
            let session = ASWebAuthenticationSession(
                url: url,
                callbackURLScheme: callbackURLScheme
            ) { callbackURL, error in
                if let error {
                    if let authError = error as? ASWebAuthenticationSessionError,
                       authError.code == .canceledLogin {
                        continuation.resume(throwing: CodexOAuthError.authorizationCancelled)
                        return
                    }
                    continuation.resume(throwing: CodexOAuthError.authorizationFailed(error.localizedDescription))
                    return
                }

                guard let callbackURL else {
                    continuation.resume(throwing: CodexOAuthError.missingAuthorizationCode)
                    return
                }

                continuation.resume(returning: callbackURL)
            }

            session.presentationContextProvider = presentationContextProvider
            session.prefersEphemeralWebBrowserSession = true
            session.start()
        }
    }
}

@MainActor
private final class AuthenticationPresentationContextProvider: NSObject, ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        if let keyWindow = NSApplication.shared.windows.first(where: \.isKeyWindow) {
            return keyWindow
        }
        return NSApplication.shared.windows.first ?? ASPresentationAnchor()
    }
}

actor CodexOAuthManager: CodexOAuthManaging {
    static let shared = CodexOAuthManager()

    static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    static let authorizeEndpoint = URL(string: "https://auth.openai.com/oauth/authorize")!
    static let tokenEndpoint = URL(string: "https://auth.openai.com/oauth/token")!
    static let redirectURI = "ora://oauth/codex"
    static let callbackScheme = "ora"

    private let logger = Logger(subsystem: "com.ora.app", category: "codex-auth")
    private let credentialStore: CredentialStore
    private let credentialReader: CodexCredentialReading
    private let authenticator: CodexWebAuthenticating
    private let session: URLSession
    private let now: @Sendable () -> Date
    private let refreshLeadTime: TimeInterval

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    init(
        credentialStore: CredentialStore = KeychainCredentialStore(),
        credentialReader: CodexCredentialReading = CodexCredentialReader(),
        authenticator: CodexWebAuthenticating? = nil,
        session: URLSession = .shared,
        refreshLeadTime: TimeInterval = 300,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.credentialStore = credentialStore
        self.credentialReader = credentialReader
        self.authenticator = authenticator ?? ASWebAuthenticationSessionAuthenticator()
        self.session = session
        self.refreshLeadTime = refreshLeadTime
        self.now = now
    }

    func authorize() async throws -> CodexOAuthCredential {
        let codeVerifier = try Self.generateCodeVerifier()
        let codeChallenge = Self.codeChallenge(for: codeVerifier)
        let state = try Self.generateState()
        let authorizationURL = Self.buildAuthorizationURL(codeChallenge: codeChallenge, state: state)

        let callbackURL = try await self.startAuthenticationSession(url: authorizationURL)
        let code = try Self.authorizationCode(from: callbackURL, expectedState: state)
        let tokenResponse = try await self.exchangeAuthorizationCode(code: code, codeVerifier: codeVerifier)
        let credential = try self.makeCredential(
            from: tokenResponse,
            fallbackRefreshToken: nil,
            fallbackAccountID: nil,
            fallbackEmail: nil
        )

        try await self.persist(credential: credential)
        self.logger.info("Codex OAuth authorization completed")
        return credential
    }

    func disconnect() async throws {
        try await self.credentialStore.delete(provider: .openaiCodex)
        self.logger.info("Codex OAuth credential removed")
    }

    func currentCredential() async throws -> CodexOAuthCredential? {
        return try await self.loadStoredCredential()
    }

    func validCredentialIfAvailable() async throws -> CodexOAuthCredential? {
        var credential = try await self.loadStoredCredential()
        if credential == nil {
            await self.importCLIAuthIfNeeded()
            credential = try await self.loadStoredCredential()
        }

        guard let credential else {
            return nil
        }

        if credential.isExpiringSoon(relativeTo: self.now(), threshold: self.refreshLeadTime) {
            let refreshed = try await self.refreshCredentialWithRetry(credential)
            try await self.persist(credential: refreshed)
            return refreshed
        }

        return credential
    }

    func importCLIAuthIfNeeded() async {
        do {
            if try await self.loadStoredCredential() != nil {
                return
            }

            guard let credential = try self.credentialReader.readCredential() else {
                return
            }

            try await self.persist(credential: credential)
            self.logger.info("Imported Codex CLI credential from auth.json")
        } catch {
            self.logger.error("Failed to import Codex CLI credential: \(error.localizedDescription)")
        }
    }

    static func generateCodeVerifier(byteCount: Int = 32) throws -> String {
        return try self.randomURLSafeString(byteCount: byteCount)
    }

    static func codeChallenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return Data(digest).base64URLEncodedString()
    }

    static func accessTokenExpiry(_ accessToken: String) -> Date? {
        return self.decodeClaims(from: accessToken)?.exp.map { Date(timeIntervalSince1970: $0) }
    }

    static func accessTokenEmail(_ accessToken: String) -> String? {
        return self.decodeClaims(from: accessToken)?.email
    }

    static func accessTokenSubject(_ accessToken: String) -> String? {
        return self.decodeClaims(from: accessToken)?.sub
    }

    @MainActor
    private func startAuthenticationSession(url: URL) async throws -> URL {
        return try await self.authenticator.authenticate(url: url, callbackURLScheme: Self.callbackScheme)
    }

    private func persist(credential: CodexOAuthCredential) async throws {
        guard let payloadData = try? Self.encoder.encode(credential),
              let payload = String(data: payloadData, encoding: .utf8) else {
            throw CodexOAuthError.credentialEncodingFailed
        }
        try await self.credentialStore.save(provider: .openaiCodex, apiKey: payload)
    }

    private func loadStoredCredential() async throws -> CodexOAuthCredential? {
        guard let payload = try await self.credentialStore.retrieve(provider: .openaiCodex),
              !payload.isEmpty else {
            return nil
        }

        guard let payloadData = payload.data(using: .utf8),
              let credential = try? Self.decoder.decode(CodexOAuthCredential.self, from: payloadData) else {
            throw CodexOAuthError.credentialDecodingFailed
        }

        return credential
    }

    private func exchangeAuthorizationCode(code: String, codeVerifier: String) async throws -> OAuthTokenResponse {
        let params = [
            "grant_type": "authorization_code",
            "client_id": Self.clientID,
            "redirect_uri": Self.redirectURI,
            "code": code,
            "code_verifier": codeVerifier,
        ]
        return try await self.performTokenRequest(parameters: params)
    }

    private func exchangeRefreshToken(refreshToken: String) async throws -> OAuthTokenResponse {
        let params = [
            "grant_type": "refresh_token",
            "client_id": Self.clientID,
            "refresh_token": refreshToken,
        ]
        return try await self.performTokenRequest(parameters: params)
    }

    private func refreshCredentialWithRetry(_ credential: CodexOAuthCredential) async throws -> CodexOAuthCredential {
        var lastError: Error?
        for attempt in 0..<3 {
            do {
                let response = try await self.exchangeRefreshToken(refreshToken: credential.refreshToken)
                let refreshed = try self.makeCredential(
                    from: response,
                    fallbackRefreshToken: credential.refreshToken,
                    fallbackAccountID: credential.accountID,
                    fallbackEmail: credential.accountEmail
                )
                return refreshed
            } catch {
                lastError = error
                if attempt < 2 {
                    let delay = 0.25 * pow(2.0, Double(attempt))
                    try await Task.sleep(for: .seconds(delay))
                }
            }
        }

        throw lastError ?? CodexOAuthError.invalidTokenResponse("Refresh failed without error details")
    }

    private func performTokenRequest(parameters: [String: String]) async throws -> OAuthTokenResponse {
        var request = URLRequest(url: Self.tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = Self.formEncodedData(parameters)

        let (data, response) = try await self.session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw CodexOAuthError.invalidTokenResponse("Non-HTTP response")
        }

        guard httpResponse.statusCode == 200 else {
            let message = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw CodexOAuthError.tokenExchangeFailed(statusCode: httpResponse.statusCode, message: message)
        }

        do {
            return try JSONDecoder().decode(OAuthTokenResponse.self, from: data)
        } catch {
            throw CodexOAuthError.invalidTokenResponse(error.localizedDescription)
        }
    }

    private func makeCredential(
        from response: OAuthTokenResponse,
        fallbackRefreshToken: String?,
        fallbackAccountID: String?,
        fallbackEmail: String?
    ) throws -> CodexOAuthCredential {
        let accessClaims = Self.decodeClaims(from: response.accessToken)
        let idClaims = Self.decodeClaims(from: response.idToken)
        let now = self.now()

        let refreshToken = response.refreshToken ?? fallbackRefreshToken
        guard let refreshToken, !refreshToken.isEmpty else {
            throw CodexOAuthError.missingRefreshToken
        }

        let accountID = response.accountID
            ?? accessClaims?.accountID
            ?? idClaims?.accountID
            ?? accessClaims?.sub
            ?? idClaims?.sub
            ?? fallbackAccountID
        guard let accountID, !accountID.isEmpty else {
            throw CodexOAuthError.missingAccountIdentifier
        }

        let accountEmail = accessClaims?.email ?? idClaims?.email ?? fallbackEmail
        let expiresAt = accessClaims?.exp.map { Date(timeIntervalSince1970: $0) }
            ?? idClaims?.exp.map { Date(timeIntervalSince1970: $0) }
            ?? response.expiresIn.map { now.addingTimeInterval(TimeInterval($0)) }
            ?? now.addingTimeInterval(3600)

        return CodexOAuthCredential(
            accessToken: response.accessToken,
            refreshToken: refreshToken,
            accountID: accountID,
            accountEmail: accountEmail,
            expiresAt: expiresAt,
            updatedAt: now
        )
    }

    private struct OAuthTokenResponse: Decodable {
        let accessToken: String
        let refreshToken: String?
        let expiresIn: Int?
        let accountID: String?
        let idToken: String?

        private enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case expiresIn = "expires_in"
            case accountID = "account_id"
            case idToken = "id_token"
        }
    }

    private struct JWTClaims: Decodable {
        let exp: TimeInterval?
        let sub: String?
        let email: String?
        let accountID: String?

        private enum CodingKeys: String, CodingKey {
            case exp
            case sub
            case email
            case accountID = "account_id"
        }
    }

    private static func buildAuthorizationURL(codeChallenge: String, state: String) -> URL {
        var components = URLComponents(url: Self.authorizeEndpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: Self.clientID),
            URLQueryItem(name: "redirect_uri", value: Self.redirectURI),
            URLQueryItem(name: "scope", value: "openid profile offline_access"),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
        ]
        return components.url!
    }

    private static func authorizationCode(from callbackURL: URL, expectedState: String) throws -> String {
        guard let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false) else {
            throw CodexOAuthError.missingAuthorizationCode
        }

        let items = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })

        if let error = items["error"] {
            let message = items["error_description"] ?? error
            throw CodexOAuthError.authorizationFailed(message)
        }

        guard items["state"] == expectedState else {
            throw CodexOAuthError.stateMismatch
        }

        guard let code = items["code"], !code.isEmpty else {
            throw CodexOAuthError.missingAuthorizationCode
        }

        return code
    }

    private static func formEncodedData(_ parameters: [String: String]) -> Data? {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "+&=")
        let encoded = parameters
            .map { key, value in
                let escapedKey = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
                let escapedValue = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
                return "\(escapedKey)=\(escapedValue)"
            }
            .joined(separator: "&")
        return Data(encoded.utf8)
    }

    private static func generateState() throws -> String {
        return try self.randomURLSafeString(byteCount: 16)
    }

    private static func randomURLSafeString(byteCount: Int) throws -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes)
        guard status == errSecSuccess else {
            throw CodexOAuthError.invalidTokenResponse("Failed to generate secure random bytes (\(status))")
        }
        return Data(bytes).base64URLEncodedString()
    }

    private static func decodeClaims(from token: String?) -> JWTClaims? {
        guard let token else {
            return nil
        }

        let segments = token.split(separator: ".")
        guard segments.count >= 2,
              let payloadData = Self.base64URLDecode(String(segments[1])),
              let claims = try? JSONDecoder().decode(JWTClaims.self, from: payloadData) else {
            return nil
        }

        return claims
    }

    private static func base64URLDecode(_ input: String) -> Data? {
        var base64 = input
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder > 0 {
            base64.append(String(repeating: "=", count: 4 - remainder))
        }
        return Data(base64Encoded: base64)
    }
}

private extension Data {
    func base64URLEncodedString() -> String {
        return self.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
