//
//  TranscriptMigrationTests.swift
//  OraTests
//
//  Tests for transcript storage in blob model.
//

import XCTest
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

    func test_messages_roundTripThroughBlobStorage() {
        let session = self.persistence.createSession()

        let messages: [Session.Message] = [
            Session.Message(id: UUID(), role: .user, content: "hello", timestamp: Date(), metadata: ["source": "asr"]),
            Session.Message(id: UUID(), role: .assistant, content: "hi", timestamp: Date(), metadata: nil)
        ]

        session.messages = messages
        self.persistence.flushSave()

        let reloaded = session.messages
        XCTAssertEqual(reloaded.count, 2)
        XCTAssertEqual(reloaded[0].content, "hello")
        XCTAssertEqual(reloaded[0].metadata?["source"], "asr")
        XCTAssertEqual(reloaded[1].content, "hi")
    }

    func test_addMessage_appendsInOrder() {
        let session = self.persistence.createSession()

        session.addMessage(role: .user, content: "first")
        session.addMessage(role: .assistant, content: "second")
        session.addMessage(role: .tool, content: "third")

        let messages = session.messages
        XCTAssertEqual(messages.map(\.content), ["first", "second", "third"])
        XCTAssertEqual(messages.map(\.role), [.user, .assistant, .tool])
    }

    func test_messagesSetter_overwritesExistingBlobMessages() {
        let session = self.persistence.createSession()
        session.addMessage(role: .user, content: "old")

        let replacement = Session.Message(
            id: UUID(),
            role: .assistant,
            content: "new",
            timestamp: Date(),
            metadata: ["reason": "overwrite"]
        )
        session.messages = [replacement]

        let messages = session.messages
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages.first?.content, "new")
        XCTAssertEqual(messages.first?.metadata?["reason"], "overwrite")
    }

    func test_invalidBlobPayload_fallsBackToEmptyMessages() {
        let session = self.persistence.createSession()
        session.messagesData = Data("not-json".utf8)

        XCTAssertTrue(session.messages.isEmpty)
    }

    func test_newSession_blobStorageBacked() {
        let session = self.persistence.createSession()
        XCTAssertNil(session.messagesData)

        session.addMessage(role: .user, content: "persist")

        XCTAssertNotNil(session.messagesData)
        XCTAssertEqual(session.messages.count, 1)
    }
}
