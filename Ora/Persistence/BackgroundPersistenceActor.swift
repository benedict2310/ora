//
//  BackgroundPersistenceActor.swift
//  Ora
//
//  Background ModelActor that handles heavy persistence operations
//  (JSON encode/decode, saves) off the main thread.
//

import Foundation
import SwiftData
import os

@ModelActor
actor BackgroundPersistenceActor {

    // MARK: - Properties

    private let logger = Logger.ora(category: "persistence")
    private let signposter = OSSignposter(logger: Logger.ora(category: "persistence"))

    // MARK: - Background Write Operations

    /// Append a message to a session on the background context.
    ///
    /// Accepts only value types (Sendable) — no `@Model` instances cross the boundary.
    func appendMessage(
        sessionID: UUID,
        role: Session.Message.Role,
        content: String,
        metadata: [String: String]?,
        timestamp: Date
    ) throws {
        let state = self.signposter.beginInterval("background.appendMessage")
        defer {
            self.signposter.endInterval("background.appendMessage", state)
        }

        let descriptor = FetchDescriptor<Session>(
            predicate: #Predicate { $0.id == sessionID }
        )

        guard let session = try self.modelContext.fetch(descriptor).first else {
            self.logger.warning("Background append: session \(sessionID) not found")
            return
        }

        session.addMessage(role: role, content: content, metadata: metadata, timestamp: timestamp)
        try self.saveContext()
    }

    /// Complete a session on the background context.
    func completeSession(sessionID: UUID) throws {
        let descriptor = FetchDescriptor<Session>(
            predicate: #Predicate { $0.id == sessionID }
        )

        guard let session = try self.modelContext.fetch(descriptor).first else {
            return
        }

        session.isComplete = true
        session.updatedAt = Date()

        if let firstMessage = session.messages.first(where: { $0.role == .user }) {
            session.summary = String(firstMessage.content.prefix(50))
        }

        try self.saveContext()
        self.logger.debug("Background completed session: \(sessionID)")
    }

    /// Save the background context with performance instrumentation.
    func saveContext() throws {
        guard self.modelContext.hasChanges else {
            return
        }

        let state = self.signposter.beginInterval("background.context.save")
        let start = DispatchTime.now().uptimeNanoseconds
        defer {
            self.signposter.endInterval("background.context.save", state)
        }

        try self.modelContext.save()

        let elapsedNanoseconds = DispatchTime.now().uptimeNanoseconds - start
        let elapsedMilliseconds = Double(elapsedNanoseconds) / 1_000_000.0
        if elapsedMilliseconds >= 10.0 {
            self.logger.notice("Slow background save: \(elapsedMilliseconds, format: .fixed(precision: 2))ms")
        }
    }

    /// Cleanup old data on the background context.
    func cleanupOldData(
        maxAuditEntries: Int,
        sessionRetentionDays: Int
    ) throws -> (auditEntriesDeleted: Int, sessionsDeleted: Int) {
        var auditDeleted = 0
        var sessionsDeleted = 0

        // Clean up audit entries
        let allEntriesDescriptor = FetchDescriptor<AuditLogEntryModel>(
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        let allEntries = try self.modelContext.fetch(allEntriesDescriptor)

        if allEntries.count > maxAuditEntries {
            let entriesToDelete = Array(allEntries.dropFirst(maxAuditEntries))
            for entry in entriesToDelete {
                self.modelContext.delete(entry)
                auditDeleted += 1
            }
        }

        // Clean up old sessions
        let cutoffDate = Calendar.current.date(byAdding: .day, value: -sessionRetentionDays, to: Date()) ?? Date()
        let oldSessionsDescriptor = FetchDescriptor<Session>(
            predicate: #Predicate { session in
                session.isComplete && session.updatedAt < cutoffDate
            }
        )
        let oldSessions = try self.modelContext.fetch(oldSessionsDescriptor)
        for session in oldSessions {
            self.modelContext.delete(session)
            sessionsDeleted += 1
        }

        if auditDeleted > 0 || sessionsDeleted > 0 {
            try self.saveContext()
            self.logger.info("Background cleanup: \(auditDeleted) audit entries, \(sessionsDeleted) sessions deleted")
        }

        return (auditDeleted, sessionsDeleted)
    }
}
