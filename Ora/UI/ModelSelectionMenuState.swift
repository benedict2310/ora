//
//  ModelSelectionMenuState.swift
//  Ora
//
//  View state for menubar provider/model selection UI.
//

import Foundation

struct ModelSelectionMenuState: Sendable, Equatable {
    let activeProvider: LLMProviderType
    let activeModelDisplayName: String
    let sections: [ProviderModelSection]
    let setupRequiredProviders: [LLMProviderType]
    let showsOpenAISetupAction: Bool
    let openAIUnavailableMessage: String?

    var showsSetupAction: Bool {
        return !self.setupRequiredProviders.isEmpty
    }
}

struct ProviderModelSection: Sendable, Equatable {
    let provider: LLMProviderType
    let title: String
    let options: [ProviderModelOption]
}

struct ProviderModelOption: Sendable, Equatable, Hashable {
    let provider: LLMProviderType
    let identifier: String
    let displayName: String
    let isSelected: Bool
}
