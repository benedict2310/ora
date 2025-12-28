//
//  OverlayView.swift
//  Ora
//
//  Main overlay content view
//

import SwiftUI

// MARK: - Main Overlay View

struct OverlayView: View {
    @EnvironmentObject var viewModel: OverlayViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            // Status indicator
            StatusIndicatorView(mode: self.viewModel.mode, reduceMotion: self.reduceMotion)
                .padding(.top, 16)
                .padding(.bottom, 12)

            Divider()

            // Messages
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(self.viewModel.messages) { message in
                            MessageBubbleView(message: message)
                                .id(message.id)
                        }
                    }
                    .padding()
                }
                .onChange(of: self.viewModel.messages.count) { _, _ in
                    // Scroll to bottom
                    if let lastMessage = self.viewModel.messages.last {
                        withAnimation {
                            proxy.scrollTo(lastMessage.id, anchor: .bottom)
                        }
                    }
                }
            }

            // Tool proposal (if any)
            if case .proposing(let proposal) = self.viewModel.mode {
                Divider()
                ToolProposalView(proposal: proposal)
            }
        }
        .frame(width: 400, height: 300)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(.ultraThinMaterial)
                .shadow(radius: 10)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
        )
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Ora Assistant")
    }
}

// MARK: - Status Indicator

struct StatusIndicatorView: View {
    let mode: OverlayMode
    let reduceMotion: Bool

    @State private var isPulsing = false

    var body: some View {
        HStack(spacing: 8) {
            // Animated indicator
            Circle()
                .fill(self.indicatorColor)
                .frame(width: 8, height: 8)
                .scaleEffect(self.isPulsing && !self.reduceMotion ? 1.2 : 1.0)
                .animation(
                    self.shouldPulse && !self.reduceMotion
                        ? .easeInOut(duration: 0.5).repeatForever(autoreverses: true)
                        : .default,
                    value: self.isPulsing
                )

            Text(self.statusText)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(self.accessibilityStatusText)
        .accessibilityAddTraits(.updatesFrequently)
        .onChange(of: self.mode) { _, _ in
            self.updatePulseState()
        }
        .onAppear {
            self.updatePulseState()
        }
    }

    private func updatePulseState() {
        self.isPulsing = self.shouldPulse
    }

    private var indicatorColor: Color {
        switch self.mode {
        case .listening: return .blue
        case .thinking: return .orange
        case .responding, .executing: return .green
        case .proposing: return .yellow
        case .error: return .red
        default: return .secondary
        }
    }

    private var shouldPulse: Bool {
        switch self.mode {
        case .listening, .thinking, .executing: return true
        default: return false
        }
    }

    private var statusText: String {
        switch self.mode {
        case .hidden: return ""
        case .listening: return "Listening..."
        case .thinking: return "Thinking..."
        case .responding: return "Responding..."
        case .proposing: return "Confirm action"
        case .executing: return "Executing..."
        case .completed: return "Done"
        case .error(let message): return "Error: \(message)"
        }
    }

    private var accessibilityStatusText: String {
        switch self.mode {
        case .hidden: return "Hidden"
        case .listening: return "Listening for your voice"
        case .thinking: return "Processing your request"
        case .responding: return "Responding"
        case .proposing: return "Action requires confirmation"
        case .executing: return "Executing action"
        case .completed: return "Completed"
        case .error(let message): return "Error: \(message)"
        }
    }
}

// MARK: - Message Bubble

struct MessageBubbleView: View {
    let message: OverlayMessage

    var body: some View {
        HStack {
            if self.message.role == .assistant {
                Spacer(minLength: 40)
            }

            VStack(alignment: self.message.role == .user ? .leading : .trailing, spacing: 4) {
                Text(self.message.content)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(self.bubbleColor)
                    .foregroundColor(self.textColor)
                    .cornerRadius(16)
                    .opacity(self.message.isPartial ? 0.8 : 1.0)

                if self.message.isPartial {
                    Text("Listening...")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(self.accessibilityLabel)
            .accessibilityHint(self.message.isPartial ? "Partial transcription, still listening" : "")

            if self.message.role == .user {
                Spacer(minLength: 40)
            }
        }
    }

    private var bubbleColor: Color {
        self.message.role == .user ? Color.accentColor : Color(nsColor: .controlBackgroundColor)
    }

    private var textColor: Color {
        self.message.role == .user ? .white : .primary
    }

    private var accessibilityLabel: String {
        let roleLabel = self.message.role == .user ? "You said" : "Ora said"
        return "\(roleLabel): \(self.message.content)"
    }
}

// MARK: - Tool Proposal

struct ToolProposalView: View {
    let proposal: ToolProposal

    @FocusState private var confirmButtonFocused: Bool
    @FocusState private var cancelButtonFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.yellow)
                    .accessibilityHidden(true)
                Text("Confirm Action")
                    .font(.headline)
            }

            Text(self.proposal.summary)
                .font(.body)

            if let details = self.proposal.details {
                Text(details)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            HStack {
                Button("Cancel") {
                    NotificationCenter.default.post(name: .proposalDenied, object: nil)
                }
                .keyboardShortcut(.escape, modifiers: [])
                .focused(self.$cancelButtonFocused)
                .accessibilityLabel("Cancel action")
                .accessibilityHint("Cancels the proposed action")

                Spacer()

                Button("Confirm") {
                    NotificationCenter.default.post(name: .proposalConfirmed, object: nil)
                }
                .keyboardShortcut(.return, modifiers: [])
                .buttonStyle(.borderedProminent)
                .focused(self.$confirmButtonFocused)
                .accessibilityLabel("Confirm action")
                .accessibilityHint("Confirms and executes the proposed action")
            }
        }
        .padding()
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(8)
        .padding()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Action confirmation for \(self.proposal.toolName)")
        .onAppear {
            // Focus confirm button by default for keyboard navigation
            self.confirmButtonFocused = true
        }
    }
}

// MARK: - Preview

#Preview {
    let viewModel = OverlayViewModel()
    viewModel.mode = .listening
    viewModel.messages = [
        OverlayMessage(role: .user, content: "Schedule a meeting tomorrow", isPartial: false),
        OverlayMessage(role: .assistant, content: "I'll create a meeting for tomorrow. What time works best?", isPartial: false)
    ]

    return OverlayView()
        .environmentObject(viewModel)
}
