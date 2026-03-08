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

    private let logger = Logger.ora(category: "providers")
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
        self.cachedModels = UserDefaults.standard.openAIDiscoveredModels
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
                let discoveredModels = try self.extractModelOptions(from: data, usesCodexOAuth: requestAuthorization.usesCodexOAuth)
                let filtered = self.filterAndSort(models: discoveredModels)
                self.cachedModels = filtered
                self.cachedAt = self.now()
                UserDefaults.standard.openAIDiscoveredModels = filtered
                return .available(models: filtered, isStale: false)
            case 401:
                self.logDiscoveryFailure(statusCode: 401, body: String(data: data, encoding: .utf8) ?? "", usesCodexOAuth: requestAuthorization.usesCodexOAuth)
                return self.cachedOrUnavailable(.unauthorized)
            default:
                let responseBody = String(data: data, encoding: .utf8) ?? ""
                self.logDiscoveryFailure(
                    statusCode: httpResponse.statusCode,
                    body: responseBody,
                    usesCodexOAuth: requestAuthorization.usesCodexOAuth
                )
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
            let inputModalities: [String]?
            let supportsImageDetailOriginal: Bool?

            private enum CodingKeys: String, CodingKey {
                case slug
                case id
                case model
                case inputModalities = "input_modalities"
                case supportsImageDetailOriginal = "supports_image_detail_original"
            }
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

    private func extractModelOptions(from data: Data, usesCodexOAuth: Bool) throws -> [OpenAIModelOption] {
        if let openAIResponse = try? JSONDecoder().decode(OpenAIModelsListResponse.self, from: data) {
            return openAIResponse.data.map {
                OpenAIModelOption(identifier: $0.id, source: .discovered)
            }
        }

        let codexResponse = try JSONDecoder().decode(CodexModelsListResponse.self, from: data)
        return codexResponse.models.compactMap { entry in
            let identifier: String
            if let slug = entry.slug, !slug.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                identifier = slug
            } else if let id = entry.id, !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                identifier = id
            } else if let model = entry.model, !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                identifier = model
            } else {
                return nil
            }

            let supportsImageInput: Bool
            if usesCodexOAuth {
                supportsImageInput = entry.inputModalities?.contains(where: { $0.caseInsensitiveCompare("image") == .orderedSame })
                    ?? true
            } else {
                supportsImageInput = false
            }

            return OpenAIModelOption(
                identifier: identifier,
                source: .discovered,
                supportsImageInput: supportsImageInput,
                supportsImageDetailOriginal: entry.supportsImageDetailOriginal ?? false
            )
        }
    }

    private func filterAndSort(models: [OpenAIModelOption]) -> [OpenAIModelOption] {
        var seen: Set<String> = []
        var filteredModels: [OpenAIModelOption] = []

        for model in models {
            let identifier = model.identifier.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !identifier.isEmpty else { continue }
            guard self.isUserFacingModel(identifier) else { continue }
            guard !seen.contains(identifier) else { continue }
            seen.insert(identifier)
            filteredModels.append(model)
        }

        filteredModels.sort { lhs, rhs in
            if lhs.identifier == OpenAIModel.preferredDefault.rawValue { return true }
            if rhs.identifier == OpenAIModel.preferredDefault.rawValue { return false }
            return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }

        return filteredModels
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

    private func logDiscoveryFailure(statusCode: Int, body: String, usesCodexOAuth: Bool) {
        if usesCodexOAuth {
            self.logger.error("OPENAI_DISCOVERY_CODEX_REQUEST_FAILED")
        } else {
            self.logger.error("OPENAI_DISCOVERY_APIKEY_REQUEST_FAILED")
        }

        switch statusCode {
        case 400:
            self.logger.error("OPENAI_DISCOVERY_HTTP_400")
        case 401:
            self.logger.error("OPENAI_DISCOVERY_HTTP_401")
        case 403:
            self.logger.error("OPENAI_DISCOVERY_HTTP_403")
        case 404:
            self.logger.error("OPENAI_DISCOVERY_HTTP_404")
        case 408:
            self.logger.error("OPENAI_DISCOVERY_HTTP_408")
        case 429:
            self.logger.error("OPENAI_DISCOVERY_HTTP_429")
        case 500...599:
            self.logger.error("OPENAI_DISCOVERY_HTTP_5XX")
        default:
            self.logger.error("OPENAI_DISCOVERY_HTTP_OTHER")
        }

        switch Self.classifyDiscoveryFailureBody(body) {
        case .invalidModel:
            self.logger.error("OPENAI_DISCOVERY_BODY_INVALID_MODEL")
        case .requestShape:
            self.logger.error("OPENAI_DISCOVERY_BODY_REQUEST_SHAPE")
        case .tokenParameter:
            self.logger.error("OPENAI_DISCOVERY_BODY_TOKEN_PARAMETER")
        case .contextLength:
            self.logger.error("OPENAI_DISCOVERY_BODY_CONTEXT_LENGTH")
        case .unknown:
            self.logger.error("OPENAI_DISCOVERY_BODY_UNKNOWN")
        }
    }

    private enum DiscoveryFailureBodyCategory {
        case invalidModel
        case requestShape
        case tokenParameter
        case contextLength
        case unknown
    }

    private static func classifyDiscoveryFailureBody(_ body: String) -> DiscoveryFailureBodyCategory {
        let normalized = body.lowercased()
        if normalized.contains("model") &&
            (normalized.contains("not found") ||
                normalized.contains("does not exist") ||
                normalized.contains("invalid model") ||
                normalized.contains("unsupported")) {
            return .invalidModel
        }
        if normalized.contains("max_tokens") ||
            normalized.contains("max_output_tokens") ||
            normalized.contains("max_completion_tokens") {
            return .tokenParameter
        }
        if normalized.contains("context length") ||
            normalized.contains("maximum context") ||
            normalized.contains("too many tokens") {
            return .contextLength
        }
        if normalized.contains("invalid_request_error") ||
            normalized.contains("invalid value") ||
            normalized.contains("unsupported value") ||
            normalized.contains("invalid type") ||
            normalized.contains("validation") ||
            normalized.contains("\"role\"") ||
            normalized.contains("messages") ||
            normalized.contains("input") ||
            normalized.contains("tool_choice") {
            return .requestShape
        }
        return .unknown
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
