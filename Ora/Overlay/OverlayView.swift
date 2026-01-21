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
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @Namespace private var inputGlassNamespace

    private let scrollAnchorID = "overlayScrollAnchor"

    var body: some View {
        GlassEffectContainer(spacing: OverlayLayout.containerSpacing) {
            VStack(alignment: .leading, spacing: OverlayLayout.containerSpacing) {
                VoiceInputControlView(
                    state: self.voiceInputState,
                    reduceMotion: self.reduceMotion,
                    reduceTransparency: self.reduceTransparency,
                    namespace: self.inputGlassNamespace
                )
                .accessibilityElement(children: .combine)
                .accessibilityLabel(self.voiceInputAccessibilityLabel)

                self.chatScrollView
            }
            .frame(maxWidth: OverlayLayout.contentMaxWidth, maxHeight: .infinity, alignment: .top)
        }
        .padding(16)
        .frame(width: OverlayLayout.panelWidth, height: OverlayLayout.panelHeight)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Ora Assistant")
    }

    private var chatScrollView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: OverlayLayout.rowSpacing) {
                    ForEach(self.visibleMessages) { message in
                        ChatBubbleView(
                            text: message.content,
                            role: message.role == .user ? .user : .assistant,
                            state: nil,
                            isPartial: message.isPartial,
                            reduceTransparency: self.reduceTransparency,
                            reduceMotion: self.reduceMotion
                        )
                        .id(message.id)
                    }

                    if self.shouldShowThinkingBubble {
                        ChatBubbleView(
                            text: nil,
                            role: .assistant,
                            state: .thinking(self.thinkingBubbleLabel),
                            isPartial: false,
                            reduceTransparency: self.reduceTransparency,
                            reduceMotion: self.reduceMotion
                        )
                    }

                    if self.shouldShowToolBubble {
                        ChatBubbleView(
                            text: nil,
                            role: .tool,
                            state: .tool(self.viewModel.activity.displayLabel),
                            isPartial: false,
                            reduceTransparency: self.reduceTransparency,
                            reduceMotion: self.reduceMotion
                        )
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }

                    if self.shouldShowExecutingBubble {
                        ToolStateView(
                            mode: .executing(label: "Executing action"),
                            reduceTransparency: self.reduceTransparency,
                            reduceMotion: self.reduceMotion
                        )
                    }

                    if case .proposing(let proposal) = self.viewModel.mode {
                        ToolStateView(
                            mode: .proposal(proposal),
                            reduceTransparency: self.reduceTransparency,
                            reduceMotion: self.reduceMotion
                        )
                    }

                    if case .awaitingFollowUp = self.viewModel.mode {
                        FollowUpPromptView(reduceTransparency: self.reduceTransparency)
                    }

                    if case .error(let message) = self.viewModel.mode {
                        ChatBubbleView(
                            text: message,
                            role: .tool,
                            state: .tool("Error"),
                            isPartial: false,
                            reduceTransparency: self.reduceTransparency,
                            reduceMotion: self.reduceMotion
                        )
                    }

                    Color.clear
                        .frame(height: 1)
                        .id(self.scrollAnchorID)
                }
                .padding(.horizontal, 4)
                .padding(.bottom, 4)
            }
            .scrollIndicators(.hidden)
            .onChange(of: self.viewModel.messages.count) { _, _ in
                self.scrollToBottom(proxy)
                self.invalidateWindowShadow()
            }
            .onChange(of: self.viewModel.mode) { _, _ in
                self.scrollToBottom(proxy)
                self.invalidateWindowShadow()
            }
        }
    }

    private var visibleMessages: [OverlayMessage] {
        self.viewModel.messages.filter { message in
            if case .listening = self.viewModel.mode,
               message.role == .user,
               message.isPartial {
                return false
            }
            return true
        }
    }

    private var voiceInputState: VoiceInputControlView.State {
        switch self.viewModel.mode {
        case .listening:
            return .active(transcript: self.currentPartialTranscript)
        case .awaitingFollowUp:
            return .idle(label: self.activityLabelOr("Press Enter to reply"))
        case .thinking:
            return .idle(label: self.activityLabelOr("Thinking"))
        case .responding:
            return .idle(label: self.activityLabelOr("Responding"))
        case .executing:
            return .idle(label: self.activityLabelOr("Executing"))
        case .proposing:
            return .idle(label: "Confirm action")
        case .completed:
            return .idle(label: "Done")
        case .error:
            return .idle(label: "Error")
        case .hidden:
            return .idle(label: "Listening")
        }
    }

    /// Returns the activity display label if set, otherwise the fallback
    private func activityLabelOr(_ fallback: String) -> String {
        let label = self.viewModel.activity.displayLabel
        return label.isEmpty ? fallback : label
    }

    private var currentPartialTranscript: String? {
        self.viewModel.messages.last { message in
            message.role == .user && message.isPartial
        }?.content
    }

    private var shouldShowThinkingBubble: Bool {
        if case .thinking = self.viewModel.mode {
            // Don't show thinking bubble if we're showing a tool bubble
            return !self.viewModel.activity.isToolOperation
        }
        return false
    }

    /// Label for the thinking bubble based on current activity
    private var thinkingBubbleLabel: String? {
        switch self.viewModel.activity {
        case .planning:
            return nil
        case .composing:
            return "Composing response"
        case .none, .listening, .speaking, .waiting:
            return nil  // Use default "Thinking"
        case .toolCall, .toolResult:
            return nil  // Shouldn't reach here due to shouldShowThinkingBubble guard
        }
    }

    /// Whether to show a tool operation bubble
    private var shouldShowToolBubble: Bool {
        if case .thinking = self.viewModel.mode {
            return self.viewModel.activity.isToolOperation
        }
        return false
    }

    private var shouldShowExecutingBubble: Bool {
        if case .executing = self.viewModel.mode {
            return true
        }
        return false
    }

    private var voiceInputAccessibilityLabel: String {
        switch self.voiceInputState {
        case .idle(let label):
            return label
        case .active:
            return "Listening for your voice"
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        let action = {
            proxy.scrollTo(self.scrollAnchorID, anchor: .bottom)
        }

        if self.reduceMotion {
            action()
        } else {
            withAnimation(.easeOut(duration: 0.2)) {
                action()
            }
        }
    }

    /// Invalidate window shadow to help clear glass rendering artifacts.
    /// Called after layout changes that may leave visual artifacts between glass regions.
    private func invalidateWindowShadow() {
        // Delay slightly to let SwiftUI complete its layout pass
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            OverlayWindowController.shared.invalidateShadow()
        }
    }
}

// MARK: - Follow-Up Prompt

struct FollowUpPromptView: View {
    let reduceTransparency: Bool

    var body: some View {
        HStack {
            Spacer(minLength: OverlayLayout.bubbleInset)
            self.content
                .frame(maxWidth: OverlayLayout.assistantBubbleMaxWidth, alignment: .trailing)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Press Enter to reply, or Escape to close")
    }

    @ViewBuilder
    private var content: some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        let base = HStack(spacing: 6) {
            Image(systemName: "mic.fill")
                .font(.caption2)
                .foregroundColor(.cyan.opacity(0.9))
            Text("Enter to reply · Esc to close")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, OverlayLayout.bubblePaddingHorizontal)
        .padding(.vertical, 10)

        if self.reduceTransparency {
            base
                .background(shape.fill(Color(nsColor: .controlBackgroundColor).opacity(0.94)))
                .overlay(shape.stroke(Color.white.opacity(0.08), lineWidth: 0.6))
        } else {
            // Tint opacity lowered to reduce black outline artifacts
            base
                .glassEffect(.regular.tint(.white.opacity(0.04)), in: shape)
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
