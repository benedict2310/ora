//
//  OverlayView.swift
//  Ora
//
//  Main overlay content view
//

import Foundation
import SwiftUI

// MARK: - Main Overlay View

struct OverlayView: View {
    @EnvironmentObject var viewModel: OverlayViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @ObservedObject private var taskProgressObserver: TaskProgressObserver
    @State private var currentProviderType: LLMProviderType = .local

    @Namespace private var inputGlassNamespace

    // Coalesces rapid-fire scroll triggers (e.g. mode + messages firing within one frame).
    @State private var pendingScrollTask: Task<Void, Never>?
    @State private var measuredTailHeight: CGFloat = 0

    private static let scrollAnchorID = "overlay-scroll-anchor"

    init(taskProgressObserver: TaskProgressObserver = .shared) {
        self._taskProgressObserver = ObservedObject(wrappedValue: taskProgressObserver)
    }

    var body: some View {
        GlassEffectContainer(spacing: OverlayLayout.containerSpacing) {
            VStack(alignment: .leading, spacing: OverlayLayout.containerSpacing) {
                if self.shouldShowTextInputControl {
                    TextInputView(
                        text: self.$viewModel.textInputText,
                        reduceMotion: self.reduceMotion,
                        reduceTransparency: self.reduceTransparency,
                        namespace: self.inputGlassNamespace,
                        onSubmit: { text in
                            SimplePipelineController.shared.submitTextInput(text)
                        },
                        onCancel: {
                            SimplePipelineController.shared.cancel()
                        },
                        onPasteImage: {
                            self.viewModel.actionHandler?.pasteImageAttachment()
                        },
                        onChooseImageFile: {
                            self.viewModel.actionHandler?.chooseImageAttachmentFile()
                        },
                        onCaptureScreenshot: {
                            self.viewModel.actionHandler?.captureScreenshotAttachment()
                        }
                    )
                    .accessibilityLabel("Type a message")
                } else {
                    VoiceInputControlView(
                        state: self.voiceInputState,
                        reduceMotion: self.reduceMotion,
                        reduceTransparency: self.reduceTransparency,
                        namespace: self.inputGlassNamespace,
                        onPasteImage: {
                            self.viewModel.actionHandler?.pasteImageAttachment()
                        },
                        onChooseImageFile: {
                            self.viewModel.actionHandler?.chooseImageAttachmentFile()
                        },
                        onCaptureScreenshot: {
                            self.viewModel.actionHandler?.captureScreenshotAttachment()
                        }
                    )
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(self.voiceInputAccessibilityLabel)
                }

                if !self.viewModel.pendingImageAttachments.isEmpty {
                    AttachmentTrayView(
                        attachments: self.viewModel.pendingImageAttachments,
                        reduceTransparency: self.reduceTransparency,
                        onRemove: { attachmentID in
                            self.viewModel.actionHandler?.removePendingImageAttachment(attachmentID)
                        },
                        onClearAll: {
                            self.viewModel.actionHandler?.clearPendingImageAttachments()
                        }
                    )
                    .padding(.horizontal, 4)
                }

                if let notice = self.viewModel.attachmentNotice {
                    OverlayPromptView(
                        text: notice.message,
                        iconName: "exclamationmark.triangle.fill",
                        accessibilityLabel: notice.message,
                        reduceTransparency: self.reduceTransparency,
                        action: notice.offersOpenSettings ? {
                            self.viewModel.actionHandler?.openScreenRecordingSettings()
                        } : nil
                    )
                }

                if let notice = self.viewModel.migrationNotice {
                    OverlayPromptView(
                        text: notice.message,
                        iconName: notice.iconName,
                        accessibilityLabel: notice.message,
                        reduceTransparency: self.reduceTransparency,
                        action: self.action(for: notice.action)
                    )
                }

                if self.currentProviderType.isCloud {
                    HStack {
                        Spacer()
                        CloudIndicator(providerType: self.currentProviderType)
                    }
                    .padding(.trailing, 4)
                }

                self.chatScrollView

                if self.shouldShowTaskStatus {
                    OverlayTaskStatusView(
                        taskProgressObserver: self.taskProgressObserver,
                        reduceTransparency: self.reduceTransparency
                    )
                    .transition(.opacity)
                }
            }
            .frame(maxWidth: OverlayLayout.contentMaxWidth, maxHeight: .infinity, alignment: .top)
            .animation(
                self.reduceMotion ? nil : .easeOut(duration: OverlayLayout.showAnimationDuration),
                value: self.shouldShowTaskStatus
            )
        }
        .padding(16)
        .frame(width: OverlayLayout.panelWidth, height: OverlayLayout.panelHeight)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Ora Assistant")
        .sheet(isPresented: self.modalProposalBinding) {
            if let proposal = self.modalProposal {
                SkillAuthoringConfirmationSheet(
                    proposal: proposal,
                    onConfirm: {
                        self.viewModel.actionHandler?.confirmToolProposal()
                    },
                    onCancel: {
                        self.viewModel.actionHandler?.denyToolProposal()
                    }
                )
            }
        }
        .onAppear {
            self.refreshProviderType()
        }
        .onReceive(NotificationCenter.default.publisher(for: .llmProviderChanged)) { notification in
            if let type = notification.userInfo?["type"] as? LLMProviderType {
                self.currentProviderType = type
            } else {
                self.refreshProviderType()
            }
        }
    }

    private var chatScrollView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: OverlayLayout.rowSpacing) {
                    LazyVStack(alignment: .leading, spacing: OverlayLayout.rowSpacing) {
                        ForEach(self.historicalMessages) { message in
                            ChatBubbleView(
                                text: message.content,
                                role: message.role == .user ? .user : .assistant,
                                state: nil,
                                isPartial: message.isPartial,
                                reduceTransparency: self.reduceTransparency,
                                reduceMotion: self.reduceMotion,
                                thumbnailURLs: message.thumbnailURLs
                            )
                            .id(message.id)
                        }
                    }

                    VStack(alignment: .leading, spacing: OverlayLayout.rowSpacing) {
                        if let latestMessage = self.latestVisibleMessage {
                            self.bubbleView(for: latestMessage)
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
                            .id("thinking-bubble")
                            .transition(.opacity)
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
                            .id("tool-bubble")
                            .transition(.opacity)
                        }

                        if self.shouldShowExecutingBubble {
                            ToolStateView(
                                mode: .executing(label: "Executing action"),
                                reduceTransparency: self.reduceTransparency,
                                reduceMotion: self.reduceMotion,
                                onConfirmProposal: { },
                                onConfirmAndTrustProposal: { },
                                onDenyProposal: { }
                            )
                            .id("executing-bubble")
                        }

                        if case .proposing(let proposal) = self.viewModel.mode,
                           !proposal.presentation.usesModalSheet {
                            ToolStateView(
                                mode: .proposal(proposal),
                                reduceTransparency: self.reduceTransparency,
                                reduceMotion: self.reduceMotion,
                                onConfirmProposal: {
                                    self.viewModel.actionHandler?.confirmToolProposal()
                                },
                                onConfirmAndTrustProposal: {
                                    self.viewModel.actionHandler?.confirmAndTrustToolProposal()
                                },
                                onDenyProposal: {
                                    self.viewModel.actionHandler?.denyToolProposal()
                                }
                            )
                            .id("proposal-bubble")
                        }

                        if case .awaitingFollowUp = self.viewModel.mode {
                            FollowUpPromptView(reduceTransparency: self.reduceTransparency)
                                .id("followup-prompt")
                        }

                        if self.shouldShowSkillsHint,
                           let skillsHintText = self.viewModel.skillsHintText {
                            OverlayPromptView(
                                text: skillsHintText,
                                iconName: "sparkles",
                                accessibilityLabel: skillsHintText,
                                reduceTransparency: self.reduceTransparency,
                                action: nil
                            )
                            .id("skills-hint")
                        }

                        if self.shouldShowStopSpeakingPrompt {
                            StopSpeakingPromptView(
                                reduceTransparency: self.reduceTransparency,
                                onStopSpeaking: {
                                    self.viewModel.actionHandler?.stopSpeechPlayback()
                                }
                            )
                            .id("stop-speaking-prompt")
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
                            .id("error-bubble")
                        }

                        Color.clear
                            .frame(height: 1)
                            .id(Self.scrollAnchorID)
                    }
                    .background(
                        GeometryReader { proxy in
                            Color.clear.preference(key: OverlayTailHeightPreferenceKey.self, value: proxy.size.height)
                        }
                    )
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
            .onChange(of: self.viewModel.activity) { oldActivity, newActivity in
                self.scrollToBottomIfNeededForActivityChange(from: oldActivity, to: newActivity, proxy: proxy)
                self.invalidateWindowShadow()
            }
            .onChange(of: self.viewModel.pendingImageAttachments.count) { _, _ in
                self.invalidateWindowShadow()
            }
            .onChange(of: self.viewModel.attachmentNotice) { _, _ in
                self.invalidateWindowShadow()
            }
            .onChange(of: self.viewModel.migrationNotice) { _, _ in
                self.invalidateWindowShadow()
            }
            .onPreferenceChange(OverlayTailHeightPreferenceKey.self) { newHeight in
                guard abs(newHeight - self.measuredTailHeight) > 0.5 else { return }
                self.measuredTailHeight = newHeight
                self.scrollToBottom(proxy)
            }
        }
    }

    var shouldShowTaskStatus: Bool {
        return self.taskProgressObserver.hasActiveTasks
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

    private var historicalMessages: [OverlayMessage] {
        Array(self.visibleMessages.dropLast())
    }

    private var latestVisibleMessage: OverlayMessage? {
        self.visibleMessages.last
    }

    @ViewBuilder
    private func bubbleView(for message: OverlayMessage) -> some View {
        ChatBubbleView(
            text: message.content,
            role: message.role == .user ? .user : .assistant,
            state: nil,
            isPartial: message.isPartial,
            reduceTransparency: self.reduceTransparency,
            reduceMotion: self.reduceMotion,
            thumbnailURLs: message.thumbnailURLs
        )
        .id(message.id)
    }

    private var modalProposal: ToolProposal? {
        guard case .proposing(let proposal) = self.viewModel.mode,
              proposal.presentation.usesModalSheet else {
            return nil
        }
        return proposal
    }

    private var modalProposalBinding: Binding<Bool> {
        Binding(
            get: { self.modalProposal != nil },
            set: { _ in }
        )
    }

    private var voiceInputState: VoiceInputControlView.State {
        if self.viewModel.inputMode == .text,
           self.viewModel.mode == .awaitingFollowUp,
           !self.viewModel.isTextInputVisible {
            return .idle(label: "Type a message or ⌘D for voice")
        }

        switch self.viewModel.mode {
        case .listening:
            if self.viewModel.inputMode == .voice,
               self.viewModel.typingHintVisible,
               self.currentPartialTranscript == nil {
                return .idle(label: "Start typing...")
            }
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

    private var shouldShowTextInputControl: Bool {
        return self.viewModel.inputMode == .text && self.viewModel.isTextInputVisible
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

    private var shouldShowStopSpeakingPrompt: Bool {
        self.viewModel.activity == .speaking
    }

    private var shouldShowSkillsHint: Bool {
        switch self.viewModel.mode {
        case .hidden:
            return false
        default:
            return true
        }
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
        // Cancel any pending scroll — coalesces rapid-fire triggers (mode + messages in one frame).
        self.pendingScrollTask?.cancel()
        self.pendingScrollTask = Task { @MainActor in
            do { try await Task.sleep(for: .milliseconds(16)) } catch { return }
            // Scroll to an eager bottom anchor that lives outside the lazy transcript rows.
            // No animation avoids competing with bubble insertion transitions.
            proxy.scrollTo(Self.scrollAnchorID, anchor: .bottom)
        }
    }

    private func scrollToBottomIfNeededForActivityChange(
        from oldActivity: OverlayActivity,
        to newActivity: OverlayActivity,
        proxy: ScrollViewProxy
    ) {
        guard Self.activityChangeAffectsTranscriptLayout(
            from: oldActivity,
            to: newActivity,
            mode: self.viewModel.mode
        ) else {
            return
        }
        self.scrollToBottom(proxy)
    }

    static func activityChangeAffectsTranscriptLayout(
        from oldActivity: OverlayActivity,
        to newActivity: OverlayActivity,
        mode: OverlayMode
    ) -> Bool {
        if case .thinking = mode {
            return oldActivity != newActivity
        }
        return oldActivity == .speaking || newActivity == .speaking
    }

    /// Invalidate window shadow to help clear glass rendering artifacts.
    /// Called after layout changes that may leave visual artifacts between glass regions.
    private func invalidateWindowShadow() {
        // Delay slightly to let SwiftUI complete its layout pass
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            OverlayWindowController.shared.invalidateShadow()
        }
    }

    private func refreshProviderType() {
        Task { @MainActor in
            self.currentProviderType = await LLMProviderManager.shared.getSelectedProviderType()
        }
    }

    private func action(for action: OverlayMigrationNoticeAction?) -> (() -> Void)? {
        guard let action else { return nil }
        return {
            switch action {
            case .openModelsPreferences:
                self.viewModel.actionHandler?.openModelsPreferences()
            }
        }
    }
}

private struct OverlayTailHeightPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

// MARK: - Overlay Prompts

private struct OverlayPromptView: View {
    let text: String
    let iconName: String
    let accessibilityLabel: String
    let reduceTransparency: Bool
    let action: (() -> Void)?

    var body: some View {
        HStack {
            Spacer(minLength: OverlayLayout.bubbleInset)
            self.content
                .frame(maxWidth: OverlayLayout.assistantBubbleMaxWidth, alignment: .trailing)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(self.accessibilityLabel)
    }

    @ViewBuilder
    private var content: some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        let base = HStack(spacing: 6) {
            Image(systemName: self.iconName)
                .font(.caption2)
                .foregroundColor(.cyan.opacity(0.9))
            Text(self.text)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, OverlayLayout.bubblePaddingHorizontal)
        .padding(.vertical, 10)

        if let action = self.action {
            Button(action: action) {
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
            .buttonStyle(.plain)
        } else {
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
}

struct FollowUpPromptView: View {
    let reduceTransparency: Bool

    var body: some View {
        OverlayPromptView(
            text: "Enter to reply · Esc to close",
            iconName: "mic.fill",
            accessibilityLabel: "Press Enter to reply, or Escape to close",
            reduceTransparency: self.reduceTransparency,
            action: nil
        )
    }
}

struct StopSpeakingPromptView: View {
    let reduceTransparency: Bool
    let onStopSpeaking: () -> Void

    var body: some View {
        OverlayPromptView(
            text: "Stop speaking · Esc",
            iconName: "speaker.slash.fill",
            accessibilityLabel: "Stop speaking",
            reduceTransparency: self.reduceTransparency,
            action: {
                self.onStopSpeaking()
            }
        )
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
