//
//  MessageModel.swift
//  Ora
//
//  Per-message SwiftData model for relationship-based transcript storage.
//  Replaces the JSON blob in Session.messagesData for improved query
//  performance and per-message operations.
//

import Foundation
import SwiftData

@Model
final class MessageModel {

    // MARK: - Properties

    @Attribute(.unique) var id: UUID
    var role: String
    var content: String
    var timestamp: Date
    var metadataJSON: String?

    /// Relationship back to the owning session.
    var session: Session?

    // MARK: - Initialization

    init(
        id: UUID = UUID(),
        role: String,
        content: String,
        timestamp: Date = Date(),
        metadataJSON: String? = nil,
        session: Session? = nil
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.timestamp = timestamp
        self.metadataJSON = metadataJSON
        self.session = session
    }

    // MARK: - Conversion

    /// Convert to the value-type `Session.Message` for consumers.
    func toMessage() -> Session.Message {
        let metadata: [String: String]?
        if let json = self.metadataJSON,
           let data = json.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([String: String].self, from: data) {
            metadata = decoded
        } else {
            metadata = nil
        }

        return Session.Message(
            id: self.id,
            role: Session.Message.Role(rawValue: self.role) ?? .user,
            content: self.content,
            timestamp: self.timestamp,
            metadata: metadata
        )
    }

    /// Create from a value-type `Session.Message`.
    static func from(_ message: Session.Message, session: Session? = nil) -> MessageModel {
        let metadataJSON: String?
        if let metadata = message.metadata,
           let data = try? JSONEncoder().encode(metadata) {
            metadataJSON = String(data: data, encoding: .utf8)
        } else {
            metadataJSON = nil
        }

        return MessageModel(
            id: message.id,
            role: message.role.rawValue,
            content: message.content,
            timestamp: message.timestamp,
            metadataJSON: metadataJSON,
            session: session
        )
    }
}
