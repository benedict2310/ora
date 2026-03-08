//
//  MemoryFileManagerTests.swift
//  OraTests
//
//  Tests for on-disk memory folder management.
//

import XCTest
@testable import Ora

final class MemoryFileManagerTests: XCTestCase {

    // MARK: - Properties

    private var temporaryDirectoryURL: URL!

    // MARK: - Setup

    override func setUpWithError() throws {
        self.temporaryDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: self.temporaryDirectoryURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let temporaryDirectoryURL = self.temporaryDirectoryURL {
            try? FileManager.default.removeItem(at: temporaryDirectoryURL)
        }
        self.temporaryDirectoryURL = nil
    }

    // MARK: - Tests

    func test_ensureMemoryStructureExists_missingStructure_createsDirectoriesAndTemplate() throws {
        // Given
        let memoryDirectory = self.temporaryDirectoryURL.appendingPathComponent("memory", isDirectory: true)
        let manager = MemoryFileManager(memoryDirectory: memoryDirectory)

        // When
        try manager.ensureMemoryStructureExists()

        // Then
        var isDirectory = ObjCBool(false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: manager.memoryDirectory.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)

        isDirectory = ObjCBool(false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: manager.summariesDirectory.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)

        XCTAssertTrue(FileManager.default.fileExists(atPath: manager.memoryFileURL.path))
        let content = try String(contentsOf: manager.memoryFileURL, encoding: .utf8)
        XCTAssertEqual(content, MemoryFileManager.initialMemoryTemplate)
    }

    func test_ensureMemoryStructureExists_existingTemplate_preservesUserEditsOnSecondCall() throws {
        // Given
        let memoryDirectory = self.temporaryDirectoryURL.appendingPathComponent("memory", isDirectory: true)
        let manager = MemoryFileManager(memoryDirectory: memoryDirectory)
        try manager.ensureMemoryStructureExists()
        let customContent = """
# Custom Memory

Favorite coffee: black
"""
        try customContent.write(to: manager.memoryFileURL, atomically: true, encoding: .utf8)

        // When
        try manager.ensureMemoryStructureExists()

        // Then
        let content = try String(contentsOf: manager.memoryFileURL, encoding: .utf8)
        XCTAssertTrue(content.contains("# Custom Memory"))
        XCTAssertTrue(content.contains("Favorite coffee: black"))
        XCTAssertTrue(content.contains("## Profile"))
        XCTAssertTrue(content.contains("## Preferences"))
        XCTAssertTrue(content.contains("## People"))
        XCTAssertTrue(content.contains("## Projects"))
        XCTAssertTrue(content.contains("## Ongoing Goals"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: manager.summariesDirectory.path))
    }

    func test_writeSummary_validSessionId_writesMarkdownFile() throws {
        // Given
        let memoryDirectory = self.temporaryDirectoryURL.appendingPathComponent("memory", isDirectory: true)
        let manager = MemoryFileManager(memoryDirectory: memoryDirectory)
        let sessionID = UUID()
        let content = "# Session Summary\n\n## TL;DR\nplaceholder"

        // When
        try manager.writeSummary(sessionId: sessionID, content: content)

        // Then
        let summaryFileURL = manager.summaryFileURL(for: sessionID)
        XCTAssertTrue(FileManager.default.fileExists(atPath: summaryFileURL.path))
        let writtenContent = try String(contentsOf: summaryFileURL, encoding: .utf8)
        XCTAssertEqual(writtenContent, content)
    }

    func test_writePlaceholderSummary_validSessionId_writesTemplateSections() throws {
        // Given
        let memoryDirectory = self.temporaryDirectoryURL.appendingPathComponent("memory", isDirectory: true)
        let manager = MemoryFileManager(memoryDirectory: memoryDirectory)
        let sessionID = UUID()

        // When
        try manager.writePlaceholderSummary(sessionId: sessionID)

        // Then
        let summaryFileURL = manager.summaryFileURL(for: sessionID)
        let writtenContent = try String(contentsOf: summaryFileURL, encoding: .utf8)
        XCTAssertTrue(writtenContent.contains("# Session Summary"))
        XCTAssertTrue(writtenContent.contains("## TL;DR"))
        XCTAssertTrue(writtenContent.contains("## Bullets"))
        XCTAssertTrue(writtenContent.contains("## Decisions & Commitments"))
        XCTAssertTrue(writtenContent.contains("## Open Loops"))
    }

    func test_appendEntries_existingContent_preservesExistingAndAppendsEntries() throws {
        // Given
        let memoryDirectory = self.temporaryDirectoryURL.appendingPathComponent("memory", isDirectory: true)
        let manager = MemoryFileManager(memoryDirectory: memoryDirectory)
        try manager.ensureMemoryStructureExists()

        let existingContent = """
# Ora Memory

Favorite coffee: black
"""
        try existingContent.write(to: manager.memoryFileURL, atomically: true, encoding: .utf8)

        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let sessionID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!

        let entries = [
            MemoryEntry(
                section: .preferences,
                tag: .preference,
                content: "Prefers morning meetings",
                sourceSessionID: sessionID,
                timestamp: timestamp
            ),
            MemoryEntry(
                section: .projects,
                tag: .fact,
                content: "Uses 25-minute focus blocks",
                sourceSessionID: sessionID,
                timestamp: timestamp
            )
        ]

        // When
        try manager.appendEntries(entries: entries)

        // Then
        let content = try String(contentsOf: manager.memoryFileURL, encoding: .utf8)
        XCTAssertTrue(content.contains("Favorite coffee: black"))
        XCTAssertTrue(content.contains("## Preferences"))
        XCTAssertTrue(content.contains("## Projects"))
        XCTAssertTrue(content.contains(sessionID.uuidString))
        XCTAssertTrue(content.contains("- [preference] Prefers morning meetings"))
        XCTAssertTrue(content.contains("- [fact] Uses 25-minute focus blocks"))
    }

    // MARK: - Fuzzy Dedup Tests

    func test_appendEntries_fuzzyDuplicate_isRejected() throws {
        // Given — existing entry "User sent a message to Alex"
        // New entry "User sent a message to Alex, which was delivered" should be deduped
        let memoryDirectory = self.temporaryDirectoryURL.appendingPathComponent("memory", isDirectory: true)
        let manager = MemoryFileManager(memoryDirectory: memoryDirectory)
        try manager.ensureMemoryStructureExists()

        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let sessionA = UUID()
        let sessionB = UUID()

        // First batch — establish baseline
        try manager.appendEntries(entries: [
            MemoryEntry(
                section: .people,
                tag: .fact,
                content: "User sent a message to Alex.",
                sourceSessionID: sessionA,
                timestamp: timestamp
            )
        ])

        // Second batch — near-duplicate should be rejected
        try manager.appendEntries(entries: [
            MemoryEntry(
                section: .people,
                tag: .fact,
                content: "User sent a message to Alex, which was successfully delivered.",
                sourceSessionID: sessionB,
                timestamp: timestamp
            )
        ])

        // Then
        let content = try String(contentsOf: manager.memoryFileURL, encoding: .utf8)
        let alexLines = content.components(separatedBy: .newlines).filter { $0.contains("message to Alex") }
        XCTAssertEqual(alexLines.count, 1, "Only one 'message to Alex' entry should exist, got: \(alexLines)")
    }

    func test_appendEntries_containmentDuplicate_isRejected() throws {
        // Given — existing entry is a substring of the new entry
        let memoryDirectory = self.temporaryDirectoryURL.appendingPathComponent("memory", isDirectory: true)
        let manager = MemoryFileManager(memoryDirectory: memoryDirectory)
        try manager.ensureMemoryStructureExists()

        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let sessionA = UUID()
        let sessionB = UUID()

        try manager.appendEntries(entries: [
            MemoryEntry(
                section: .projects,
                tag: .fact,
                content: "User scheduled a meeting.",
                sourceSessionID: sessionA,
                timestamp: timestamp
            )
        ])

        try manager.appendEntries(entries: [
            MemoryEntry(
                section: .projects,
                tag: .fact,
                content: "User scheduled a meeting during the ski vacation in Dorfgastein.",
                sourceSessionID: sessionB,
                timestamp: timestamp
            )
        ])

        // Then — the longer entry should be rejected because it contains the shorter one
        let content = try String(contentsOf: manager.memoryFileURL, encoding: .utf8)
        let meetingLines = content.components(separatedBy: .newlines).filter { $0.contains("scheduled a meeting") }
        XCTAssertEqual(meetingLines.count, 1, "Only one 'scheduled a meeting' entry should exist, got: \(meetingLines)")
    }

    func test_appendEntries_withNormalizedKey_stillRunsFuzzyDedup() throws {
        // Regression: entries with normalizedKey used to skip fuzzy dedup entirely,
        // allowing near-duplicates to accumulate across sessions.
        let memoryDirectory = self.temporaryDirectoryURL.appendingPathComponent("memory", isDirectory: true)
        let manager = MemoryFileManager(memoryDirectory: memoryDirectory)
        try manager.ensureMemoryStructureExists()

        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let sessionA = UUID()
        let sessionB = UUID()

        try manager.appendEntries(entries: [
            MemoryEntry(
                section: .people,
                tag: .fact,
                content: "User has a contact named Alex.",
                sourceSessionID: sessionA,
                timestamp: timestamp,
                normalizedKey: "alex_contact"
            )
        ])

        // New entry with DIFFERENT normalizedKey but semantically identical content
        try manager.appendEntries(entries: [
            MemoryEntry(
                section: .people,
                tag: .fact,
                content: "User has a contact named Alex.",
                sourceSessionID: sessionB,
                timestamp: timestamp,
                normalizedKey: "contact_alex"
            )
        ])

        // Then — should be deduped even though normalizedKeys differ
        let content = try String(contentsOf: manager.memoryFileURL, encoding: .utf8)
        let alexLines = content.components(separatedBy: .newlines).filter { $0.contains("contact named Alex") }
        XCTAssertEqual(alexLines.count, 1, "Only one 'contact named Alex' entry should exist, got: \(alexLines)")
    }

    func test_appendEntries_genuinelyDifferentEntries_arePreserved() throws {
        // Sanity check: entries that are genuinely different should not be deduped
        let memoryDirectory = self.temporaryDirectoryURL.appendingPathComponent("memory", isDirectory: true)
        let manager = MemoryFileManager(memoryDirectory: memoryDirectory)
        try manager.ensureMemoryStructureExists()

        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let sessionID = UUID()

        try manager.appendEntries(entries: [
            MemoryEntry(
                section: .profile,
                tag: .fact,
                content: "User's name is Benedict.",
                sourceSessionID: sessionID,
                timestamp: timestamp
            ),
            MemoryEntry(
                section: .people,
                tag: .fact,
                content: "Family members are Maddie and Sophia.",
                sourceSessionID: sessionID,
                timestamp: timestamp
            ),
            MemoryEntry(
                section: .preferences,
                tag: .preference,
                content: "Favorite sport is skiing.",
                sourceSessionID: sessionID,
                timestamp: timestamp
            )
        ])

        // Then — all three distinct entries should be preserved
        let content = try String(contentsOf: manager.memoryFileURL, encoding: .utf8)
        XCTAssertTrue(content.contains("Benedict"))
        XCTAssertTrue(content.contains("Maddie and Sophia"))
        XCTAssertTrue(content.contains("skiing"))
    }
}
