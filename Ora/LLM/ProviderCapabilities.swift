//
//  ProviderCapabilities.swift
//  Ora
//
//  Shared capability definitions for LLM providers.
//

import Foundation

public struct ProviderCapabilities: Sendable, Equatable {
    public let supportsTextInput: Bool
    public let supportsImageInput: Bool

    public init(
        supportsTextInput: Bool = true,
        supportsImageInput: Bool = false
    ) {
        self.supportsTextInput = supportsTextInput
        self.supportsImageInput = supportsImageInput
    }

    public static let textOnly = ProviderCapabilities(
        supportsTextInput: true,
        supportsImageInput: false
    )

    public static let multimodal = ProviderCapabilities(
        supportsTextInput: true,
        supportsImageInput: true
    )
}
