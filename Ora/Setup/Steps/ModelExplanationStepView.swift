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
            Text("Model Setup")
                .font(.largeTitle)
                .fontWeight(.bold)

            Text("Ora uses three local models. If they are already on this Mac, Ora reuses them.")
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

    private var modelListCard: some View {
        VStack(spacing: 0) {
            ModelInfoRow(
                icon: "waveform",
                iconColor: .blue,
                name: "Speech Recognition (Parakeet)",
                description: "Converts your speech into text",
                size: "~600 MB"
            )

            Divider()
                .padding(.leading, 52)

            ModelInfoRow(
                icon: "brain",
                iconColor: .purple,
                name: self.state.primaryLLM.displayName,
                description: "Understands requests and plans responses",
                size: self.state.primaryLLM.sizeDisplay
            )

            Divider()
                .padding(.leading, 52)

            ModelInfoRow(
                icon: "speaker.wave.2",
                iconColor: .green,
                name: "Text-to-Speech (Kokoro)",
                description: "Speaks replies with natural voice output",
                size: "~500 MB"
            )

            Divider()

            HStack {
                Spacer()
                Text("Total download:")
                    .foregroundColor(.secondary)
                Text(SetupState.totalModelSizeDisplay(for: self.state.primaryLLM))
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
                Text("Privacy-first by default")
                    .fontWeight(.medium)
                Text("Model files run on your Mac. Existing downloads are verified and skipped.")
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
