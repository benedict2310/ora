//
//  SetupWindow.swift
//  Ora
//
//  Main setup window container
//

import SwiftUI

struct SetupWindow: View {
    @ObservedObject var coordinator: SetupCoordinator

    var body: some View {
        VStack(spacing: 0) {
            // Progress indicator
            SetupProgressView(currentStep: self.coordinator.state.currentStep)
                .padding(.top, 20)
                .padding(.horizontal, 40)

            Divider()
                .padding(.top, 20)

            // Content area
            Group {
                switch self.coordinator.state.currentStep {
                case .welcome:
                    WelcomeStepView(state: self.coordinator.state)
                case .permissions:
                    PermissionsStepView(coordinator: self.coordinator)
                case .modelExplanation:
                    ModelExplanationStepView(
                        state: self.coordinator.state,
                        onDownloadNow: {
                            Task { await self.coordinator.startDownloadFromExplanation() }
                        },
                        onMaybeLater: {
                            self.coordinator.postponeSetup()
                        }
                    )
                case .download:
                    DownloadStepView(
                        state: self.coordinator.state,
                        onRetry: {
                            Task { await self.coordinator.retryDownload() }
                        },
                        onCancel: {
                            self.coordinator.cancelDownloads()
                        }
                    )
                case .ready:
                    ReadyStepView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(40)

            Divider()

            // Navigation buttons
            SetupNavigationView(coordinator: self.coordinator)
                .padding(20)
        }
        .frame(width: 600, height: 500)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

// MARK: - Progress Indicator

struct SetupProgressView: View {
    let currentStep: SetupStep

    var body: some View {
        HStack(spacing: 4) {
            ForEach(SetupStep.allCases, id: \.rawValue) { step in
                HStack(spacing: 4) {
                    // Step indicator
                    ZStack {
                        Circle()
                            .fill(self.stepColor(for: step))
                            .frame(width: 8, height: 8)

                        if step.rawValue < self.currentStep.rawValue {
                            // Completed step - show checkmark
                            Image(systemName: "checkmark")
                                .font(.system(size: 5, weight: .bold))
                                .foregroundColor(.white)
                        }
                    }

                    Text(step.title)
                        .font(.caption2)
                        .foregroundColor(step.rawValue <= self.currentStep.rawValue ? .primary : .secondary)

                    if step != SetupStep.allCases.last {
                        Rectangle()
                            .fill(step.rawValue < self.currentStep.rawValue ? Color.accentColor : Color.secondary.opacity(0.3))
                            .frame(height: 1.5)
                            .frame(maxWidth: 20)
                    }
                }
            }
        }
    }

    private func stepColor(for step: SetupStep) -> Color {
        if step.rawValue < self.currentStep.rawValue {
            return .green // Completed
        } else if step.rawValue == self.currentStep.rawValue {
            return .accentColor // Current
        } else {
            return Color.secondary.opacity(0.3) // Future
        }
    }
}

// MARK: - Navigation

struct SetupNavigationView: View {
    @ObservedObject var coordinator: SetupCoordinator

    var body: some View {
        // ModelExplanation and Download steps have their own navigation
        if self.coordinator.state.currentStep == .modelExplanation ||
           self.coordinator.state.currentStep == .download {
            // These steps handle their own buttons
            EmptyView()
        } else {
            HStack {
                // Back button
                if self.coordinator.state.currentStep.canGoBack {
                    Button("Back") {
                        self.coordinator.previousStep()
                    }
                    .keyboardShortcut(.escape, modifiers: [])
                }

                Spacer()

                // Postpone (only on welcome/permissions)
                if self.coordinator.state.currentStep == .welcome || self.coordinator.state.currentStep == .permissions {
                    Button("Later") {
                        self.coordinator.postponeSetup()
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.secondary)
                }

                // Next/Done button
                Button(self.nextButtonTitle) {
                    Task {
                        await self.coordinator.nextStep()
                    }
                }
                .keyboardShortcut(.return, modifiers: [])
                .buttonStyle(.borderedProminent)
                .disabled(!self.canProceed)
            }
        }
    }

    private var nextButtonTitle: String {
        Self.nextButtonTitle(for: self.coordinator.state.currentStep)
    }

    private var canProceed: Bool {
        Self.canProceed(for: self.coordinator.state)
    }

    static func nextButtonTitle(for step: SetupStep) -> String {
        switch step {
        case .welcome: return "Get Started"
        case .permissions: return "Continue"
        case .modelExplanation: return "Download Now"
        case .download: return "Continue"
        case .ready: return "Done"
        }
    }

    static func canProceed(for state: SetupState) -> Bool {
        switch state.currentStep {
        case .welcome:
            return true
        case .permissions:
            return state.permissionsGranted
        case .modelExplanation:
            return true
        case .download:
            return state.downloadProgress >= 1.0 && state.downloadError == nil
        case .ready:
            return true
        }
    }
}
