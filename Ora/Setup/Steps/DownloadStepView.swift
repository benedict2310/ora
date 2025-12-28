//
//  DownloadStepView.swift
//  Ora
//
//  Model download step
//

import SwiftUI

struct DownloadStepView: View {
    let state: SetupState
    let onRetry: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Text("Downloading Models")
                .font(.largeTitle)
                .fontWeight(.bold)

            Text("Ora is downloading the AI models needed for voice recognition and responses.")
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            Spacer()
                .frame(height: 20)

            // Overall progress
            VStack(spacing: 16) {
                // Progress bar
                ProgressView(value: self.state.downloadProgress)
                    .progressViewStyle(.linear)

                HStack {
                    if let currentModel = self.state.downloadingModel {
                        Text("Downloading \(currentModel)...")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else if self.state.downloadProgress >= 1.0 {
                        Label("All models downloaded", systemImage: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundColor(.green)
                    }

                    Spacer()

                    Text("\(Int(self.state.downloadProgress * 100))%")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .monospacedDigit()
                }

                // Individual model status
                VStack(alignment: .leading, spacing: 12) {
                    ModelDownloadRow(
                        name: "Parakeet ASR",
                        size: "~600 MB",
                        progress: self.modelProgress(for: .parakeetTDT)
                    )
                    ModelDownloadRow(
                        name: self.state.primaryLLM.displayName,
                        size: self.state.primaryLLM == .qwen7B ? "~5 GB" : "~2 GB",
                        progress: self.modelProgress(for: self.state.primaryLLM)
                    )
                    ModelDownloadRow(
                        name: "Kokoro TTS",
                        size: "~500 MB",
                        progress: self.modelProgress(for: .kokoro)
                    )
                }
                .padding()
                .background(Color(nsColor: .controlBackgroundColor))
                .cornerRadius(8)
            }

            Spacer()

            // Error state
            if let error = self.state.downloadError {
                VStack(spacing: 12) {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundColor(.red)

                    Button("Retry Download") {
                        self.onRetry()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }

            // Note
            if self.state.downloadError == nil && self.state.downloadProgress < 1.0 {
                Label("This may take a few minutes depending on your internet speed.", systemImage: "info.circle")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    private func modelProgress(for model: ModelIdentifier) -> Double {
        self.state.modelProgresses[model] ?? 0
    }
}

struct ModelDownloadRow: View {
    let name: String
    let size: String
    let progress: Double

    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                Text(self.name)
                    .fontWeight(.medium)
                Text(self.size)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            if self.progress >= 1.0 {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
            } else if self.progress > 0 {
                ProgressView()
                    .scaleEffect(0.7)
            } else {
                Image(systemName: "circle")
                    .foregroundColor(.secondary)
            }
        }
    }
}
