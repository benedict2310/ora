//
//  MemoryFileWatcherTests.swift
//  OraTests
//
//  Tests for MemoryFileWatcher file monitoring and debounce behavior.
//

import XCTest
@testable import Ora

final class MemoryFileWatcherTests: XCTestCase {

    private var temporaryDirectoryURL: URL!

    override func setUp() async throws {
        self.temporaryDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: self.temporaryDirectoryURL,
            withIntermediateDirectories: true
        )
    }

    override func tearDown() async throws {
        if let url = self.temporaryDirectoryURL {
            try? FileManager.default.removeItem(at: url)
        }
        self.temporaryDirectoryURL = nil
    }

    // MARK: - Tests

    func test_fileChange_triggersCallback() async throws {
        let fileURL = self.temporaryDirectoryURL.appendingPathComponent("MEMORY.md")
        try "initial".write(to: fileURL, atomically: true, encoding: .utf8)

        let expectation = XCTestExpectation(description: "onFileChanged called")
        let watcher = MemoryFileWatcher(
            fileURL: fileURL,
            debounceInterval: 0.1
        ) {
            expectation.fulfill()
        }

        await watcher.startWatching()

        // Simulate external edit
        try await Task.sleep(for: .milliseconds(50))
        try "updated content".write(to: fileURL, atomically: true, encoding: .utf8)

        await fulfillment(of: [expectation], timeout: 3.0)
        await watcher.stopWatching()
    }

    func test_rapidWrites_debounceIntoSingleCallback() async throws {
        let fileURL = self.temporaryDirectoryURL.appendingPathComponent("MEMORY.md")
        try "initial".write(to: fileURL, atomically: true, encoding: .utf8)

        let callCount = CallCounter()
        let expectation = XCTestExpectation(description: "onFileChanged called once")

        let watcher = MemoryFileWatcher(
            fileURL: fileURL,
            debounceInterval: 0.3
        ) {
            await callCount.increment()
            expectation.fulfill()
        }

        await watcher.startWatching()

        // Rapid writes within debounce window
        try await Task.sleep(for: .milliseconds(50))
        for i in 0..<5 {
            try "edit \(i)".write(to: fileURL, atomically: true, encoding: .utf8)
            try await Task.sleep(for: .milliseconds(30))
        }

        await fulfillment(of: [expectation], timeout: 3.0)

        // Wait a bit more to ensure no extra callbacks
        try await Task.sleep(for: .milliseconds(500))
        let count = await callCount.value
        XCTAssertEqual(count, 1, "Rapid writes should debounce into a single callback")

        await watcher.stopWatching()
    }

    func test_oraWriteFlag_suppressesCallback() async throws {
        let fileURL = self.temporaryDirectoryURL.appendingPathComponent("MEMORY.md")
        try "initial".write(to: fileURL, atomically: true, encoding: .utf8)

        let callCount = CallCounter()

        let watcher = MemoryFileWatcher(
            fileURL: fileURL,
            debounceInterval: 0.1
        ) {
            await callCount.increment()
        }

        await watcher.startWatching()

        // Mark write-in-progress before editing
        await watcher.beginOraWrite()
        try await Task.sleep(for: .milliseconds(50))
        try "ora writes this".write(to: fileURL, atomically: true, encoding: .utf8)

        // Wait for debounce to expire
        try await Task.sleep(for: .milliseconds(500))

        let count = await callCount.value
        XCTAssertEqual(count, 0, "Callback should be suppressed during Ora writes")

        await watcher.endOraWrite()
        await watcher.stopWatching()
    }

    func test_atomicWrites_continueToBeDetectedAfterReopen() async throws {
        let fileURL = self.temporaryDirectoryURL.appendingPathComponent("MEMORY.md")
        try "initial".write(to: fileURL, atomically: true, encoding: .utf8)

        let callCount = CallCounter()
        let firstExpectation = XCTestExpectation(description: "first callback")
        let secondExpectation = XCTestExpectation(description: "second callback")

        let watcher = MemoryFileWatcher(
            fileURL: fileURL,
            debounceInterval: 0.1
        ) {
            let count = await callCount.increment()
            if count == 1 {
                firstExpectation.fulfill()
            } else if count == 2 {
                secondExpectation.fulfill()
            }
        }

        await watcher.startWatching()

        // First atomic write (triggers rename, invalidating old FD)
        try await Task.sleep(for: .milliseconds(50))
        try "first edit".write(to: fileURL, atomically: true, encoding: .utf8)

        await fulfillment(of: [firstExpectation], timeout: 3.0)

        // Second atomic write — verifies FD was re-opened after rename
        try await Task.sleep(for: .milliseconds(300))
        try "second edit".write(to: fileURL, atomically: true, encoding: .utf8)

        await fulfillment(of: [secondExpectation], timeout: 3.0)

        let count = await callCount.value
        XCTAssertEqual(count, 2, "Both atomic writes should be detected after FD reopen")

        await watcher.stopWatching()
    }

    func test_stopWatching_preventsCallbacks() async throws {
        let fileURL = self.temporaryDirectoryURL.appendingPathComponent("MEMORY.md")
        try "initial".write(to: fileURL, atomically: true, encoding: .utf8)

        let callCount = CallCounter()

        let watcher = MemoryFileWatcher(
            fileURL: fileURL,
            debounceInterval: 0.1
        ) {
            await callCount.increment()
        }

        await watcher.startWatching()
        await watcher.stopWatching()

        try await Task.sleep(for: .milliseconds(50))
        try "after stop".write(to: fileURL, atomically: true, encoding: .utf8)

        try await Task.sleep(for: .milliseconds(500))

        let count = await callCount.value
        XCTAssertEqual(count, 0, "No callbacks after stopWatching")
    }
}

// MARK: - Helpers

private actor CallCounter {
    var value = 0

    @discardableResult
    func increment() -> Int {
        self.value += 1
        return self.value
    }
}
