//
//  SetupWindow.swift
//  Ora
//
//  Main setup window container
//

import SwiftUI

struct SetupWindow: View {
    @ObservedObject var coordinator: SetupCoordinator
    private let windowSize = CGSize(width: 640, height: 640)
    private let contentMaxWidth: CGFloat = 520
    private let contentPadding: CGFloat = 24

    var body: some View {
        VStack(spacing: 0) {
            // Progress indicator
            self.header

            Divider()

            // Content area
            ScrollView {
                self.stepContent
                    .frame(maxWidth: self.contentMaxWidth, alignment: .top)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, self.contentPadding)
                    .padding(.vertical, 24)
                    .padding(.bottom, 12)
            }
            .scrollIndicators(.automatic)

            Divider()

            // Navigation buttons
            SetupNavigationView(coordinator: self.coordinator)
        }
        .frame(width: self.windowSize.width, height: self.windowSize.height)
        .background(self.windowBackground)
    }

    @ViewBuilder
    private var stepContent: some View {
        switch self.coordinator.state.currentStep {
        case .welcome:
            WelcomeStepView(state: self.coordinator.state)
        case .permissions:
            PermissionsStepView(coordinator: self.coordinator)
        case .modelExplanation:
            ModelExplanationStepView(
                state: self.coordinator.state
            )
        case .download:
            DownloadStepView(
                setupState: self.coordinator.state,
                modelsState: self.coordinator.modelsState
            )
        case .ready:
            ReadyStepView()
        }
    }

    private var header: some View {
        SetupProgressView(currentStep: self.coordinator.state.currentStep)
            .padding(.vertical, 10)
            .padding(.horizontal, 16)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.6))
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .frame(maxWidth: self.contentMaxWidth)
            .padding(.top, 16)
            .padding(.horizontal, 20)
            .padding(.bottom, 12)
    }

    private var windowBackground: some View {
        LinearGradient(
            colors: [
                Color(nsColor: .windowBackgroundColor),
                Color(nsColor: .controlBackgroundColor).opacity(0.5)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
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
        HStack {
            if self.showsCancelButton {
                Button("Cancel") {
                    self.coordinator.cancelDownloads()
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
                .keyboardShortcut(.escape, modifiers: [])
                .disabled(self.coordinator.modelsState.overallProgress >= 1.0)
            } else if self.coordinator.state.currentStep.canGoBack {
                Button("Back") {
                    self.coordinator.previousStep()
                }
                .keyboardShortcut(.escape, modifiers: [])
            }

            Spacer()

            if self.showsLaterButton {
                Button(self.laterButtonTitle) {
                    self.coordinator.postponeSetup()
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
            }

            Button(self.primaryButtonTitle) {
                self.handlePrimaryAction()
            }
            .keyboardShortcut(.return, modifiers: [])
            .buttonStyle(.borderedProminent)
            .disabled(!self.primaryButtonEnabled)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.6))
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var nextButtonTitle: String {
        Self.nextButtonTitle(for: self.coordinator.state.currentStep)
    }

    private var canProceed: Bool {
        Self.canProceed(for: self.coordinator.state)
    }

    private var showsCancelButton: Bool {
        self.coordinator.state.currentStep == .download
    }

    private var showsLaterButton: Bool {
        switch self.coordinator.state.currentStep {
        case .welcome, .permissions, .modelExplanation:
            return true
        case .download, .ready:
            return false
        }
    }

    private var laterButtonTitle: String {
        self.coordinator.state.currentStep == .modelExplanation ? "Maybe Later" : "Later"
    }

    private var primaryButtonTitle: String {
        if self.coordinator.state.currentStep == .download,
           self.coordinator.state.downloadError != nil {
            return "Retry Download"
        }
        return self.nextButtonTitle
    }

    private var primaryButtonEnabled: Bool {
        if self.coordinator.state.currentStep == .download,
           self.coordinator.state.downloadError != nil {
            return true
        }
        return self.canProceed
    }

    private func handlePrimaryAction() {
        switch self.coordinator.state.currentStep {
        case .modelExplanation:
            Task { await self.coordinator.startDownloadFromExplanation() }
        case .download:
            if self.coordinator.state.downloadError != nil {
                Task { await self.coordinator.retryDownload() }
            } else {
                Task { await self.coordinator.nextStep() }
            }
        default:
            Task { await self.coordinator.nextStep() }
        }
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
