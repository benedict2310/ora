//
//  ModelsPreferencesView.swift
//  Ora
//
//  Models management tab
//

import SwiftUI
import os

struct ModelsPreferencesView: View {

    // MARK: - State

    private let logger = Logger.ora(category: "ModelsPreferences")
    @State private var modelsState = ModelsState()
    @State private var showDeleteConfirmation = false
    @State private var modelToDelete: ModelIdentifier?
    @State private var downloadErrorMessage: String?
    @State private var totalRAMBytes: UInt64 = ProcessInfo.processInfo.physicalMemory
    @StateObject private var migrationCoordinator = ModelMigrationCoordinator.shared

    // MARK: - Body

    var body: some View {
        Form {
            // Models by category - only show active (non-legacy) models
            Section {
                ForEach(ModelIdentifier.activeModels.filter { $0.category == .asr }, id: \.self) { model in
                    ModelRowView(
                        model: model,
                        status: modelsState.statuses[model] ?? .notDownloaded,
                        isPrimary: false,
                        isPrimarySelectionSupported: true,
                        primarySelectionGuidance: nil,
                        onDownload: { await self.downloadModel(model) },
                        onDelete: { self.confirmDelete(model) },
                        onSetPrimary: { }
                    )
                }
            } header: {
                Text("Speech Recognition")
            }

            Section {
                ForEach(ModelIdentifier.activeModels(for: self.totalRAMBytes).filter { $0.category == .llm }, id: \.self) { model in
                    let isPrimarySelectionSupported = model.isSupported(on: self.totalRAMBytes)
                    let primarySelectionGuidance = self.primarySelectionGuidance(for: model, isPrimarySelectionSupported: isPrimarySelectionSupported)
                    ModelRowView(
                        model: model,
                        status: modelsState.statuses[model] ?? .notDownloaded,
                        isPrimary: model == modelsState.primaryLLM,
                        isPrimarySelectionSupported: isPrimarySelectionSupported,
                        primarySelectionGuidance: primarySelectionGuidance,
                        onDownload: { await self.downloadModel(model) },
                        onDelete: { self.confirmDelete(model) },
                        onSetPrimary: { await self.setPrimary(model) }
                    )
                }
            } header: {
                Text("Language Model")
            } footer: {
                Text(self.languageModelFooterText)
            }

            if self.shouldShowMigrationSection {
                Section {
                    self.migrationSectionContent
                } header: {
                    Text("Model Upgrade")
                }
            }

            Section {
                ForEach(ModelIdentifier.activeModels.filter { $0.category == .tts }, id: \.self) { model in
                    ModelRowView(
                        model: model,
                        status: modelsState.statuses[model] ?? .notDownloaded,
                        isPrimary: false,
                        isPrimarySelectionSupported: true,
                        primarySelectionGuidance: nil,
                        onDownload: { await self.downloadModel(model) },
                        onDelete: { self.confirmDelete(model) },
                        onSetPrimary: { }
                    )
                }
            } header: {
                Text("Text to Speech")
            }
            
            // Show legacy models section if any are present
            if !self.visibleLegacyModels.isEmpty {
                Section {
                    ForEach(self.visibleLegacyModels, id: \.self) { model in
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(model.displayName)
                                    .fontWeight(.medium)
                                    .foregroundColor(.secondary)
                                Text("No longer supported")
                                    .font(.caption)
                                    .foregroundColor(.orange)
                            }
                            
                            Spacer()
                            
                            Button(role: .destructive) {
                                self.confirmDelete(model)
                            } label: {
                                Text("Delete")
                            }
                            .controlSize(.small)
                        }
                    }
                } header: {
                    Text("Legacy Models")
                } footer: {
                    Text("These models can be deleted to free up disk space. Ora now uses Qwen3 Vision.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Section {
                HStack {
                    Image(systemName: "internaldrive")
                        .foregroundColor(.secondary)
                    Text("Models are stored in ~/Library/Application Support/Ora/Models/")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            if let downloadErrorMessage {
                Section {
                    Label(downloadErrorMessage, systemImage: "exclamationmark.triangle.fill")
                        .foregroundColor(.red)
                        .font(.caption)
                }
            }
        }
        .formStyle(.grouped)
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
            self.downloadErrorMessage = nil
        } catch {
            let message = "Failed to download \(model.displayName): \(error.localizedDescription)"
            self.downloadErrorMessage = message
            self.logger.warning("\(message)")
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

    private func primarySelectionGuidance(
        for model: ModelIdentifier,
        isPrimarySelectionSupported: Bool
    ) -> String? {
        guard model.category == .llm else { return nil }
        guard !isPrimarySelectionSupported else { return nil }
        guard let minimumRAMBytes = model.minimumSupportedRAMBytes else { return nil }

        let minimumRAMGB = Int(Double(minimumRAMBytes) / 1_000_000_000)
        return "Requires \(minimumRAMGB) GB RAM to set as Primary."
    }

    private var shouldShowMigrationSection: Bool {
        if self.migrationCoordinator.migrationCompleted && self.migrationCoordinator.status == .idle {
            return false
        }

        if self.modelsState.primaryLLM == .qwen3_4B {
            return true
        }

        if self.modelsState.statuses[.qwen3_4B]?.isReady == true {
            return true
        }

        switch self.migrationCoordinator.status {
        case .idle:
            return self.migrationCoordinator.manualRetryRequired
        case .migrating, .failed, .completed:
            return true
        }
    }

    @ViewBuilder
    private var migrationSectionContent: some View {
        switch self.migrationCoordinator.status {
        case .idle:
            VStack(alignment: .leading, spacing: 8) {
                Text("Qwen 3 4B has been retired. Upgrade to Qwen3 VL 4B to keep the local model current and image-capable.")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Button("Upgrade Now") {
                    Task {
                        await self.migrationCoordinator.retryFromPreferences()
                    }
                }
            }

        case .migrating(let progress):
            VStack(alignment: .leading, spacing: 8) {
                ProgressView(value: progress)
                Text("Upgrading the retired Qwen 3 4B install to Qwen3 VL 4B.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

        case .failed(let message):
            VStack(alignment: .leading, spacing: 8) {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                    .font(.caption)

                Button("Retry Upgrade") {
                    Task {
                        await self.migrationCoordinator.retryFromPreferences()
                    }
                }
            }

        case .completed:
            Label("Qwen3 VL 4B is now the default local model.", systemImage: "checkmark.circle.fill")
                .foregroundColor(.green)
                .font(.caption)
        }
    }

    private var languageModelFooterText: String {
        if self.totalRAMBytes < 24_000_000_000 {
            return "Qwen3 VL 4B needs 16 GB RAM, Qwen3 VL 8B needs 24 GB RAM, and Qwen3 VL 32B needs 48 GB RAM to be selected as Primary on this Mac."
        }

        if self.totalRAMBytes < 48_000_000_000 {
            return "Qwen3 VL 32B is visible here, but it needs 48 GB RAM to be selected as Primary on this Mac."
        }

        return "Choose the fastest model your Mac can comfortably run. Larger variants trade speed for higher quality."
    }

    private var visibleLegacyModels: [ModelIdentifier] {
        return ModelIdentifier.allCases.filter {
            $0.isLegacy(on: self.totalRAMBytes) && self.modelsState.statuses[$0]?.isReady == true
        }
    }
}

// MARK: - Model Row View

struct ModelRowView: View {

    let model: ModelIdentifier
    let status: ModelStatus
    let isPrimary: Bool
    let isPrimarySelectionSupported: Bool
    let primarySelectionGuidance: String?
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

                    if model.isAdvancedLocalModel {
                        Text("Advanced")
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.orange.opacity(0.18))
                            .foregroundColor(.orange)
                            .cornerRadius(4)
                    }
                }

                Text(self.formatBytes(model.estimatedSizeBytes))
                    .font(.caption)
                    .foregroundColor(.secondary)

                if let primarySelectionGuidance {
                    Text(primarySelectionGuidance)
                        .font(.caption2)
                        .foregroundColor(.orange)
                }
            }

            Spacer()

            // Status and actions
            self.statusView
        }
    }

    @ViewBuilder
    private var statusView: some View {
        switch status {
        case .ready:
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)

                if model.category == .llm && !isPrimary {
                    if isPrimarySelectionSupported {
                        Button("Set Primary") {
                            Task { await onSetPrimary() }
                        }
                        .controlSize(.small)
                    } else {
                        Text("Unavailable")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                if !model.isRequired || model.category == .llm {
                    Button(role: .destructive) {
                        onDelete()
                    } label: {
                        Image(systemName: "trash")
                    }
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
