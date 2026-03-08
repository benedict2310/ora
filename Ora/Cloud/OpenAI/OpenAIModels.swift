//
//  OpenAIModels.swift
//  Ora
//
//  OpenAI model configuration
//

import Foundation

/// Available OpenAI models
public enum OpenAIModel: String, Sendable, CaseIterable {
    case gpt52 = "gpt-5.2"
    case gpt4o = "gpt-4o"
    case gpt4oMini = "gpt-4o-mini"
    case o3Mini = "o3-mini"

    public static let preferredDefault: OpenAIModel = .gpt52

    public var displayName: String {
        switch self {
        case .gpt52: return "GPT-5.2"
        case .gpt4o: return "GPT-4o"
        case .gpt4oMini: return "GPT-4o Mini"
        case .o3Mini: return "o3-mini"
        }
    }

    static var curatedOptions: [OpenAIModelOption] {
        return self.allCases.map { model in
            OpenAIModelOption(
                identifier: model.rawValue,
                displayName: model.displayName,
                source: .curated
            )
        }
    }

    public static func displayName(for identifier: String) -> String {
        if let curated = Self(rawValue: identifier) {
            return curated.displayName
        }
        return OpenAIModelOption.defaultDisplayName(for: identifier)
    }

    static func codexCuratedImageFallbackSupportsInput(for identifier: String) -> Bool {
        return [
            "gpt-5.2-codex",
            Self.gpt52.rawValue,
        ].contains(identifier.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

// MARK: - Model Option

struct OpenAIModelOption: Sendable, Equatable, Hashable, Codable {

    enum Source: String, Sendable, Equatable, Hashable, Codable {
        case curated
        case discovered
    }

    let identifier: String
    let displayName: String
    let source: Source
    let supportsImageInput: Bool?
    let supportsImageDetailOriginal: Bool?

    init(
        identifier: String,
        displayName: String,
        source: Source,
        supportsImageInput: Bool? = nil,
        supportsImageDetailOriginal: Bool? = nil
    ) {
        self.identifier = identifier
        self.displayName = displayName
        self.source = source
        self.supportsImageInput = supportsImageInput
        self.supportsImageDetailOriginal = supportsImageDetailOriginal
    }

    init(
        identifier: String,
        source: Source,
        supportsImageInput: Bool? = nil,
        supportsImageDetailOriginal: Bool? = nil
    ) {
        self.identifier = identifier
        self.displayName = OpenAIModel.displayName(for: identifier)
        self.source = source
        self.supportsImageInput = supportsImageInput
        self.supportsImageDetailOriginal = supportsImageDetailOriginal
    }

    static func defaultDisplayName(for identifier: String) -> String {
        let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return "Unknown Model"
        }

        let lowercased = trimmed.lowercased()
        if lowercased.hasPrefix("gpt-") {
            let suffix = String(trimmed.dropFirst(4))
            return "GPT-\(suffix)"
        }
        if lowercased.hasPrefix("o") {
            return trimmed.lowercased()
        }

        return trimmed
    }

    var resolvedSupportsImageInput: Bool {
        if let supportsImageInput = self.supportsImageInput {
            return supportsImageInput
        }
        return OpenAIModel.codexCuratedImageFallbackSupportsInput(for: self.identifier)
    }
}
