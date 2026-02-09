//
//  CodexCredentialReader.swift
//  Ora
//
//  Reads Codex CLI OAuth credentials from ~/.codex/auth.json.
//

import Foundation

protocol CodexCredentialReading {
    func readCredential() throws -> CodexOAuthCredential?
}

struct CodexCredentialReader: CodexCredentialReading {
    private let environment: [String: String]
    private let fileManager: FileManager
    private let now: @Sendable () -> Date

    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.environment = environment
        self.fileManager = fileManager
        self.now = now
    }

    func readCredential() throws -> CodexOAuthCredential? {
        let fileURL = self.authFileURL()
        guard self.fileManager.fileExists(atPath: fileURL.path) else {
            return nil
        }

        let data = try Data(contentsOf: fileURL)
        let authFile = try JSONDecoder().decode(CodexCLIAuthFile.self, from: data)
        let tokenData = authFile.tokens

        guard !tokenData.accessToken.isEmpty, !tokenData.refreshToken.isEmpty else {
            return nil
        }

        let accountID = tokenData.accountID
            ?? CodexOAuthManager.accessTokenSubject(tokenData.accessToken)
            ?? CodexOAuthManager.accessTokenEmail(tokenData.accessToken)
        guard let accountID, !accountID.isEmpty else {
            return nil
        }

        let expiresAt = tokenData.expiresAt
            ?? CodexOAuthManager.accessTokenExpiry(tokenData.accessToken)
            ?? self.now().addingTimeInterval(3600)

        return CodexOAuthCredential(
            accessToken: tokenData.accessToken,
            refreshToken: tokenData.refreshToken,
            accountID: accountID,
            accountEmail: tokenData.accountEmail ?? CodexOAuthManager.accessTokenEmail(tokenData.accessToken),
            expiresAt: expiresAt,
            updatedAt: self.now()
        )
    }

    private func authFileURL() -> URL {
        if let codexHome = self.environment["CODEX_HOME"], !codexHome.isEmpty {
            let expanded = NSString(string: codexHome).expandingTildeInPath
            return URL(fileURLWithPath: expanded).appendingPathComponent("auth.json")
        }

        let codexDirectory = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".codex")
        return codexDirectory.appendingPathComponent("auth.json")
    }

    private struct CodexCLIAuthFile: Decodable {
        let tokens: Tokens

        struct Tokens: Decodable {
            let accessToken: String
            let refreshToken: String
            let accountID: String?
            let accountEmail: String?
            let expiresAt: Date?

            private enum CodingKeys: String, CodingKey {
                case accessToken = "access_token"
                case refreshToken = "refresh_token"
                case accountID = "account_id"
                case accountEmail = "account_email"
                case expiresAt = "expires_at"
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                self.accessToken = try container.decode(String.self, forKey: .accessToken)
                self.refreshToken = try container.decode(String.self, forKey: .refreshToken)
                self.accountID = try container.decodeIfPresent(String.self, forKey: .accountID)
                self.accountEmail = try container.decodeIfPresent(String.self, forKey: .accountEmail)

                if let expiresString = try container.decodeIfPresent(String.self, forKey: .expiresAt) {
                    self.expiresAt = ISO8601DateFormatter().date(from: expiresString)
                } else {
                    self.expiresAt = nil
                }
            }
        }
    }
}
