//
//  OpenAIModelDiscoveryService.swift
//  Ora
//
//  Fetches and caches OpenAI model discovery results.
//

import Foundation
import os

protocol OpenAIModelDiscovering: Sendable {
    func fetchModelAvailability(forceRefresh: Bool) async -> OpenAIModelDiscoveryState
}

enum OpenAIModelDiscoveryState: Sendable, Equatable {
    case available(models: [OpenAIModelOption], isStale: Bool)
    case unavailable(OpenAIModelDiscoveryUnavailableReason)
}

enum OpenAIModelDiscoveryUnavailableReason: Sendable, Equatable {
    case missingCredential
    case disconnected
    case unauthorized
    case requestFailed(String)
}

actor OpenAIModelDiscoveryService: OpenAIModelDiscovering {

    // MARK: - Properties

    private let logger = Logger(subsystem: "com.ora.app", category: "providers")
    private let credentialStore: CredentialStore
    private let codexOAuthManager: (any CodexOAuthManaging)?
    private let session: URLSession
    private let cacheTTL: TimeInterval
    private let now: @Sendable () -> Date
    private let apiKeyModelsEndpoint = URL(string: "https://api.openai.com/v1/models")!
    private let codexModelsEndpoint = URL(string: "https://chatgpt.com/backend-api/codex/models")!

    private var cachedModels: [OpenAIModelOption]
    private var cachedAt: Date?

    // MARK: - Initialization

    init(
        credentialStore: CredentialStore = KeychainCredentialStore(),
        codexOAuthManager: (any CodexOAuthManaging)? = nil,
        session: URLSession = .shared,
        cacheTTL: TimeInterval = 300,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.credentialStore = credentialStore
        self.codexOAuthManager = codexOAuthManager
        self.session = session
        self.cacheTTL = cacheTTL
        self.now = now
        self.cachedModels = UserDefaults.standard.openAIDiscoveredModelIdentifiers.map {
            OpenAIModelOption(identifier: $0, source: .discovered)
        }
        self.cachedAt = self.cachedModels.isEmpty ? nil : self.now()
    }

    // MARK: - OpenAIModelDiscovering

    func fetchModelAvailability(forceRefresh: Bool = false) async -> OpenAIModelDiscoveryState {
        if !forceRefresh, self.isCacheValid, !self.cachedModels.isEmpty {
            return .available(models: self.cachedModels, isStale: false)
        }

        do {
            guard let requestAuthorization = try await self.resolveAuthorization() else {
                return .unavailable(.missingCredential)
            }

            var request = URLRequest(url: requestAuthorization.endpoint)
            request.httpMethod = "GET"
            request.setValue("Bearer \(requestAuthorization.token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            if requestAuthorization.usesCodexOAuth {
                request.setValue(CodexOAuthManager.originator, forHTTPHeaderField: "originator")
                request.setValue(Self.clientVersion, forHTTPHeaderField: "version")
                request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
            }
            if let accountID = requestAuthorization.accountID {
                request.setValue(accountID, forHTTPHeaderField: "chatgpt-account-id")
            }
            request.timeoutInterval = 20

            let (data, response) = try await self.session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                return self.cachedOrUnavailable(.disconnected)
            }

            switch httpResponse.statusCode {
            case 200:
                let identifiers = try self.extractModelIdentifiers(from: data)
                let filtered = self.filterAndSort(identifiers: identifiers)
                self.cachedModels = filtered
                self.cachedAt = self.now()
                UserDefaults.standard.openAIDiscoveredModelIdentifiers = filtered.map(\.identifier)
                return .available(models: filtered, isStale: false)
            case 401:
                return self.cachedOrUnavailable(.unauthorized)
            default:
                let responseBody = String(data: data, encoding: .utf8) ?? ""
                let message = responseBody.isEmpty
                    ? "HTTP \(httpResponse.statusCode)"
                    : "HTTP \(httpResponse.statusCode): \(responseBody)"
                return self.cachedOrUnavailable(.requestFailed(message))
            }
        } catch is CancellationError {
            return self.cachedOrUnavailable(.disconnected)
        } catch let urlError as URLError {
            self.logger.error("OpenAI model discovery URL error: \(urlError.localizedDescription)")
            return self.cachedOrUnavailable(.disconnected)
        } catch {
            self.logger.error("OpenAI model discovery failed: \(error.localizedDescription)")
            return self.cachedOrUnavailable(.requestFailed(error.localizedDescription))
        }
    }

    // MARK: - Private

    private var isCacheValid: Bool {
        guard let cachedAt else { return false }
        return self.now().timeIntervalSince(cachedAt) <= self.cacheTTL
    }

    private func cachedOrUnavailable(_ unavailableReason: OpenAIModelDiscoveryUnavailableReason) -> OpenAIModelDiscoveryState {
        guard !self.cachedModels.isEmpty else {
            return .unavailable(unavailableReason)
        }
        return .available(models: self.cachedModels, isStale: true)
    }

    private struct RequestAuthorization: Sendable {
        let token: String
        let accountID: String?
        let endpoint: URL
        let usesCodexOAuth: Bool
    }

    private struct OpenAIModelsListResponse: Decodable {
        struct Entry: Decodable {
            let id: String
        }
        let data: [Entry]
    }

    private struct CodexModelsListResponse: Decodable {
        struct Entry: Decodable {
            let slug: String?
            let id: String?
            let model: String?
        }
        let models: [Entry]
    }

    private func resolveAuthorization() async throws -> RequestAuthorization? {
        if let codexOAuthManager = self.codexOAuthManager,
           let credential = try await codexOAuthManager.validCredentialIfAvailable() {
            var components = URLComponents(url: self.codexModelsEndpoint, resolvingAgainstBaseURL: false)
            components?.queryItems = [URLQueryItem(name: "client_version", value: Self.clientVersion)]
            return RequestAuthorization(
                token: credential.accessToken,
                accountID: credential.accountID,
                endpoint: components?.url ?? self.codexModelsEndpoint,
                usesCodexOAuth: true
            )
        }

        guard let apiKey = try await self.credentialStore.retrieve(provider: .openai),
              !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        return RequestAuthorization(
            token: apiKey,
            accountID: nil,
            endpoint: self.apiKeyModelsEndpoint,
            usesCodexOAuth: false
        )
    }

    private func extractModelIdentifiers(from data: Data) throws -> [String] {
        if let openAIResponse = try? JSONDecoder().decode(OpenAIModelsListResponse.self, from: data) {
            return openAIResponse.data.map(\.id)
        }

        let codexResponse = try JSONDecoder().decode(CodexModelsListResponse.self, from: data)
        return codexResponse.models.compactMap { entry in
            if let slug = entry.slug, !slug.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return slug
            }
            if let id = entry.id, !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return id
            }
            if let model = entry.model, !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return model
            }
            return nil
        }
    }

    private func filterAndSort(identifiers: [String]) -> [OpenAIModelOption] {
        var seen: Set<String> = []
        var models: [OpenAIModelOption] = []

        for rawIdentifier in identifiers {
            let identifier = rawIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !identifier.isEmpty else { continue }
            guard self.isUserFacingModel(identifier) else { continue }
            guard !seen.contains(identifier) else { continue }
            seen.insert(identifier)
            models.append(OpenAIModelOption(identifier: identifier, source: .discovered))
        }

        models.sort { lhs, rhs in
            if lhs.identifier == OpenAIModel.preferredDefault.rawValue { return true }
            if rhs.identifier == OpenAIModel.preferredDefault.rawValue { return false }
            return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }

        return models
    }

    private func isUserFacingModel(_ identifier: String) -> Bool {
        let lowercased = identifier.lowercased()
        let include = lowercased.hasPrefix("gpt-") || lowercased.hasPrefix("o")
        guard include else { return false }

        let excludedTokens = [
            "audio",
            "transcribe",
            "transcription",
            "embedding",
            "moderation",
            "image",
            "whisper",
            "realtime",
            "tts",
            "search",
        ]
        return !excludedTokens.contains(where: { lowercased.contains($0) })
    }

    private static var clientVersion: String {
        if let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
           !version.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return version
        }
        return "0.0.0"
    }

    private static var userAgent: String {
        return "\(CodexOAuthManager.originator)/\(Self.clientVersion) (Ora macOS)"
    }
}
