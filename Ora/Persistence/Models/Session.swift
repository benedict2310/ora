//
//  Session.swift
//  Ora
//
//  Conversation session model
//

import Foundation
import SwiftData
import os

@Model
final class Session {

    // MARK: - Performance Instrumentation

    private static let persistenceLogger = Logger(subsystem: "com.ora.app", category: "persistence")
    private static let persistenceSignposter = OSSignposter(logger: persistenceLogger)
    private static let slowOperationThresholdNanoseconds = Session.resolveSlowOperationThresholdNanoseconds()

    // MARK: - Properties

    /// Unique identifier
    @Attribute(.unique) var id: UUID

    /// When the session started
    var createdAt: Date

    /// When the session was last updated
    var updatedAt: Date

    /// Short summary of the conversation
    var summary: String?

    /// Messages in this session (stored as JSON blob — legacy, kept for backward compat)
    var messagesData: Data?

    /// Per-message relationship storage (new, replaces messagesData for new writes)
    @Relationship(deleteRule: .cascade, inverse: \MessageModel.session)
    var messageModels: [MessageModel]?

    /// Whether the session has been migrated from blob to relationship storage
    var isMigrated: Bool = false

    /// Whether the session is complete
    var isComplete: Bool

    // MARK: - Initialization

    init() {
        self.id = UUID()
        self.createdAt = Date()
        self.updatedAt = Date()
        self.isComplete = false
        self.isMigrated = true
    }

    // MARK: - Messages

    struct Message: Codable, Sendable {
        let id: UUID
        let role: Role
        let content: String
        let timestamp: Date
        let metadata: [String: String]?

        enum Role: String, Codable, Sendable {
            case user
            case assistant
            case tool
        }
    }

    var messages: [Message] {
        get {
            // Prefer relationship storage if migrated
            if self.isMigrated, let models = self.messageModels, !models.isEmpty {
                return models
                    .sorted { $0.timestamp < $1.timestamp }
                    .map { $0.toMessage() }
            }

            // Fallback to blob storage
            guard let data = self.messagesData else { return [] }

            let state = Self.persistenceSignposter.beginInterval("session.messages.decode")
            let start = DispatchTime.now().uptimeNanoseconds
            let decodedMessages = (try? JSONDecoder().decode([Message].self, from: data)) ?? []
            let elapsedNanoseconds = DispatchTime.now().uptimeNanoseconds - start
            Self.persistenceSignposter.endInterval("session.messages.decode", state)

            Self.logIfSlow(
                operation: "messagesData.decode",
                elapsedNanoseconds: elapsedNanoseconds,
                messageCount: decodedMessages.count,
                payloadBytes: data.count
            )

            return decodedMessages
        }
        set {
            if self.isMigrated {
                // Replace relationship storage with new values
                self.messageModels = newValue.map { MessageModel.from($0, session: self) }
                self.updatedAt = Date()
                return
            }

            // Legacy blob path
            let state = Self.persistenceSignposter.beginInterval("session.messages.encode")
            let start = DispatchTime.now().uptimeNanoseconds
            let encodedData = try? JSONEncoder().encode(newValue)
            let elapsedNanoseconds = DispatchTime.now().uptimeNanoseconds - start
            Self.persistenceSignposter.endInterval("session.messages.encode", state)

            self.messagesData = encodedData
            self.updatedAt = Date()

            Self.logIfSlow(
                operation: "messagesData.encode",
                elapsedNanoseconds: elapsedNanoseconds,
                messageCount: newValue.count,
                payloadBytes: encodedData?.count ?? 0
            )
        }
    }

    func addMessage(
        role: Message.Role,
        content: String,
        metadata: [String: String]? = nil,
        timestamp: Date = Date()
    ) {
        let message = Message(
            id: UUID(),
            role: role,
            content: content,
            timestamp: timestamp,
            metadata: metadata
        )

        // Append to relationship storage if migrated
        if self.isMigrated {
            let model = MessageModel.from(message, session: self)
            if self.messageModels != nil {
                self.messageModels?.append(model)
            } else {
                self.messageModels = [model]
            }
            self.updatedAt = Date()
            return
        }

        // Legacy blob path
        var current = messages
        current.append(message)
        messages = current
    }

    // MARK: - Migration

    /// Migrate this session from blob storage to relationship storage.
    /// Returns the number of messages migrated, or 0 if already migrated / no data.
    @discardableResult
    func migrateToRelationshipStorage() -> Int {
        guard !self.isMigrated else {
            return 0
        }

        guard let data = self.messagesData,
              let blobMessages = try? JSONDecoder().decode([Message].self, from: data),
              !blobMessages.isEmpty else {
            self.isMigrated = true
            return 0
        }

        let models = blobMessages.map { MessageModel.from($0, session: self) }
        self.messageModels = models
        self.isMigrated = true

        return models.count
    }

    // MARK: - Helpers

    private static func resolveSlowOperationThresholdNanoseconds() -> UInt64 {
        let defaultThresholdMilliseconds = 10.0
        let environment = ProcessInfo.processInfo.environment
        let configuredThresholdMilliseconds = environment["ORA_PERSISTENCE_SLOW_LOG_THRESHOLD_MS"]
            .flatMap(Double.init)
            ?? defaultThresholdMilliseconds
        let clampedThresholdMilliseconds = max(0, configuredThresholdMilliseconds)
        return UInt64(clampedThresholdMilliseconds * 1_000_000.0)
    }

    private static func logIfSlow(
        operation: String,
        elapsedNanoseconds: UInt64,
        messageCount: Int,
        payloadBytes: Int
    ) {
        guard elapsedNanoseconds >= Self.slowOperationThresholdNanoseconds else {
            return
        }

        let elapsedMilliseconds = Double(elapsedNanoseconds) / 1_000_000.0
        Self.persistenceLogger.notice(
            "Slow persistence \(operation): \(elapsedMilliseconds, format: .fixed(precision: 2))ms (messages: \(messageCount), payloadBytes: \(payloadBytes))"
        )
    }
}
