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
}

// MARK: - Model Option

struct OpenAIModelOption: Sendable, Equatable, Hashable {

    enum Source: Sendable, Equatable, Hashable {
        case curated
        case discovered
    }

    let identifier: String
    let displayName: String
    let source: Source

    init(identifier: String, displayName: String, source: Source) {
        self.identifier = identifier
        self.displayName = displayName
        self.source = source
    }

    init(identifier: String, source: Source) {
        self.identifier = identifier
        self.displayName = OpenAIModel.displayName(for: identifier)
        self.source = source
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
}
