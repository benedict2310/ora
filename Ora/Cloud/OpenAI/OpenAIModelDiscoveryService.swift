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

    // MARK: - Types

    private struct ModelsResponse: Decodable {
        struct Entry: Decodable {
            let id: String
        }

        let data: [Entry]
    }

    // MARK: - Properties

    private let logger = Logger(subsystem: "com.ora.app", category: "providers")
    private let credentialStore: CredentialStore
    private let session: URLSession
    private let cacheTTL: TimeInterval
    private let now: @Sendable () -> Date
    private let endpoint = URL(string: "https://api.openai.com/v1/models")!

    private var cachedModels: [OpenAIModelOption]
    private var cachedAt: Date?

    // MARK: - Initialization

    init(
        credentialStore: CredentialStore = KeychainCredentialStore(),
        session: URLSession = .shared,
        cacheTTL: TimeInterval = 300,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.credentialStore = credentialStore
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
            guard let apiKey = try await self.credentialStore.retrieve(provider: .openai),
                  !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .unavailable(.missingCredential)
            }

            var request = URLRequest(url: self.endpoint)
            request.httpMethod = "GET"
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.timeoutInterval = 20

            let (data, response) = try await self.session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                return self.cachedOrUnavailable(.disconnected)
            }

            switch httpResponse.statusCode {
            case 200:
                let responseBody = try JSONDecoder().decode(ModelsResponse.self, from: data)
                let filtered = self.filterAndSort(entries: responseBody.data)
                self.cachedModels = filtered
                self.cachedAt = self.now()
                UserDefaults.standard.openAIDiscoveredModelIdentifiers = filtered.map(\.identifier)
                return .available(models: filtered, isStale: false)
            case 401:
                return self.cachedOrUnavailable(.unauthorized)
            default:
                return self.cachedOrUnavailable(.requestFailed("HTTP \(httpResponse.statusCode)"))
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

    private func filterAndSort(entries: [ModelsResponse.Entry]) -> [OpenAIModelOption] {
        var seen: Set<String> = []
        var models: [OpenAIModelOption] = []

        for entry in entries {
            let identifier = entry.id.trimmingCharacters(in: .whitespacesAndNewlines)
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
}
