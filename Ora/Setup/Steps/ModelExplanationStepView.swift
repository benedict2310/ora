//
//  ModelExplanationStepView.swift
//  Ora
//
//  Model explanation step - explains what models are and gets user consent for download
//

import SwiftUI

struct ModelExplanationStepView: View {
    let state: SetupState
    let onDownloadNow: () -> Void
    let onMaybeLater: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            // Title
            Text("Ora Runs Locally")
                .font(.largeTitle)
                .fontWeight(.bold)

            Text("Three AI models power your private assistant")
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            Spacer()
                .frame(height: 8)

            // Model list card
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

                // Total size
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
            .background(Color(nsColor: .controlBackgroundColor))
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 12))

            // Privacy badge
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
            .padding()
            .background(Color.green.opacity(0.1))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.green.opacity(0.3), lineWidth: 1)
            )
            .cornerRadius(10)

            Spacer()

            // Action buttons
            HStack {
                Button("Maybe Later") {
                    self.onMaybeLater()
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)

                Spacer()

                Button(action: self.onDownloadNow) {
                    HStack {
                        Text("Download Now")
                        Image(systemName: "arrow.down.circle.fill")
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        }
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
        state: SetupState(),
        onDownloadNow: {},
        onMaybeLater: {}
    )
    .frame(width: 500, height: 450)
    .padding()
}
