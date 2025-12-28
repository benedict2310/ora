//
//  ModelsPreferencesView.swift
//  Ora
//
//  Models management tab
//

import SwiftUI

struct ModelsPreferencesView: View {

    // MARK: - State

    @State private var modelsState = ModelsState()
    @State private var showDeleteConfirmation = false
    @State private var modelToDelete: ModelIdentifier?

    // MARK: - Body

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Header
                Text("AI Models")
                    .font(.headline)

                Text("Ora uses three AI models for speech recognition, language understanding, and voice synthesis.")
                    .font(.caption)
                    .foregroundColor(.secondary)

                // Models List
                VStack(spacing: 12) {
                    ForEach(ModelIdentifier.allCases, id: \.self) { model in
                        ModelRowView(
                            model: model,
                            status: modelsState.statuses[model] ?? .notDownloaded,
                            isPrimary: model == modelsState.primaryLLM && model.category == .llm,
                            onDownload: { await self.downloadModel(model) },
                            onDelete: { self.confirmDelete(model) },
                            onSetPrimary: { await self.setPrimary(model) }
                        )
                    }
                }

                // Storage info
                HStack {
                    Image(systemName: "internaldrive")
                        .foregroundColor(.secondary)
                    Text("Models are stored in ~/Library/Application Support/Ora/Models/")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear {
            self.refreshModels()
        }
        .onReceive(NotificationCenter.default.publisher(for: .modelStateDidChange)) { _ in
            self.refreshModels()
        }
        .alert("Delete Model", isPresented: $showDeleteConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                if let model = modelToDelete {
                    Task { await self.deleteModel(model) }
                }
            }
        } message: {
            if let model = modelToDelete {
                Text("Are you sure you want to delete \(model.displayName)? You'll need to download it again to use Ora.")
            }
        }
    }

    // MARK: - Private Methods

    private func refreshModels() {
        Task {
            await ModelManager.shared.refreshStatuses()
            modelsState = await ModelManager.shared.state
        }
    }

    private func downloadModel(_ model: ModelIdentifier) async {
        do {
            try await ModelManager.shared.downloadModel(model)
        } catch {
            // Error handling - model state will reflect failure
        }
    }

    private func confirmDelete(_ model: ModelIdentifier) {
        modelToDelete = model
        showDeleteConfirmation = true
    }

    private func deleteModel(_ model: ModelIdentifier) async {
        try? await ModelManager.shared.deleteModel(model)
    }

    private func setPrimary(_ model: ModelIdentifier) async {
        await ModelManager.shared.setPrimaryLLM(model)
    }
}

// MARK: - Model Row View

struct ModelRowView: View {

    let model: ModelIdentifier
    let status: ModelStatus
    let isPrimary: Bool
    let onDownload: () async -> Void
    let onDelete: () -> Void
    let onSetPrimary: () async -> Void

    var body: some View {
        HStack {
            // Model info
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(model.displayName)
                        .fontWeight(.medium)

                    if isPrimary {
                        Text("Primary")
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.2))
                            .foregroundColor(.accentColor)
                            .cornerRadius(4)
                    }
                }

                Text(model.category.rawValue.uppercased())
                    .font(.caption2)
                    .foregroundColor(.secondary)

                Text(self.formatBytes(model.estimatedSizeBytes))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            // Status and actions
            self.statusView
        }
        .padding()
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(8)
    }

    @ViewBuilder
    private var statusView: some View {
        switch status {
        case .ready:
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)

                if model.category == .llm && !isPrimary {
                    Button("Set Primary") {
                        Task { await onSetPrimary() }
                    }
                    .buttonStyle(.glass)
                    .controlSize(.small)
                }

                if !model.isRequired || model.category == .llm {
                    Button(role: .destructive) {
                        onDelete()
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.glass)
                    .controlSize(.small)
                }
            }

        case .downloading(let progress):
            HStack(spacing: 8) {
                ProgressView(value: progress)
                    .frame(width: 100)
                Text("\(Int(progress * 100))%")
                    .font(.caption)
                    .monospacedDigit()
            }

        case .notDownloaded:
            Button("Download") {
                Task { await onDownload() }
            }
            .buttonStyle(.glassProminent)
            .controlSize(.small)

        case .verifying:
            HStack(spacing: 8) {
                ProgressView()
                    .scaleEffect(0.7)
                Text("Verifying...")
                    .font(.caption)
            }

        case .failed(let error):
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundColor(.red)
                Button("Retry") {
                    Task { await onDownload() }
                }
                .buttonStyle(.glassProminent)
                .controlSize(.small)
            }
            .help(error)

        case .corrupted:
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundColor(.orange)
                Text("Corrupted")
                    .font(.caption)
                Button("Re-download") {
                    Task { await onDownload() }
                }
                .buttonStyle(.glassProminent)
                .controlSize(.small)
            }
        }
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}
