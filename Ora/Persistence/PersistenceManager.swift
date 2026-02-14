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
    private static let defaultSaveDebounceInterval: Duration = .milliseconds(250)

    // MARK: - Properties

    private let logger = Logger(subsystem: "com.ora.app", category: "Persistence")
    private let saveDebounceInterval: Duration
    private let onContextSavedForTesting: (@MainActor () -> Void)?
    private var saveTask: Task<Void, Never>?
    private var saveTaskToken: UInt64 = 0

    let container: ModelContainer
    var context: ModelContext {
        container.mainContext
    }

    // MARK: - Initialization

    private init() {
        self.saveDebounceInterval = Self.defaultSaveDebounceInterval
        self.onContextSavedForTesting = nil

        let schema = Schema([
            Session.self,
            AuditLogEntryModel.self,
            AppSettings.self
        ])

        let storeURL = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Ora", isDirectory: true)
            .appendingPathComponent("default.store")

        let configuration = ModelConfiguration(
            schema: schema,
            url: storeURL,
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
    static func createForTesting(
        inMemory: Bool = true,
        storeURL: URL? = nil,
        saveDebounceInterval: Duration = PersistenceManager.defaultSaveDebounceInterval,
        onContextSaved: (@MainActor () -> Void)? = nil
    ) -> PersistenceManager {
        return PersistenceManager(
            inMemory: inMemory,
            storeURL: storeURL,
            saveDebounceInterval: saveDebounceInterval,
            onContextSaved: onContextSaved
        )
    }

    private init(
        inMemory: Bool,
        storeURL: URL? = nil,
        saveDebounceInterval: Duration = PersistenceManager.defaultSaveDebounceInterval,
        onContextSaved: (@MainActor () -> Void)? = nil
    ) {
        self.saveDebounceInterval = saveDebounceInterval
        self.onContextSavedForTesting = onContextSaved

        let schema = Schema([
            Session.self,
            AuditLogEntryModel.self,
            AppSettings.self
        ])

        let configuration: ModelConfiguration
        if inMemory {
            configuration = ModelConfiguration(
                schema: schema,
                isStoredInMemoryOnly: true,
                cloudKitDatabase: .none
            )
        } else if let storeURL {
            configuration = ModelConfiguration(
                schema: schema,
                url: storeURL,
                cloudKitDatabase: .none
            )
        } else {
            configuration = ModelConfiguration(
                schema: schema,
                isStoredInMemoryOnly: false,
                cloudKitDatabase: .none
            )
        }

        do {
            container = try ModelContainer(for: schema, configurations: [configuration])
            self.logger.info("SwiftData container initialized (in-memory: \(inMemory), custom-url: \(storeURL != nil))")
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

    /// Append a message to the current active session
    @discardableResult
    func appendMessage(
        role: Session.Message.Role,
        content: String,
        metadata: [String: String]? = nil
    ) -> Session {
        let session = self.currentSession()
        session.addMessage(role: role, content: content, metadata: metadata)
        self.saveContext()

        if let metadata, !metadata.isEmpty {
            self.logger.debug("Appended message to session \(session.id) (metadata keys: \(metadata.count))")
        } else {
            self.logger.debug("Appended message to session \(session.id)")
        }

        return session
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

    // MARK: - Cleanup (Memory Management)

    /// Clean up old data to prevent memory growth
    ///
    /// This should be called periodically to remove old audit entries and sessions.
    /// Default retention: 500 audit entries, sessions older than 30 days.
    ///
    /// - Parameters:
    ///   - maxAuditEntries: Maximum number of audit entries to keep (default: 500)
    ///   - sessionRetentionDays: Days to retain completed sessions (default: 30)
    /// - Returns: Count of deleted items (audit entries, sessions)
    @discardableResult
    func cleanupOldData(
        maxAuditEntries: Int = 500,
        sessionRetentionDays: Int = 30
    ) -> (auditEntriesDeleted: Int, sessionsDeleted: Int) {
        var auditDeleted = 0
        var sessionsDeleted = 0

        // Clean up audit entries beyond the limit
        do {
            let allEntriesDescriptor = FetchDescriptor<AuditLogEntryModel>(
                sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
            )
            let allEntries = try context.fetch(allEntriesDescriptor)

            if allEntries.count > maxAuditEntries {
                let entriesToDelete = Array(allEntries.dropFirst(maxAuditEntries))
                for entry in entriesToDelete {
                    context.delete(entry)
                    auditDeleted += 1
                }
                self.logger.info("Cleaned up \(auditDeleted) old audit entries")
            }
        } catch {
            self.logger.error("Failed to clean up audit entries: \(error.localizedDescription)")
        }

        // Clean up old completed sessions
        let cutoffDate = Calendar.current.date(byAdding: .day, value: -sessionRetentionDays, to: Date()) ?? Date()
        do {
            let oldSessionsDescriptor = FetchDescriptor<Session>(
                predicate: #Predicate { session in
                    session.isComplete && session.updatedAt < cutoffDate
                }
            )
            let oldSessions = try context.fetch(oldSessionsDescriptor)

            for session in oldSessions {
                context.delete(session)
                sessionsDeleted += 1
            }

            if sessionsDeleted > 0 {
                self.logger.info("Cleaned up \(sessionsDeleted) old sessions")
            }
        } catch {
            self.logger.error("Failed to clean up old sessions: \(error.localizedDescription)")
        }

        if auditDeleted > 0 || sessionsDeleted > 0 {
            self.saveContext()
        }

        return (auditDeleted, sessionsDeleted)
    }

    /// Reset the SwiftData context to release cached objects
    ///
    /// This clears the in-memory object graph, which can help reduce memory usage
    /// after processing many objects. Pending changes are lost.
    func resetContext() {
        context.rollback()
        self.logger.debug("Context reset (in-memory objects released)")
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

    /// Immediately persist any pending changes, cancelling a scheduled debounced save first.
    func flushSave() {
        self.saveTask?.cancel()
        self.saveTask = nil
        self.performSave()
    }

    // MARK: - Helpers

    private func saveContext() {
        self.saveTask?.cancel()
        self.saveTaskToken &+= 1
        let token = self.saveTaskToken
        let debounceInterval = self.saveDebounceInterval

        self.saveTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: debounceInterval)
            } catch {
                return
            }

            guard let self else {
                return
            }
            guard !Task.isCancelled, token == self.saveTaskToken else {
                return
            }

            self.performSave()
            self.saveTask = nil
        }
    }

    private func performSave() {
        guard self.context.hasChanges else {
            return
        }

        do {
            try self.context.save()
            self.onContextSavedForTesting?()
        } catch {
            self.logger.error("Failed to save context: \(error.localizedDescription)")
        }
    }
}
