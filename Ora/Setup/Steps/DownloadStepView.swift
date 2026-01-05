//
//  DownloadStepView.swift
//  Ora
//
//  Model download step with enhanced progress UI
//

import SwiftUI

struct DownloadStepView: View {
    let state: SetupState
    let onRetry: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Text("Downloading Models")
                .font(.largeTitle)
                .fontWeight(.bold)

            Text("This may take a few minutes depending on your connection")
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            Spacer()
                .frame(height: 8)

            // Overall progress section
            VStack(spacing: 12) {
                // Progress bar
                ProgressView(value: self.state.downloadProgress)
                    .progressViewStyle(.linear)

                // Stats row
                HStack {
                    // Bytes downloaded
                    HStack(spacing: 4) {
                        Text(self.state.formattedBytesDownloaded)
                            .fontWeight(.medium)
                        Text("of")
                            .foregroundColor(.secondary)
                        Text(self.state.formattedTotalBytes)
                            .foregroundColor(.secondary)
                    }
                    .font(.caption)

                    Spacer()

                    // Speed and ETA
                    HStack(spacing: 8) {
                        Text(self.state.formattedDownloadSpeed)
                            .fontWeight(.medium)

                        if let timeRemaining = self.state.formattedTimeRemaining {
                            Text("•")
                                .foregroundColor(.secondary)
                            Text(timeRemaining)
                                .foregroundColor(.secondary)
                        }
                    }
                    .font(.caption)

                    Text("\(Int(self.state.downloadProgress * 100))%")
                        .font(.caption)
                        .fontWeight(.medium)
                        .monospacedDigit()
                        .frame(width: 40, alignment: .trailing)
                }
            }

            // Per-model progress card
            VStack(spacing: 0) {
                ModelProgressRow(
                    name: "Parakeet ASR",
                    totalSize: "~600 MB",
                    downloadState: self.state.modelDownloadStates[.parakeetTDT] ?? .pending
                )

                Divider()

                ModelProgressRow(
                    name: self.state.primaryLLM.displayName,
                    totalSize: self.llmSizeDisplay,
                    downloadState: self.state.modelDownloadStates[self.state.primaryLLM] ?? .pending
                )

                Divider()

                ModelProgressRow(
                    name: "Kokoro TTS",
                    totalSize: "~500 MB",
                    downloadState: self.state.modelDownloadStates[.kokoro] ?? .pending
                )
            }
            .padding()
            .background(Color(nsColor: .controlBackgroundColor))
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 12))

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

            // Bottom buttons
            HStack {
                Button("Cancel") {
                    self.onCancel()
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
                .disabled(self.state.downloadProgress >= 1.0)

                Spacer()

                if self.state.downloadProgress >= 1.0 && self.state.downloadError == nil {
                    Button("Continue") {
                        // The coordinator will handle advancing to the next step
                        Task {
                            await SetupCoordinator.shared.nextStep()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
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

// MARK: - Model Progress Row

private struct ModelProgressRow: View {
    let name: String
    let totalSize: String
    let downloadState: ModelDownloadState

    var body: some View {
        HStack(spacing: 12) {
            // Status icon
            self.statusIcon
                .frame(width: 24, height: 24)

            // Model info
            VStack(alignment: .leading, spacing: 2) {
                Text(self.name)
                    .fontWeight(.medium)

                // Progress text
                Text(self.progressText)
                    .font(.caption)
                    .foregroundColor(.secondary)

                // Mini progress bar for downloading state
                if case .downloading(let progress, _, _) = self.downloadState {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Color.secondary.opacity(0.2))
                                .frame(height: 3)

                            RoundedRectangle(cornerRadius: 2)
                                .fill(Color.accentColor)
                                .frame(width: geo.size.width * progress, height: 3)
                        }
                    }
                    .frame(height: 3)
                }
            }

            Spacer()

            // Size
            Text(self.totalSize)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch self.downloadState {
        case .pending:
            Image(systemName: "circle")
                .foregroundColor(.secondary)

        case .downloading:
            ProgressView()
                .scaleEffect(0.6)

        case .verifying:
            ProgressView()
                .scaleEffect(0.6)

        case .complete:
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(.green)

        case .error:
            Image(systemName: "xmark.circle.fill")
                .foregroundColor(.red)
        }
    }

    private var progressText: String {
        switch self.downloadState {
        case .pending:
            return "Waiting..."
        case .downloading(let progress, let bytes, let total):
            let bytesStr = SetupState.formatBytes(bytes)
            let totalStr = SetupState.formatBytes(total)
            return "\(bytesStr) of \(totalStr) (\(Int(progress * 100))%)"
        case .verifying:
            return "Verifying..."
        case .complete:
            return "Complete"
        case .error(let message):
            return "Error: \(message)"
        }
    }
}

// MARK: - Preview

#Preview {
    var state = SetupState()
    state.downloadProgress = 0.47
    state.totalBytesDownloaded = 1_700_000_000
    state.totalBytesToDownload = 3_600_000_000
    state.downloadSpeedBytesPerSecond = 12_900_000
    state.estimatedTimeRemainingSeconds = 120
    state.modelDownloadStates = [
        .parakeetTDT: .complete,
        .qwen3_4B: .downloading(progress: 0.45, bytesDownloaded: 1_100_000_000, totalBytes: 2_500_000_000),
        .kokoro: .pending
    ]

    return DownloadStepView(
        state: state,
        onRetry: {},
        onCancel: {}
    )
    .frame(width: 500, height: 450)
    .padding()
}
