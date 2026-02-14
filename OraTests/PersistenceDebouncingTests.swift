import Foundation
import XCTest
@testable import Ora

@MainActor
final class PersistenceDebouncingTests: XCTestCase {

    // MARK: - Debounced Save Scheduling

    func test_persistenceManager_appendMessage_rapidAppends_triggerSingleDebouncedSave() async throws {
        // Given
        let saveObserver = SaveObserver()
        let manager = PersistenceManager.createForTesting(
            saveDebounceInterval: .milliseconds(250),
            onContextSaved: {
                saveObserver.recordSave()
            }
        )

        // When
        for index in 0..<5 {
            _ = manager.appendMessage(role: .user, content: "Message \(index)")
        }
        try await Task.sleep(for: .milliseconds(700))

        // Then
        XCTAssertEqual(saveObserver.saveCount, 1)
    }

    func test_persistenceManager_flushSave_pendingDebounce_forcesImmediateSave() async throws {
        // Given
        let saveObserver = SaveObserver()
        let manager = PersistenceManager.createForTesting(
            saveDebounceInterval: .seconds(5),
            onContextSaved: {
                saveObserver.recordSave()
            }
        )
        _ = manager.appendMessage(role: .assistant, content: "Pending")

        // When
        manager.flushSave()
        try await Task.sleep(for: .milliseconds(300))

        // Then
        XCTAssertEqual(saveObserver.saveCount, 1)
    }

    func test_persistenceManager_flushSave_diskStore_reloadsLatestMessage() throws {
        // Given
        let fileManager = FileManager.default
        let tempDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("PersistenceDebouncingTests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer {
            try? fileManager.removeItem(at: tempDirectory)
        }

        let storeURL = tempDirectory.appendingPathComponent("default.store")
        let writer = PersistenceManager.createForTesting(
            inMemory: false,
            storeURL: storeURL,
            saveDebounceInterval: .seconds(5)
        )

        // When
        _ = writer.appendMessage(role: .user, content: "Persist before terminate")
        writer.flushSave()

        let reader = PersistenceManager.createForTesting(
            inMemory: false,
            storeURL: storeURL,
            saveDebounceInterval: .seconds(5)
        )
        let session = reader.currentSession()

        // Then
        XCTAssertEqual(session.messages.count, 1)
        XCTAssertEqual(session.messages.first?.content, "Persist before terminate")
    }
}

@MainActor
private final class SaveObserver {

    // MARK: - Properties

    private(set) var saveCount: Int = 0

    // MARK: - API

    func recordSave() {
        self.saveCount += 1
    }
}
