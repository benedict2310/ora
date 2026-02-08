//
//  CloudIndicator.swift
//  Ora
//
//  Badge shown when a cloud LLM provider is active
//

import SwiftUI

struct CloudIndicator: View {
    let providerType: LLMProviderType

    var body: some View {
        Label("Cloud \(self.providerName)", systemImage: "cloud.fill")
            .font(.caption2)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.orange.opacity(0.18))
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(Color.orange.opacity(0.35), lineWidth: 0.8)
            )
            .foregroundColor(.orange)
            .accessibilityLabel("Cloud provider active: \(self.providerType.displayName)")
    }

    private var providerName: String {
        switch self.providerType {
        case .anthropic:
            return "Anthropic"
        case .openai:
            return "OpenAI"
        case .local:
            return ""
        }
    }
}
