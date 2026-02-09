//
//  CodexCredentialReaderTests.swift
//  OraTests
//
//  Tests for reading Codex CLI credentials from auth.json.
//

import XCTest
@testable import Ora

final class CodexCredentialReaderTests: XCTestCase {
    private var temporaryDirectoryURL: URL!

    override func setUpWithError() throws {
        self.temporaryDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: self.temporaryDirectoryURL,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        if let temporaryDirectoryURL {
            try? FileManager.default.removeItem(at: temporaryDirectoryURL)
        }
        self.temporaryDirectoryURL = nil
    }

    func test_readCredential_parsesAuthJson() throws {
        // Given
        let exp = Date(timeIntervalSince1970: 1_892_160_000) // 2030-01-01T00:00:00Z
        let token = self.makeJWT(expiry: exp, email: "user@example.com", subject: "acct_123")
        let codexHome = self.temporaryDirectoryURL.path
        try self.writeAuthFile(
            to: codexHome,
            content: """
            {
              "tokens": {
                "access_token": "\(token)",
                "refresh_token": "rt_abc",
                "account_id": "acct_123",
                "account_email": "user@example.com"
              },
              "last_refresh": "2026-01-01T00:00:00Z"
            }
            """
        )
        let reader = CodexCredentialReader(environment: ["CODEX_HOME": codexHome], now: {
            Date(timeIntervalSince1970: 1_700_000_000)
        })

        // When
        let credential = try reader.readCredential()

        // Then
        XCTAssertEqual(credential?.accessToken, token)
        XCTAssertEqual(credential?.refreshToken, "rt_abc")
        XCTAssertEqual(credential?.accountID, "acct_123")
        XCTAssertEqual(credential?.accountEmail, "user@example.com")
        XCTAssertEqual(credential?.expiresAt, exp)
    }

    func test_readCredential_missingFile_returnsNil() throws {
        // Given
        let reader = CodexCredentialReader(
            environment: ["CODEX_HOME": self.temporaryDirectoryURL.path]
        )

        // When
        let credential = try reader.readCredential()

        // Then
        XCTAssertNil(credential)
    }

    func test_readCredential_usesTokenClaimsWhenAccountIdMissing() throws {
        // Given
        let exp = Date(timeIntervalSince1970: 1_892_160_000)
        let token = self.makeJWT(expiry: exp, email: "user@example.com", subject: "acct_claims")
        let codexHome = self.temporaryDirectoryURL.path
        try self.writeAuthFile(
            to: codexHome,
            content: """
            {
              "tokens": {
                "access_token": "\(token)",
                "refresh_token": "rt_abc"
              }
            }
            """
        )
        let reader = CodexCredentialReader(environment: ["CODEX_HOME": codexHome])

        // When
        let credential = try reader.readCredential()

        // Then
        XCTAssertEqual(credential?.accountID, "acct_claims")
        XCTAssertEqual(credential?.accountEmail, "user@example.com")
    }

    func test_readCredential_prefersChatGPTAccountIdClaim() throws {
        let exp = Date(timeIntervalSince1970: 1_892_160_000)
        let token = self.makeJWT(
            expiry: exp,
            email: "user@example.com",
            subject: "sub_fallback",
            chatGPTAccountID: "acct_chatgpt"
        )
        let codexHome = self.temporaryDirectoryURL.path
        try self.writeAuthFile(
            to: codexHome,
            content: """
            {
              "tokens": {
                "access_token": "\(token)",
                "refresh_token": "rt_abc"
              }
            }
            """
        )
        let reader = CodexCredentialReader(environment: ["CODEX_HOME": codexHome])

        let credential = try reader.readCredential()

        XCTAssertEqual(credential?.accountID, "acct_chatgpt")
        XCTAssertEqual(credential?.accountEmail, "user@example.com")
    }

    private func writeAuthFile(to codexHome: String, content: String) throws {
        let homeURL = URL(fileURLWithPath: codexHome, isDirectory: true)
        try FileManager.default.createDirectory(at: homeURL, withIntermediateDirectories: true)
        let authFileURL = homeURL.appendingPathComponent("auth.json")
        try content.write(to: authFileURL, atomically: true, encoding: .utf8)
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
        let signature = "signature"
        return [
            self.base64URLEncode(header),
            self.base64URLEncode(payload),
            self.base64URLEncode(signature),
        ].joined(separator: ".")
    }

    private func base64URLEncode(_ string: String) -> String {
        return Data(string.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
