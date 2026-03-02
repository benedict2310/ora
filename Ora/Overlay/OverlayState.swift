//
//  OverlayState.swift
//  Ora
//
//  State management for the overlay window
//

import Foundation
import os

// MARK: - Overlay Activity

/// Activity status shown in the voice input control
///
/// This provides fine-grained feedback about what the agent is doing,
/// complementing the broader `OverlayMode` state machine.
enum OverlayActivity: Equatable, Sendable {
    /// Listening for user speech
    case listening
    /// Planning/reasoning before tool calls or response
    case planning
    /// Calling a tool
    case toolCall(label: String)
    /// Processing tool result
    case toolResult(label: String)
    /// Generating response text
    case composing
    /// Speaking the response
    case speaking
    /// Waiting for user follow-up
    case waiting
    /// No specific activity (default/idle)
    case none

    /// User-friendly display label
    var displayLabel: String {
        switch self {
        case .listening:
            return "Listening"
        case .planning:
            return "Thinking"
        case .toolCall(let label):
            return "Calling \(label)"
        case .toolResult(let label):
            return "Processing \(label) result"
        case .composing:
            return "Composing response"
        case .speaking:
            return "Speaking"
        case .waiting:
            return "Waiting for your reply"
        case .none:
            return ""
        }
    }

    /// Map tool name to user-friendly label
    static func toolLabel(for toolName: String) -> String {
        let prefix = toolName.split(separator: ".").first.map(String.init) ?? toolName
        switch prefix {
        case "calendar":
            return "Calendar"
        case "reminders":
            return "Reminders"
        case "contacts":
            return "Contacts"
        case "system":
            if toolName == "system.run_shortcut" || toolName == "system.list_shortcuts" {
                return "Shortcuts"
            }
            return "System"
        case "skills":
            return "Skills"
        default:
            return "Tool"
        }
    }

    /// Whether this activity represents a tool operation
    var isToolOperation: Bool {
        switch self {
        case .toolCall, .toolResult:
            return true
        default:
            return false
        }
    }
}

// MARK: - Overlay Mode

/// Current state of the overlay
enum OverlayMode: Equatable, Sendable {
    case hidden
    case listening
    case thinking
    case responding
    case awaitingFollowUp
    case proposing(ToolProposal)
    case executing
    case completed
    case error(String)
}

// MARK: - Tool Proposal

/// Tool proposal requiring user confirmation
struct ToolProposal: Equatable, Sendable {
    let toolName: String
    let title: String?
    let summary: String
    let details: String?
    let confirmLabel: String?
    let cancelLabel: String?
    let trustLabel: String?
    let presentation: ToolAuthorizationPresentation

    init(
        toolName: String,
        title: String? = nil,
        summary: String,
        details: String?,
        confirmLabel: String? = nil,
        cancelLabel: String? = nil,
        trustLabel: String? = nil,
        presentation: ToolAuthorizationPresentation = .inline
    ) {
        self.toolName = toolName
        self.title = title
        self.summary = summary
        self.details = details
        self.confirmLabel = confirmLabel
        self.cancelLabel = cancelLabel
        self.trustLabel = trustLabel
        self.presentation = presentation
    }
}

// MARK: - Overlay Message

/// A message in the conversation
struct OverlayMessage: Identifiable, Equatable, Sendable {
    let id: UUID
    let role: MessageRole
    var content: String
    var isPartial: Bool
    let timestamp: Date

    enum MessageRole: Sendable {
        case user
        case assistant
    }

    init(role: MessageRole, content: String, isPartial: Bool = false) {
        self.id = UUID()
        self.role = role
        self.content = content
        self.isPartial = isPartial
        self.timestamp = Date()
    }
}

// MARK: - Overlay Actions

@MainActor
protocol OverlayActionHandling: AnyObject {
    func confirmToolProposal()
    func confirmAndTrustToolProposal()
    func denyToolProposal()
    func stopSpeechPlayback()
}

// MARK: - Overlay View Model

/// Observable state for the overlay
@MainActor
final class OverlayViewModel: ObservableObject {
    private let logger = Logger.ora(category: "OverlayViewModel")
    @Published var mode: OverlayMode = .hidden
    @Published var messages: [OverlayMessage] = []
    @Published var currentProposal: ToolProposal?
    @Published var activity: OverlayActivity = .none
    @Published var skillsHintText: String?
    weak var actionHandler: (any OverlayActionHandling)?

    /// Delay before showing tool activity to avoid flicker (seconds)
    private let toolActivityRevealDelay: TimeInterval = 0.2

    /// Pending tool activity waiting to be shown
    private var pendingToolActivity: OverlayActivity?

    /// Task for delayed tool activity reveal
    private var toolActivityRevealTask: Task<Void, Never>?

    // MARK: - User Messages

    /// Add a user message (from ASR)
    func addUserMessage(_ text: String, isPartial: Bool) {
        if let lastIndex = self.messages.lastIndex(where: { $0.role == .user && $0.isPartial }) {
            // Update existing partial
            self.messages[lastIndex].content = text
            self.messages[lastIndex].isPartial = isPartial
        } else {
            // Add new message
            self.messages.append(OverlayMessage(role: .user, content: text, isPartial: isPartial))
        }
    }

    // MARK: - Assistant Messages

    /// Add an assistant message (from LLM)
    func addAssistantMessage(_ text: String, isPartial: Bool) {
        if let lastIndex = self.messages.lastIndex(where: { $0.role == .assistant && $0.isPartial }) {
            // Update existing partial
            self.messages[lastIndex].content = text
            self.messages[lastIndex].isPartial = isPartial
        } else {
            // Add new message
            self.messages.append(OverlayMessage(role: .assistant, content: text, isPartial: isPartial))
        }
    }

    /// Remove a trailing partial assistant message, if present.
    func discardTrailingPartialAssistantMessage() {
        guard let lastMessage = self.messages.last else { return }
        guard lastMessage.role == .assistant, lastMessage.isPartial else { return }
        self.messages.removeLast()
        self.logger.notice("OVERLAY_DISCARDED_PARTIAL_ASSISTANT_MESSAGE")
    }

    // MARK: - Tool Proposals

    /// Show a tool proposal
    func showProposal(_ proposal: ToolProposal) {
        self.currentProposal = proposal
        self.mode = .proposing(proposal)
    }

    // MARK: - Activity

    /// Update the current activity status with delayed tool reveal to avoid flicker
    func setActivity(_ newActivity: OverlayActivity) {
        // Tool activity transitions stay visible once shown
        if newActivity.isToolOperation {
            if self.activity.isToolOperation {
                self.toolActivityRevealTask?.cancel()
                self.toolActivityRevealTask = nil
                self.pendingToolActivity = nil
                self.activity = newActivity
                return
            }

            self.pendingToolActivity = newActivity

            if self.toolActivityRevealTask == nil {
                self.toolActivityRevealTask = Task { @MainActor [weak self] in
                    guard let self else { return }
                    do {
                        try await Task.sleep(for: .seconds(self.toolActivityRevealDelay))
                    } catch {
                        return
                    }
                    guard !Task.isCancelled else { return }
                    if let pending = self.pendingToolActivity {
                        self.activity = pending
                        self.pendingToolActivity = nil
                    }
                    self.toolActivityRevealTask = nil
                }
            }
            return
        }

        // Non-tool activities apply immediately
        self.toolActivityRevealTask?.cancel()
        self.toolActivityRevealTask = nil
        self.pendingToolActivity = nil
        self.activity = newActivity
    }

    // MARK: - Reset

    /// Clear conversation for new session
    func reset() {
        self.logger.info("Overlay model reset")
        self.toolActivityRevealTask?.cancel()
        self.toolActivityRevealTask = nil
        self.pendingToolActivity = nil
        self.messages.removeAll()
        self.currentProposal = nil
        self.mode = .hidden
        self.activity = .none
    }
}
