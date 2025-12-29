//
//  Session.swift
//  Ora
//
//  Conversation session model
//

import Foundation
import SwiftData

@Model
final class Session {

    // MARK: - Properties

    /// Unique identifier
    @Attribute(.unique) var id: UUID

    /// When the session started
    var createdAt: Date

    /// When the session was last updated
    var updatedAt: Date

    /// Short summary of the conversation
    var summary: String?

    /// Messages in this session (stored as JSON)
    var messagesData: Data?

    /// Whether the session is complete
    var isComplete: Bool

    // MARK: - Initialization

    init() {
        self.id = UUID()
        self.createdAt = Date()
        self.updatedAt = Date()
        self.isComplete = false
    }

    // MARK: - Messages

    struct Message: Codable, Sendable {
        let id: UUID
        let role: Role
        let content: String
        let timestamp: Date

        enum Role: String, Codable, Sendable {
            case user
            case assistant
            case tool
        }
    }

    var messages: [Message] {
        get {
            guard let data = messagesData else { return [] }
            return (try? JSONDecoder().decode([Message].self, from: data)) ?? []
        }
        set {
            messagesData = try? JSONEncoder().encode(newValue)
            updatedAt = Date()
        }
    }

    func addMessage(role: Message.Role, content: String) {
        var current = messages
        current.append(Message(
            id: UUID(),
            role: role,
            content: content,
            timestamp: Date()
        ))
        messages = current
    }
}
