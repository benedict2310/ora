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

    private static let persistenceLogger = Logger.ora(category: "persistence")
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

    /// Messages in this session (stored as JSON blob)
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
        let metadata: [String: String]?

        enum Role: String, Codable, Sendable {
            case user
            case assistant
            case tool
        }
    }

    var messages: [Message] {
        get {
            guard let data = self.messagesData else {
                return []
            }

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

        var currentMessages = self.messages
        currentMessages.append(message)
        self.messages = currentMessages
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
