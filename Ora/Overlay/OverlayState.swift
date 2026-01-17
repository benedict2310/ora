//
//  OverlayState.swift
//  Ora
//
//  State management for the overlay window
//

import Foundation

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
            return "Planning response"
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
    let summary: String
    let details: String?
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

// MARK: - Overlay View Model

/// Observable state for the overlay
@MainActor
final class OverlayViewModel: ObservableObject {
    @Published var mode: OverlayMode = .hidden
    @Published var messages: [OverlayMessage] = []
    @Published var currentProposal: ToolProposal?
    @Published var activity: OverlayActivity = .none

    /// Minimum time a tool activity should be visible (seconds)
    private let toolActivityMinDuration: TimeInterval = 0.6

    /// When the current tool activity started
    private var toolActivityStartTime: Date?

    /// Pending activity to apply after minimum duration
    private var pendingActivity: OverlayActivity?

    /// Task for delayed activity update
    private var activityDelayTask: Task<Void, Never>?

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

    // MARK: - Tool Proposals

    /// Show a tool proposal
    func showProposal(_ proposal: ToolProposal) {
        self.currentProposal = proposal
        self.mode = .proposing(proposal)
    }

    // MARK: - Activity

    /// Update the current activity status with minimum display duration for tool activities
    func setActivity(_ newActivity: OverlayActivity) {
        // Cancel any pending delayed update
        self.activityDelayTask?.cancel()
        self.activityDelayTask = nil
        self.pendingActivity = nil

        // If new activity is a tool operation, track start time and apply immediately
        if newActivity.isToolOperation {
            self.toolActivityStartTime = Date()
            self.activity = newActivity
            return
        }

        // If current activity is a tool operation, ensure minimum display duration
        if self.activity.isToolOperation, let startTime = self.toolActivityStartTime {
            let elapsed = Date().timeIntervalSince(startTime)
            let remaining = self.toolActivityMinDuration - elapsed

            if remaining > 0 {
                // Delay the new activity
                self.pendingActivity = newActivity
                self.activityDelayTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(remaining))
                    guard let self = self, !Task.isCancelled else { return }
                    if let pending = self.pendingActivity {
                        self.toolActivityStartTime = nil
                        self.pendingActivity = nil
                        self.activity = pending
                    }
                }
                return
            }
        }

        // Apply immediately
        self.toolActivityStartTime = nil
        self.activity = newActivity
    }

    // MARK: - Reset

    /// Clear conversation for new session
    func reset() {
        self.activityDelayTask?.cancel()
        self.activityDelayTask = nil
        self.pendingActivity = nil
        self.toolActivityStartTime = nil
        self.messages.removeAll()
        self.currentProposal = nil
        self.mode = .hidden
        self.activity = .none
    }
}
