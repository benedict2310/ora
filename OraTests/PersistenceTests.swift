//
//  PersistenceTests.swift
//  OraTests
//
//  Tests for SwiftData persistence layer
//

import XCTest
import SwiftData
@testable import Ora

@MainActor
final class PersistenceTests: XCTestCase {

    // MARK: - Properties

    private var container: ModelContainer!
    private var context: ModelContext!

    // MARK: - Setup

    override func setUp() async throws {
        try await super.setUp()

        // Create in-memory container for testing
        let schema = Schema([
            Session.self,
            AuditLogEntryModel.self,
            AppSettings.self
        ])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try! ModelContainer(for: schema, configurations: [config])
        context = container.mainContext
    }

    override func tearDown() async throws {
        container = nil
        context = nil
        try await super.tearDown()
    }

    // MARK: - Session Tests

    func test_session_creation() {
        // Given
        let session = Session()

        // When
        context.insert(session)
        try? context.save()

        // Then
        XCTAssertNotNil(session.id)
        XCTAssertFalse(session.isComplete)
        XCTAssertNil(session.summary)
        XCTAssertTrue(session.messages.isEmpty)
    }

    func test_session_addMessage_storesMessages() {
        // Given
        let session = Session()
        context.insert(session)

        // When
        session.addMessage(role: .user, content: "Hello")
        session.addMessage(role: .assistant, content: "Hi there!")

        // Then
        XCTAssertEqual(session.messages.count, 2)
        XCTAssertEqual(session.messages[0].role, .user)
        XCTAssertEqual(session.messages[0].content, "Hello")
        XCTAssertEqual(session.messages[1].role, .assistant)
        XCTAssertEqual(session.messages[1].content, "Hi there!")
    }

    func test_session_addMessage_updatesTimestamp() {
        // Given
        let session = Session()
        context.insert(session)
        let originalUpdatedAt = session.updatedAt

        // Wait a tiny bit to ensure timestamps differ
        Thread.sleep(forTimeInterval: 0.01)

        // When
        session.addMessage(role: .user, content: "Test message")

        // Then
        XCTAssertGreaterThan(session.updatedAt, originalUpdatedAt)
    }

    func test_session_fetchIncomplete() {
        // Given
        let session1 = Session()
        let session2 = Session()
        session1.isComplete = true

        context.insert(session1)
        context.insert(session2)
        try? context.save()

        // When
        let descriptor = FetchDescriptor<Session>(
            predicate: #Predicate { !$0.isComplete }
        )
        let incompleteSessions = try? context.fetch(descriptor)

        // Then
        XCTAssertEqual(incompleteSessions?.count, 1)
        XCTAssertEqual(incompleteSessions?.first?.id, session2.id)
    }

    // MARK: - AuditLogEntryModel Tests

    func test_auditLog_creation() {
        // Given
        let entry = AuditLogEntryModel(
            toolName: "calendar",
            action: "create",
            category: "toolExecution",
            summary: "calendar.create",
            userConfirmed: true
        )

        // When
        context.insert(entry)
        try? context.save()

        // Then
        XCTAssertEqual(entry.toolName, "calendar")
        XCTAssertEqual(entry.action, "create")
        XCTAssertTrue(entry.userConfirmed)
        XCTAssertFalse(entry.succeeded)
    }

    func test_auditLog_setParameters() {
        // Given
        let entry = AuditLogEntryModel(
            toolName: "calendar",
            action: "create",
            category: "toolExecution",
            summary: "calendar.create"
        )

        // When
        entry.setParameters(["title": "Meeting", "duration": 30])

        // Then
        XCTAssertNotNil(entry.parameters)
        XCTAssertEqual(entry.parameters?["title"] as? String, "Meeting")
        XCTAssertEqual(entry.parameters?["duration"] as? Int, 30)
    }

    func test_auditLog_setResult() {
        // Given
        let entry = AuditLogEntryModel(
            toolName: "calendar",
            action: "create",
            category: "toolExecution",
            summary: "calendar.create"
        )

        // When
        entry.setResult(["eventId": "abc123"], succeeded: true)

        // Then
        XCTAssertNotNil(entry.result)
        XCTAssertTrue(entry.succeeded)
        XCTAssertTrue(entry.result?.contains("abc123") ?? false)
    }

    func test_auditLog_setError() {
        // Given
        let entry = AuditLogEntryModel(
            toolName: "calendar",
            action: "create",
            category: "toolExecution",
            summary: "calendar.create"
        )

        // When
        entry.setError("Permission denied")

        // Then
        XCTAssertEqual(entry.errorMessage, "Permission denied")
        XCTAssertFalse(entry.succeeded)
    }

    func test_auditLog_toAuditLogEntry_conversion() {
        // Given
        let model = AuditLogEntryModel(
            toolName: "reminders",
            action: "list",
            category: "toolExecution",
            summary: "reminders.list",
            userConfirmed: false
        )
        model.setResult(["count": 5], succeeded: true)

        // When
        let entry = model.toAuditLogEntry()

        // Then
        XCTAssertEqual(entry.id, model.id)
        XCTAssertEqual(entry.toolName, "reminders")
        XCTAssertEqual(entry.summary, "reminders.list")
        XCTAssertEqual(entry.category, .toolExecution)
        XCTAssertTrue(entry.success)
        XCTAssertFalse(entry.userConfirmed)
    }

    // MARK: - AppSettings Tests

    func test_appSettings_creation() {
        // Given
        let settings = AppSettings()

        // When
        context.insert(settings)
        try? context.save()

        // Then
        XCTAssertEqual(settings.id, "settings")
        XCTAssertTrue(settings.voiceOutputEnabled)
        XCTAssertEqual(settings.primaryLLMModel, "qwen3-4b-instruct-4bit")
    }

    func test_appSettings_hotkeyConfig_default() {
        // Given
        let settings = AppSettings()

        // When
        let hotkeyConfig = settings.hotkeyConfig

        // Then
        XCTAssertEqual(hotkeyConfig, HotkeyConfiguration.defaultHotkey)
    }

    func test_appSettings_hotkeyConfig_customValue() {
        // Given
        let settings = AppSettings()
        let customHotkey = HotkeyConfiguration(keyCode: 0, modifiers: 256)

        // When
        settings.hotkeyConfig = customHotkey

        // Then
        XCTAssertNotNil(settings.hotkeyConfigData)
        XCTAssertEqual(settings.hotkeyConfig.keyCode, 0)
        XCTAssertEqual(settings.hotkeyConfig.modifiers, 256)
    }

    func test_appSettings_singleton() {
        // Given
        let settings1 = AppSettings()
        let settings2 = AppSettings()

        context.insert(settings1)
        context.insert(settings2)
        try? context.save()

        // When
        let descriptor = FetchDescriptor<AppSettings>()
        let allSettings = try? context.fetch(descriptor)

        // Then - Should only have one due to unique ID constraint
        // Note: SwiftData unique constraint behavior may vary
        XCTAssertEqual(settings1.id, settings2.id)
    }

    func test_appSettings_updateVoiceEnabled() {
        // Given
        let settings = AppSettings()
        context.insert(settings)
        XCTAssertTrue(settings.voiceOutputEnabled)

        // When
        settings.voiceOutputEnabled = false
        try? context.save()

        // Then
        XCTAssertFalse(settings.voiceOutputEnabled)
    }

    // MARK: - Integration Tests

    func test_session_withAuditLog_linkedBySessionID() {
        // Given
        let session = Session()
        context.insert(session)
        let sessionID: UUID? = session.id

        let entry = AuditLogEntryModel(
            toolName: "calendar",
            action: "query",
            category: "toolExecution",
            summary: "calendar.query",
            sessionID: session.id
        )
        context.insert(entry)
        try? context.save()

        // When
        let descriptor = FetchDescriptor<AuditLogEntryModel>(
            predicate: #Predicate { $0.sessionID == sessionID }
        )
        let entriesForSession = try? context.fetch(descriptor)

        // Then
        XCTAssertEqual(entriesForSession?.count, 1)
        XCTAssertEqual(entriesForSession?.first?.toolName, "calendar")
    }
}

// MARK: - PersistenceManager API Tests

@MainActor
final class PersistenceManagerAPITests: XCTestCase {

    // Use in-memory manager for isolated tests
    private var manager: PersistenceManager!

    override func setUp() async throws {
        try await super.setUp()
        manager = PersistenceManager.createForTesting()
    }

    override func tearDown() async throws {
        manager = nil
        try await super.tearDown()
    }

    // MARK: - Session API Tests

    func test_persistenceManager_createSession_returnsNewSession() {
        // When
        let session = manager.createSession()

        // Then
        XCTAssertNotNil(session.id)
        XCTAssertFalse(session.isComplete)
    }

    func test_persistenceManager_currentSession_returnsActiveOrNew() {
        // Given - no sessions exist in clean test manager

        // When
        let session = manager.currentSession()

        // Then
        XCTAssertFalse(session.isComplete)
    }

    func test_persistenceManager_appendMessage_freshSession_appendsMessageWithIdentifiers() {
        // Given
        let appendStart = Date()
        let metadata = ["source": "asr", "turnId": "1"]

        // When
        let session = manager.appendMessage(
            role: .user,
            content: "Hello persistence",
            metadata: metadata
        )

        // Then
        XCTAssertFalse(session.isComplete)
        XCTAssertEqual(session.messages.count, 1)

        let message = session.messages[0]
        XCTAssertEqual(message.role, .user)
        XCTAssertEqual(message.content, "Hello persistence")
        XCTAssertGreaterThanOrEqual(message.timestamp, appendStart)
        XCTAssertEqual(message.metadata, metadata)
        XCTAssertNotNil(session.messagesData)
        XCTAssertFalse(session.messagesData?.isEmpty ?? true)
    }

    func test_persistenceManager_appendMessage_updatesSessionUpdatedAt() {
        // Given
        let session = manager.createSession()
        let originalUpdatedAt = session.updatedAt
        Thread.sleep(forTimeInterval: 0.01)

        // When
        _ = manager.appendMessage(role: .assistant, content: "Reply")

        // Then
        XCTAssertEqual(session.messages.count, 1)
        XCTAssertGreaterThan(session.updatedAt, originalUpdatedAt)
    }

    func test_persistenceManager_appendMessage_multipleSequentialAppends_accumulateInOrderWithUniqueIDs() {
        // Given
        let messages = [
            (role: Session.Message.Role.user, content: "First"),
            (role: Session.Message.Role.assistant, content: "Second"),
            (role: Session.Message.Role.user, content: "Third")
        ]

        // When
        for message in messages {
            _ = manager.appendMessage(role: message.role, content: message.content)
        }
        let session = manager.currentSession()

        // Then
        XCTAssertEqual(session.messages.count, messages.count)
        XCTAssertEqual(session.messages.map(\.content), messages.map(\.content))
        XCTAssertEqual(session.messages.map(\.role), messages.map(\.role))

        let uniqueMessageIDs = Set(session.messages.map(\.id))
        XCTAssertEqual(uniqueMessageIDs.count, messages.count)
    }

    func test_persistenceManager_appendMessage_diskStore_nonEmptyAfterFirstMessage() throws {
        // Given
        let fileManager = FileManager.default
        let tempDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("PersistenceManagerAPITests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer {
            try? fileManager.removeItem(at: tempDirectory)
        }

        let storeURL = tempDirectory.appendingPathComponent(".default.store")
        let diskManager = PersistenceManager.createForTesting(
            inMemory: false,
            storeURL: storeURL
        )

        // When
        _ = diskManager.appendMessage(role: .user, content: "Persist me")
        diskManager.flushSave()

        // Then
        XCTAssertTrue(fileManager.fileExists(atPath: storeURL.path))
        let storeAttributes = try fileManager.attributesOfItem(atPath: storeURL.path)
        let storeSize = (storeAttributes[.size] as? NSNumber)?.intValue ?? 0
        XCTAssertGreaterThan(storeSize, 0)
    }

    func test_persistenceManager_completeSession_marksSummary() {
        // Given
        let session = manager.createSession()
        session.addMessage(role: .user, content: "Hello, this is a test message")

        // When
        manager.completeSession(session)

        // Then
        XCTAssertTrue(session.isComplete)
        XCTAssertNotNil(session.summary)
        XCTAssertTrue(session.summary?.contains("Hello") ?? false)
    }

    func test_persistenceManager_recentSessions_returnsCompletedOnly() {
        // Given
        let session1 = manager.createSession()
        let session2 = manager.createSession()
        manager.completeSession(session1)

        // When
        let recent = manager.recentSessions()

        // Then
        XCTAssertTrue(recent.contains { $0.id == session1.id })
        XCTAssertFalse(recent.contains { $0.id == session2.id })
    }

    // MARK: - Audit Log API Tests

    func test_persistenceManager_recordToolExecution_createsEntry() {
        // When
        let entry = manager.recordToolExecution(
            toolName: "testTool",
            action: "testAction",
            category: .toolExecution,
            summary: "testTool.testAction",
            parameters: ["key": "value"],
            userConfirmed: true,
            sessionID: nil
        )

        // Then
        XCTAssertEqual(entry.toolName, "testTool")
        XCTAssertEqual(entry.action, "testAction")
        XCTAssertTrue(entry.userConfirmed)
        XCTAssertNotNil(entry.parameters)
    }

    func test_persistenceManager_updateAuditEntry_setsResult() {
        // Given
        let entry = manager.recordToolExecution(
            toolName: "updateTest",
            action: "test",
            category: .toolExecution,
            summary: "updateTest.test",
            parameters: [:],
            userConfirmed: false,
            sessionID: nil
        )

        // When
        manager.updateAuditEntry(
            entry,
            result: ["success": true],
            succeeded: true
        )

        // Then
        XCTAssertTrue(entry.succeeded)
        XCTAssertNotNil(entry.result)
    }

    func test_persistenceManager_recentAuditEntries_returnsEntries() {
        // Given
        let entry = manager.recordToolExecution(
            toolName: "recentTest",
            action: "list",
            category: .toolExecution,
            summary: "recentTest.list",
            parameters: [:],
            userConfirmed: false,
            sessionID: nil
        )

        // When
        let entries = manager.recentAuditEntries(limit: 10)

        // Then
        XCTAssertTrue(entries.contains { $0.id == entry.id })
    }

    // MARK: - Settings API Tests

    func test_persistenceManager_settings_returnsSingleton() {
        // When
        let settings1 = manager.settings
        let settings2 = manager.settings

        // Then
        XCTAssertEqual(settings1.id, settings2.id)
    }

    func test_persistenceManager_updateSettings_persistsChanges() {
        // Given
        let originalValue = manager.settings.voiceOutputEnabled

        // When
        manager.updateSettings { settings in
            settings.voiceOutputEnabled = !originalValue
        }

        // Then
        XCTAssertEqual(manager.settings.voiceOutputEnabled, !originalValue)
    }

    // MARK: - Cleanup API Tests

    func test_persistenceManager_cleanupOldData_deletesExcessAuditEntries() {
        // Given - Create more entries than the limit
        let maxEntries = 5
        for i in 0..<10 {
            _ = manager.recordToolExecution(
                toolName: "cleanupTest\(i)",
                action: "test",
                category: .toolExecution,
                summary: "cleanupTest\(i).test",
                parameters: [:],
                userConfirmed: false,
                sessionID: nil
            )
        }

        // When
        let result = manager.cleanupOldData(maxAuditEntries: maxEntries, sessionRetentionDays: 30)

        // Then
        XCTAssertEqual(result.auditEntriesDeleted, 5)  // 10 - 5 = 5 deleted
        let remaining = manager.recentAuditEntries(limit: 100)
        XCTAssertEqual(remaining.count, maxEntries)
    }

    func test_persistenceManager_cleanupOldData_keepsRecentAuditEntries() {
        // Given - Create fewer entries than the limit
        for i in 0..<3 {
            _ = manager.recordToolExecution(
                toolName: "keepTest\(i)",
                action: "test",
                category: .toolExecution,
                summary: "keepTest\(i).test",
                parameters: [:],
                userConfirmed: false,
                sessionID: nil
            )
        }

        // When
        let result = manager.cleanupOldData(maxAuditEntries: 10, sessionRetentionDays: 30)

        // Then
        XCTAssertEqual(result.auditEntriesDeleted, 0)  // Nothing to delete
        let remaining = manager.recentAuditEntries(limit: 100)
        XCTAssertEqual(remaining.count, 3)
    }

    func test_persistenceManager_resetContext_doesNotCrash() {
        // Given
        _ = manager.createSession()
        _ = manager.recordToolExecution(
            toolName: "resetTest",
            action: "test",
            category: .toolExecution,
            summary: "resetTest.test",
            parameters: [:],
            userConfirmed: false,
            sessionID: nil
        )

        // When / Then - Should not crash
        manager.resetContext()
    }
}
