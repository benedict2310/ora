//
//  ModelExplanationStepView.swift
//  Ora
//
//  Model explanation step - explains what models are and gets user consent for download
//

import SwiftUI

struct ModelExplanationStepView: View {
    let state: SetupState

    var body: some View {
        VStack(spacing: 20) {
            // Title
            Text("Ora Runs Locally")
                .font(.largeTitle)
                .fontWeight(.bold)

            Text("Three AI models power your private assistant")
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            GlassEffectContainer(spacing: 16) {
                VStack(spacing: 16) {
                    self.modelListCard
                    self.privacyCard
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
    }

    private var llmSizeDisplay: String {
        switch self.state.primaryLLM {
        case .qwen7B:
            return "~5 GB"
        case .qwen3_4B:
            return "~2.5 GB"
        case .qwen3B:
            return "~2 GB"
        default:
            return "~2.5 GB"
        }
    }

    private var modelListCard: some View {
        VStack(spacing: 0) {
            ModelInfoRow(
                icon: "waveform",
                iconColor: .blue,
                name: "Speech Recognition (Parakeet)",
                description: "Converts your voice to text",
                size: "~600 MB"
            )

            Divider()
                .padding(.leading, 52)

            ModelInfoRow(
                icon: "brain",
                iconColor: .purple,
                name: self.state.primaryLLM.displayName,
                description: "Understands requests and generates responses",
                size: self.llmSizeDisplay
            )

            Divider()
                .padding(.leading, 52)

            ModelInfoRow(
                icon: "speaker.wave.2",
                iconColor: .green,
                name: "Text-to-Speech (Kokoro)",
                description: "Speaks responses back to you",
                size: "~500 MB"
            )

            Divider()

            HStack {
                Spacer()
                Text("Total download:")
                    .foregroundColor(.secondary)
                Text(SetupState.totalModelSizeDisplay)
                    .fontWeight(.semibold)
                    .foregroundColor(.accentColor)
            }
            .padding()
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.6))
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var privacyCard: some View {
        HStack(spacing: 12) {
            Image(systemName: "lock.shield.fill")
                .font(.title2)
                .foregroundColor(.green)

            VStack(alignment: .leading, spacing: 2) {
                Text("Your privacy is protected")
                    .fontWeight(.medium)
                Text("All models run locally on your Mac. Your conversations never leave your device.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()
        }
        .padding(12)
        .background(Color.green.opacity(0.08))
        .glassEffect(.regular.tint(Color.green.opacity(0.2)), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

// MARK: - Model Info Row

private struct ModelInfoRow: View {
    let icon: String
    let iconColor: Color
    let name: String
    let description: String
    let size: String

    var body: some View {
        HStack(spacing: 12) {
            // Icon
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(self.iconColor.opacity(0.15))
                    .frame(width: 40, height: 40)

                Image(systemName: self.icon)
                    .font(.system(size: 18))
                    .foregroundColor(self.iconColor)
            }

            // Name and description
            VStack(alignment: .leading, spacing: 2) {
                Text(self.name)
                    .fontWeight(.medium)
                Text(self.description)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            // Size
            Text(self.size)
                .font(.callout)
                .foregroundColor(.secondary)
        }
        .padding()
    }
}

// MARK: - Preview

#Preview {
    ModelExplanationStepView(
        state: SetupState()
    )
    .frame(width: 500, height: 450)
    .padding()
}
