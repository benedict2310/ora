//
//  TranscriptMigrationTests.swift
//  OraTests
//
//  Tests for transcript storage migration from blob to relationship model.
//

import XCTest
import SwiftData
@testable import Ora

@MainActor
final class TranscriptMigrationTests: XCTestCase {

    private var persistence: PersistenceManager!

    override func setUp() async throws {
        await MainActor.run {
            self.persistence = PersistenceManager.createForTesting(inMemory: true)
        }
    }

    override func tearDown() async throws {
        self.persistence = nil
    }

    // MARK: - MessageModel Tests

    func test_messageModel_roundTripsCorrectly() {
        let original = Session.Message(
            id: UUID(),
            role: .user,
            content: "Hello world",
            timestamp: Date(),
            metadata: ["key": "value"]
        )

        let model = MessageModel.from(original)
        let roundTripped = model.toMessage()

        XCTAssertEqual(roundTripped.id, original.id)
        XCTAssertEqual(roundTripped.role, original.role)
        XCTAssertEqual(roundTripped.content, original.content)
        XCTAssertEqual(roundTripped.metadata?["key"], "value")
    }

    func test_messageModel_handlesNilMetadata() {
        let original = Session.Message(
            id: UUID(),
            role: .assistant,
            content: "Response",
            timestamp: Date(),
            metadata: nil
        )

        let model = MessageModel.from(original)
        let roundTripped = model.toMessage()

        XCTAssertEqual(roundTripped.content, "Response")
        XCTAssertNil(roundTripped.metadata)
    }

    // MARK: - New Session Tests (Relationship Storage)

    func test_newSession_usesRelationshipStorage() {
        let session = self.persistence.createSession()
        XCTAssertTrue(session.isMigrated, "New sessions should be flagged as migrated")

        session.addMessage(role: .user, content: "test")
        self.persistence.flushSave()

        let messages = session.messages
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages.first?.content, "test")
    }

    func test_newSession_storesViaRelationship() {
        let session = self.persistence.createSession()
        session.addMessage(role: .user, content: "msg1")
        session.addMessage(role: .assistant, content: "msg2")
        self.persistence.flushSave()

        // Verify messages accessible
        let messages = session.messages
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[0].role, .user)
        XCTAssertEqual(messages[1].role, .assistant)
    }

    // MARK: - Migration Tests

    func test_migrateSession_convertsBlob() {
        // Create a session with blob-style storage
        let session = Session()
        session.isMigrated = false
        self.persistence.context.insert(session)

        // Write messages directly to messagesData (simulating old format)
        let blobMessages: [Session.Message] = [
            Session.Message(id: UUID(), role: .user, content: "old message 1", timestamp: Date(), metadata: nil),
            Session.Message(id: UUID(), role: .assistant, content: "old response", timestamp: Date(), metadata: ["tool": "calendar"])
        ]
        session.messagesData = try? JSONEncoder().encode(blobMessages)
        self.persistence.flushSave()

        // Verify blob is readable pre-migration
        XCTAssertEqual(session.messages.count, 2)
        XCTAssertFalse(session.isMigrated)

        // Migrate
        let count = session.migrateToRelationshipStorage()
        XCTAssertEqual(count, 2)
        XCTAssertTrue(session.isMigrated)

        // Verify messages are now from relationship
        let postMigrationMessages = session.messages
        XCTAssertEqual(postMigrationMessages.count, 2)
        XCTAssertEqual(postMigrationMessages[0].content, "old message 1")
        XCTAssertEqual(postMigrationMessages[1].metadata?["tool"], "calendar")
    }

    func test_migrateSession_alreadyMigrated_returnsZero() {
        let session = self.persistence.createSession()
        session.addMessage(role: .user, content: "already migrated")
        self.persistence.flushSave()

        let count = session.migrateToRelationshipStorage()
        XCTAssertEqual(count, 0, "Already migrated session should return 0")
    }

    func test_migrateSession_emptyBlob_flagsMigrated() {
        let session = Session()
        session.isMigrated = false
        self.persistence.context.insert(session)
        self.persistence.flushSave()

        let count = session.migrateToRelationshipStorage()
        XCTAssertEqual(count, 0)
        XCTAssertTrue(session.isMigrated)
    }

    func test_migrateSessionsToRelationshipStorage_migratesBatch() {
        // Create multiple unmigrated sessions
        for i in 0..<3 {
            let session = Session()
            session.isMigrated = false
            self.persistence.context.insert(session)

            let messages = [
                Session.Message(id: UUID(), role: .user, content: "msg \(i)", timestamp: Date(), metadata: nil)
            ]
            session.messagesData = try? JSONEncoder().encode(messages)
        }
        self.persistence.flushSave()

        // Run bulk migration
        let total = self.persistence.migrateSessionsToRelationshipStorage()
        XCTAssertEqual(total, 3, "Should migrate 3 messages (1 per session)")
    }

    // MARK: - Backward Compatibility

    func test_unmigrated_session_readsFromBlob() {
        let session = Session()
        session.isMigrated = false
        self.persistence.context.insert(session)

        let messages = [
            Session.Message(id: UUID(), role: .user, content: "blob content", timestamp: Date(), metadata: nil)
        ]
        session.messagesData = try? JSONEncoder().encode(messages)
        self.persistence.flushSave()

        // Messages should still be readable from blob
        let retrieved = session.messages
        XCTAssertEqual(retrieved.count, 1)
        XCTAssertEqual(retrieved.first?.content, "blob content")
    }

    func test_messagesAPI_unchangedForConsumers() {
        let session = self.persistence.createSession()

        // Use the same API as always
        session.addMessage(role: .user, content: "hello")
        session.addMessage(role: .assistant, content: "hi there")
        session.addMessage(role: .tool, content: "[ToolResult: calendar] Done")

        let messages = session.messages
        XCTAssertEqual(messages.count, 3)
        XCTAssertEqual(messages[0].role, .user)
        XCTAssertEqual(messages[1].role, .assistant)
        XCTAssertEqual(messages[2].role, .tool)
    }
}
