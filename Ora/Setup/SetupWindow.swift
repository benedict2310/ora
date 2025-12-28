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
                case .download:
                    DownloadStepView(state: self.coordinator.state, onRetry: {
                        Task { await self.coordinator.retryDownload() }
                    })
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
        HStack(spacing: 8) {
            ForEach(SetupStep.allCases, id: \.rawValue) { step in
                HStack(spacing: 8) {
                    Circle()
                        .fill(step.rawValue <= self.currentStep.rawValue ? Color.accentColor : Color.secondary.opacity(0.3))
                        .frame(width: 10, height: 10)

                    Text(step.title)
                        .font(.caption)
                        .foregroundColor(step.rawValue <= self.currentStep.rawValue ? .primary : .secondary)

                    if step != SetupStep.allCases.last {
                        Rectangle()
                            .fill(step.rawValue < self.currentStep.rawValue ? Color.accentColor : Color.secondary.opacity(0.3))
                            .frame(height: 2)
                            .frame(maxWidth: 40)
                    }
                }
            }
        }
    }
}

// MARK: - Navigation

struct SetupNavigationView: View {
    @ObservedObject var coordinator: SetupCoordinator

    var body: some View {
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

    private var nextButtonTitle: String {
        switch self.coordinator.state.currentStep {
        case .welcome: return "Get Started"
        case .permissions: return "Continue"
        case .download: return "Continue"
        case .ready: return "Done"
        }
    }

    private var canProceed: Bool {
        switch self.coordinator.state.currentStep {
        case .welcome:
            return true
        case .permissions:
            return self.coordinator.state.permissionsGranted
        case .download:
            return self.coordinator.state.downloadProgress >= 1.0 && self.coordinator.state.downloadError == nil
        case .ready:
            return true
        }
    }
}
