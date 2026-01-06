//
//  DownloadStepView.swift
//  Ora
//
//  Model download step with enhanced progress UI
//

import SwiftUI

// MARK: - Display State (Local UI Mapping)

/// Local display state enum that maps ModelStatus to UI states
private enum ModelDisplayState: Equatable {
    case pending
    case downloading(progress: Double, bytesDownloaded: Int64, totalBytes: Int64)
    case verifying
    case complete
    case error(String)

    var progress: Double {
        switch self {
        case .pending: return 0
        case .downloading(let progress, _, _): return progress
        case .verifying, .complete: return 1.0
        case .error: return 0
        }
    }
}

// MARK: - Download Step View

struct DownloadStepView: View {
    let setupState: SetupState
    let modelsState: ModelsState

    var body: some View {
        VStack(spacing: 20) {
            Text("Downloading Models")
                .font(.largeTitle)
                .fontWeight(.bold)

            Text("This may take a few minutes depending on your connection")
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            GlassEffectContainer(spacing: 16) {
                VStack(spacing: 16) {
                    self.overallProgressCard
                    self.modelProgressCard
                    if let error = self.setupState.downloadError {
                        self.errorCard(for: error)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
    }

    // MARK: - Helpers

    /// Map ModelStatus to display state for UI
    private func displayState(for model: ModelIdentifier) -> ModelDisplayState {
        let status = modelsState.statuses[model] ?? .notDownloaded
        let progress = modelsState.downloadProgress[model]

        switch status {
        case .notDownloaded:
            return .pending
        case .downloading(let progressValue):
            return .downloading(
                progress: progressValue,
                bytesDownloaded: progress?.bytesDownloaded ?? 0,
                totalBytes: progress?.totalBytes ?? model.estimatedSizeBytes
            )
        case .verifying:
            return .verifying
        case .ready:
            return .complete
        case .failed(let error):
            return .error(error)
        case .corrupted:
            return .error("Model files corrupted")
        }
    }

    private var llmSizeDisplay: String {
        switch self.modelsState.primaryLLM {
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

    private var overallProgressCard: some View {
        VStack(spacing: 12) {
            ProgressView(value: self.modelsState.overallProgress)
                .progressViewStyle(.linear)

            HStack {
                HStack(spacing: 4) {
                    Text(self.modelsState.formattedBytesDownloaded)
                        .fontWeight(.medium)
                    Text("of")
                        .foregroundColor(.secondary)
                    Text(self.modelsState.formattedTotalBytes)
                        .foregroundColor(.secondary)
                }
                .font(.caption)

                Spacer()

                HStack(spacing: 8) {
                    Text(self.modelsState.formattedDownloadSpeed)
                        .fontWeight(.medium)

                    if let timeRemaining = self.modelsState.formattedTimeRemaining {
                        Text("•")
                            .foregroundColor(.secondary)
                        Text(timeRemaining)
                            .foregroundColor(.secondary)
                    }
                }
                .font(.caption)

                Text("\(Int(self.modelsState.overallProgress * 100))%")
                    .font(.caption)
                    .fontWeight(.medium)
                    .monospacedDigit()
                    .frame(width: 40, alignment: .trailing)
            }
        }
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.6))
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var modelProgressCard: some View {
        VStack(spacing: 0) {
            ModelProgressRow(
                name: "Parakeet ASR",
                totalSize: "~600 MB",
                displayState: self.displayState(for: .parakeetTDT)
            )

            Divider()

            ModelProgressRow(
                name: self.modelsState.primaryLLM.displayName,
                totalSize: self.llmSizeDisplay,
                displayState: self.displayState(for: self.modelsState.primaryLLM)
            )

            Divider()

            ModelProgressRow(
                name: "Kokoro TTS",
                totalSize: "~500 MB",
                displayState: self.displayState(for: .kokoro)
            )
        }
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.6))
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    @ViewBuilder
    private func errorCard(for error: String) -> some View {
        Label(error, systemImage: "exclamationmark.triangle")
            .foregroundColor(.red)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Color.red.opacity(0.08))
            .glassEffect(.regular.tint(Color.red.opacity(0.2)), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

// MARK: - Model Progress Row

private struct ModelProgressRow: View {
    let name: String
    let totalSize: String
    let displayState: ModelDisplayState

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
                if case .downloading(let progress, _, _) = self.displayState {
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
        switch self.displayState {
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
        switch self.displayState {
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
    var modelsState = ModelsState()
    modelsState.statuses = [
        .parakeetTDT: .ready,
        .qwen3_4B: .downloading(progress: 0.45),
        .kokoro: .notDownloaded
    ]
    modelsState.downloadProgress = [
        .parakeetTDT: ModelDownloadProgress(
            identifier: .parakeetTDT,
            bytesDownloaded: 600_000_000,
            totalBytes: 600_000_000
        ),
        .qwen3_4B: ModelDownloadProgress(
            identifier: .qwen3_4B,
            bytesDownloaded: 1_100_000_000,
            totalBytes: 2_500_000_000
        ),
        .kokoro: ModelDownloadProgress(
            identifier: .kokoro,
            bytesDownloaded: 0,
            totalBytes: 500_000_000
        )
    ]
    modelsState.overallDownloadSpeed = 12_900_000
    modelsState.estimatedTimeRemainingSeconds = 120
    modelsState.isDownloading = true

    var setupState = SetupState()
    setupState.currentStep = .download
    setupState.downloadProgress = 0.47

    return DownloadStepView(
        setupState: setupState,
        modelsState: modelsState
    )
    .frame(width: 500, height: 450)
    .padding()
}
