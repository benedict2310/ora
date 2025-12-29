//
//  PersistenceManager.swift
//  Ora
//
//  SwiftData container management
//

import Foundation
import SwiftData
import os

@MainActor
final class PersistenceManager {

    // MARK: - Singleton

    static let shared = PersistenceManager()

    // MARK: - Properties

    private let logger = Logger(subsystem: "com.ora.app", category: "Persistence")

    let container: ModelContainer
    var context: ModelContext {
        container.mainContext
    }

    // MARK: - Initialization

    private init() {
        let schema = Schema([
            Session.self,
            AuditLogEntryModel.self,
            AppSettings.self
        ])

        let configuration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: false,
            cloudKitDatabase: .none
        )

        do {
            container = try ModelContainer(for: schema, configurations: [configuration])
            self.logger.info("SwiftData container initialized")
        } catch {
            self.logger.error("Failed to initialize SwiftData: \(error.localizedDescription)")
            fatalError("Failed to initialize SwiftData: \(error)")
        }
    }

    // MARK: - Test Support

    /// Create a persistence manager with an in-memory store for testing
    static func createForTesting() -> PersistenceManager {
        return PersistenceManager(inMemory: true)
    }

    private init(inMemory: Bool) {
        let schema = Schema([
            Session.self,
            AuditLogEntryModel.self,
            AppSettings.self
        ])

        let configuration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: inMemory,
            cloudKitDatabase: .none
        )

        do {
            container = try ModelContainer(for: schema, configurations: [configuration])
            self.logger.info("SwiftData container initialized (in-memory: \(inMemory))")
        } catch {
            self.logger.error("Failed to initialize SwiftData: \(error.localizedDescription)")
            fatalError("Failed to initialize SwiftData: \(error)")
        }
    }

    // MARK: - Session Management

    /// Create a new session
    func createSession() -> Session {
        let session = Session()
        context.insert(session)
        self.saveContext()
        self.logger.debug("Created session: \(session.id)")
        return session
    }

    /// Get the current active session, or create one
    func currentSession() -> Session {
        let descriptor = FetchDescriptor<Session>(
            predicate: #Predicate { !$0.isComplete },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )

        if let session = try? context.fetch(descriptor).first {
            return session
        }

        return createSession()
    }

    /// Complete the current session
    func completeSession(_ session: Session) {
        session.isComplete = true
        session.updatedAt = Date()

        // Generate summary from first user message
        if let firstMessage = session.messages.first(where: { $0.role == .user }) {
            session.summary = String(firstMessage.content.prefix(50))
        }

        self.saveContext()
        self.logger.debug("Completed session: \(session.id)")
    }

    /// Fetch recent sessions
    func recentSessions(limit: Int = 20) -> [Session] {
        var descriptor = FetchDescriptor<Session>(
            predicate: #Predicate { $0.isComplete },
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        descriptor.fetchLimit = limit

        return (try? context.fetch(descriptor)) ?? []
    }

    /// Delete a session
    func deleteSession(_ session: Session) {
        context.delete(session)
        self.saveContext()
        self.logger.debug("Deleted session: \(session.id)")
    }

    /// Delete all sessions
    func deleteAllSessions() {
        do {
            try context.delete(model: Session.self)
            self.saveContext()
            self.logger.info("Deleted all sessions")
        } catch {
            self.logger.error("Failed to delete sessions: \(error.localizedDescription)")
        }
    }

    // MARK: - Audit Log

    /// Record a tool execution
    func recordToolExecution(
        toolName: String,
        action: String,
        category: AuditCategory,
        summary: String,
        parameters: [String: Any],
        userConfirmed: Bool,
        sessionID: UUID? = nil
    ) -> AuditLogEntryModel {
        let entry = AuditLogEntryModel(
            toolName: toolName,
            action: action,
            category: category.rawValue,
            summary: summary,
            userConfirmed: userConfirmed,
            sessionID: sessionID
        )
        entry.setParameters(parameters)

        context.insert(entry)
        self.saveContext()
        self.logger.debug("Recorded audit log: \(toolName).\(action)")
        return entry
    }

    /// Update audit log entry with result
    func updateAuditEntry(_ entry: AuditLogEntryModel, result: [String: Any], succeeded: Bool) {
        entry.setResult(result, succeeded: succeeded)
        self.saveContext()
    }

    /// Fetch recent audit log entries
    func recentAuditEntries(limit: Int = 100) -> [AuditLogEntryModel] {
        var descriptor = FetchDescriptor<AuditLogEntryModel>(
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        descriptor.fetchLimit = limit

        return (try? context.fetch(descriptor)) ?? []
    }

    /// Clear audit log
    func clearAuditLog() {
        do {
            try context.delete(model: AuditLogEntryModel.self)
            self.saveContext()
            self.logger.info("Cleared audit log")
        } catch {
            self.logger.error("Failed to clear audit log: \(error.localizedDescription)")
        }
    }

    // MARK: - App Settings

    /// Get or create app settings
    var settings: AppSettings {
        let descriptor = FetchDescriptor<AppSettings>()

        if let settings = try? context.fetch(descriptor).first {
            return settings
        }

        let settings = AppSettings()
        context.insert(settings)
        self.saveContext()
        return settings
    }

    /// Update settings
    func updateSettings(_ update: (AppSettings) -> Void) {
        let settings = self.settings
        update(settings)
        self.saveContext()
    }

    // MARK: - Helpers

    private func saveContext() {
        do {
            try context.save()
        } catch {
            self.logger.error("Failed to save context: \(error.localizedDescription)")
        }
    }
}
