//
//  OverlayState.swift
//  Ora
//
//  State management for the overlay window
//

import Foundation

// MARK: - Overlay Mode

/// Current state of the overlay
enum OverlayMode: Equatable, Sendable {
    case hidden
    case listening
    case thinking
    case responding
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

    // MARK: - Reset

    /// Clear conversation for new session
    func reset() {
        self.messages.removeAll()
        self.currentProposal = nil
        self.mode = .hidden
    }
}
