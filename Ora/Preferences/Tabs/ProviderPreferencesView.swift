//
//  ProviderPreferencesView.swift
//  Ora
//
//  Cloud provider configuration tab
//

import SwiftUI

struct ProviderPreferencesView: View {

    // MARK: - State

    @StateObject private var viewModel = ProviderPreferencesViewModel()

    // MARK: - Body

    var body: some View {
        Form {
            Section {
                Picker("", selection: self.providerSelection) {
                    ForEach(LLMProviderType.allCases, id: \.self) { type in
                        Text(type.displayName)
                            .tag(type)
                    }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
            } header: {
                Text("Active Provider")
            }

            Section {
                HStack(spacing: 8) {
                    SecureField("sk-ant-...", text: self.$viewModel.anthropicKeyInput)
                        .textFieldStyle(.roundedBorder)

                    Button("Save") {
                        Task {
                            await self.viewModel.saveAnthropicKey()
                        }
                    }
                    .disabled(self.viewModel.anthropicKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    Button("Delete", role: .destructive) {
                        Task {
                            await self.viewModel.deleteAnthropicKey()
                        }
                    }
                    .disabled(self.viewModel.anthropicKeyStatus == .noKey || self.viewModel.anthropicKeyStatus == .checking)
                }

                Picker("Model", selection: self.anthropicModelSelection) {
                    ForEach(AnthropicModel.allCases, id: \.self) { model in
                        Text(model.displayName)
                            .tag(model)
                    }
                }

                KeyStatusRow(status: self.viewModel.anthropicKeyStatus)
            } header: {
                Text("Anthropic")
            }

            Section {
                HStack(spacing: 8) {
                    SecureField("sk-...", text: self.$viewModel.openAIKeyInput)
                        .textFieldStyle(.roundedBorder)

                    Button("Save") {
                        Task {
                            await self.viewModel.saveOpenAIKey()
                        }
                    }
                    .disabled(self.viewModel.openAIKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    Button("Delete", role: .destructive) {
                        Task {
                            await self.viewModel.deleteOpenAIKey()
                        }
                    }
                    .disabled(self.viewModel.openAIKeyStatus == .noKey || self.viewModel.openAIKeyStatus == .checking)
                }

                Picker("Model", selection: self.openAIModelSelection) {
                    ForEach(OpenAIModel.allCases, id: \.self) { model in
                        Text(model.displayName)
                            .tag(model)
                    }
                }

                KeyStatusRow(status: self.viewModel.openAIKeyStatus)

                Divider()

                Text("Have ChatGPT Pro?")
                    .font(.subheadline)

                HStack(spacing: 8) {
                    Button("Authorize Codex") {
                        Task {
                            await self.viewModel.authorizeCodex()
                        }
                    }
                    .disabled(self.viewModel.codexAuthStatus == .connecting)

                    if self.viewModel.codexAuthStatus.isConnected {
                        Button("Disconnect", role: .destructive) {
                            Task {
                                await self.viewModel.disconnectCodex()
                            }
                        }
                    }
                }

                CodexAuthStatusRow(status: self.viewModel.codexAuthStatus)

                Text(self.viewModel.openAICredentialSummary)
                    .font(.caption)
                    .foregroundColor(.secondary)
            } header: {
                Text("OpenAI")
            }

            Section {
                Label("Cloud providers send your prompts to external servers. Local mode keeps everything on-device.", systemImage: "info.circle")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
        .task {
            await self.viewModel.loadState()
        }
    }

    // MARK: - Bindings

    private var providerSelection: Binding<LLMProviderType> {
        Binding(
            get: {
                self.viewModel.selectedProvider
            },
            set: { newValue in
                Task {
                    await self.viewModel.switchProvider(newValue)
                }
            }
        )
    }

    private var anthropicModelSelection: Binding<AnthropicModel> {
        Binding(
            get: {
                self.viewModel.anthropicModel
            },
            set: { newValue in
                Task {
                    await self.viewModel.updateAnthropicModel(newValue)
                }
            }
        )
    }

    private var openAIModelSelection: Binding<OpenAIModel> {
        Binding(
            get: {
                self.viewModel.openAIModel
            },
            set: { newValue in
                Task {
                    await self.viewModel.updateOpenAIModel(newValue)
                }
            }
        )
    }
}

private struct CodexAuthStatusRow: View {
    let status: ProviderPreferencesViewModel.CodexAuthStatus

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: self.iconName)
                .foregroundColor(self.tintColor)
            Text(self.message)
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private var iconName: String {
        switch self.status {
        case .disconnected:
            return "minus.circle"
        case .connecting:
            return "clock"
        case .connected:
            return "checkmark.circle.fill"
        case .error:
            return "exclamationmark.triangle.fill"
        }
    }

    private var tintColor: Color {
        switch self.status {
        case .disconnected:
            return .secondary
        case .connecting:
            return .orange
        case .connected:
            return .green
        case .error:
            return .red
        }
    }

    private var message: String {
        switch self.status {
        case .disconnected:
            return "Not connected"
        case .connecting:
            return "Waiting for authorization"
        case .connected(let account):
            return "Signed in (\(account))"
        case .error(let message):
            return message
        }
    }
}

// MARK: - Status Row

private struct KeyStatusRow: View {
    let status: ProviderPreferencesViewModel.KeyStatus

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: self.iconName)
                .foregroundColor(self.tintColor)
            Text(self.message)
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private var iconName: String {
        switch self.status {
        case .saved:
            return "checkmark.circle.fill"
        case .noKey:
            return "minus.circle"
        case .checking:
            return "clock"
        case .error:
            return "exclamationmark.triangle.fill"
        }
    }

    private var tintColor: Color {
        switch self.status {
        case .saved:
            return .green
        case .noKey:
            return .secondary
        case .checking:
            return .orange
        case .error:
            return .red
        }
    }

    private var message: String {
        switch self.status {
        case .saved:
            return "Key saved"
        case .noKey:
            return "No key configured"
        case .checking:
            return "Checking key status"
        case .error(let message):
            return message
        }
    }
}
