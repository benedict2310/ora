//
//  MemoryUpdatePolicyTests.swift
//  OraTests
//
//  Tests for MEMORY.md sectioned append policy and deduplication.
//

import XCTest
@testable import Ora

final class MemoryUpdatePolicyTests: XCTestCase {

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

    func test_appendEntries_missingSections_appendsToCorrectSectionAndCreatesRequiredSections() throws {
        // Given
        let manager = self.makeManager()
        try manager.ensureMemoryStructureExists()

        let customMemory = """
# Ora Memory

Custom user line
"""
        try customMemory.write(to: manager.memoryFileURL, atomically: true, encoding: .utf8)

        let sessionID = UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!
        let timestamp = Date(timeIntervalSince1970: 1_739_800_000)
        let entries = [
            MemoryEntry(
                section: .preferences,
                tag: .preference,
                content: "Likes short standups",
                sourceSessionID: sessionID,
                timestamp: timestamp,
                normalizedKey: "pref:meeting:short-standup"
            ),
            MemoryEntry(
                section: .people,
                tag: .fact,
                content: "Maddie is a product designer",
                sourceSessionID: sessionID,
                timestamp: timestamp
            )
        ]

        // When
        try manager.appendEntries(entries: entries)

        // Then
        let content = try String(contentsOf: manager.memoryFileURL, encoding: .utf8)
        XCTAssertTrue(content.contains("Custom user line"))
        XCTAssertTrue(content.contains("## Profile"))
        XCTAssertTrue(content.contains("## Preferences"))
        XCTAssertTrue(content.contains("## People"))
        XCTAssertTrue(content.contains("## Projects"))
        XCTAssertTrue(content.contains("## Ongoing Goals"))
        XCTAssertTrue(content.contains("- [preference] Likes short standups (source: \(sessionID.uuidString) @ 2025-02-17T13:46:40Z)"))
        XCTAssertTrue(content.contains("- [fact] Maddie is a product designer (source: \(sessionID.uuidString) @ 2025-02-17T13:46:40Z)"))
        XCTAssertTrue(self.entryLineAppearsInsideSection(
            content: content,
            sectionHeading: "## Preferences",
            entryPrefix: "- [preference] Likes short standups"
        ))
        XCTAssertTrue(self.entryLineAppearsInsideSection(
            content: content,
            sectionHeading: "## People",
            entryPrefix: "- [fact] Maddie is a product designer"
        ))
    }

    func test_appendEntries_duplicateFacts_existingEntryPreventsSecondInsert() throws {
        // Given
        let manager = self.makeManager()
        try manager.ensureMemoryStructureExists()

        let firstSessionID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let secondSessionID = UUID(uuidString: "66666666-7777-8888-9999-000000000000")!
        let first = MemoryEntry(
            section: .projects,
            tag: .fact,
            content: "Building Ora memory manager",
            sourceSessionID: firstSessionID,
            timestamp: Date(timeIntervalSince1970: 1_739_800_000),
            normalizedKey: "proj:ora:memory-manager"
        )
        let duplicate = MemoryEntry(
            section: .projects,
            tag: .fact,
            content: "Building Ora memory manager",
            sourceSessionID: secondSessionID,
            timestamp: Date(timeIntervalSince1970: 1_739_900_000),
            normalizedKey: "proj:ora:memory-manager"
        )

        // When
        try manager.appendEntries(entries: [first, duplicate])
        try manager.appendEntries(entries: [duplicate])

        // Then
        let content = try String(contentsOf: manager.memoryFileURL, encoding: .utf8)
        XCTAssertEqual(self.occurrenceCount(of: "- [fact] Building Ora memory manager (source:", in: content), 1)
    }

    func test_appendEntries_userCustomLines_existingLinesRemainAfterAppend() throws {
        // Given
        let manager = self.makeManager()
        try manager.ensureMemoryStructureExists()

        let customMemory = """
# Ora Memory

## Profile

- User custom profile line

## Preferences

Keep this exact line

## People

## Projects

## Ongoing Goals
"""
        try customMemory.write(to: manager.memoryFileURL, atomically: true, encoding: .utf8)

        let entry = MemoryEntry(
            section: .ongoingGoals,
            tag: .factSensitive,
            content: "Prefers private planning sessions",
            sourceSessionID: UUID(uuidString: "aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb")!,
            timestamp: Date(timeIntervalSince1970: 1_739_850_000)
        )

        // When
        try manager.appendEntries(entries: [entry])

        // Then
        let content = try String(contentsOf: manager.memoryFileURL, encoding: .utf8)
        XCTAssertTrue(content.contains("- User custom profile line"))
        XCTAssertTrue(content.contains("Keep this exact line"))
        XCTAssertTrue(content.contains("- [fact][sensitive] Prefers private planning sessions"))
    }

    func test_appendEntries_fuzzyNearDuplicate_sameSection_skipsSecondEntry() throws {
        // Given
        let manager = self.makeManager()
        try manager.ensureMemoryStructureExists()

        let sessionID = UUID(uuidString: "aaaaaaaa-1111-2222-3333-444444444444")!
        let firstEntry = MemoryEntry(
            section: .preferences,
            tag: .preference,
            content: "User prefers evening workouts after 7pm on weekdays.",
            sourceSessionID: sessionID,
            timestamp: Date(timeIntervalSince1970: 1_739_910_000)
        )
        let nearDuplicate = MemoryEntry(
            section: .preferences,
            tag: .preference,
            content: "User prefers evening workouts after 7pm on weekday evenings.",
            sourceSessionID: sessionID,
            timestamp: Date(timeIntervalSince1970: 1_739_910_100)
        )

        // When
        try manager.appendEntries(entries: [firstEntry])
        try manager.appendEntries(entries: [nearDuplicate])

        // Then
        let content = try String(contentsOf: manager.memoryFileURL, encoding: .utf8)
        XCTAssertTrue(content.contains("User prefers evening workouts after 7pm on weekdays."))
        XCTAssertFalse(content.contains("User prefers evening workouts after 7pm on weekday evenings."))
    }

    func test_appendEntries_fuzzyDedup_sameSectionDifferentContent_allowsBothEntries() throws {
        // Given
        let manager = self.makeManager()
        try manager.ensureMemoryStructureExists()

        let sessionID = UUID(uuidString: "bbbbbbbb-1111-2222-3333-444444444444")!
        let firstEntry = MemoryEntry(
            section: .preferences,
            tag: .preference,
            content: "Prefers evening workouts after 7pm on weekdays.",
            sourceSessionID: sessionID,
            timestamp: Date(timeIntervalSince1970: 1_739_920_000)
        )
        let distinctEntry = MemoryEntry(
            section: .preferences,
            tag: .preference,
            content: "Keeps notifications disabled during deep work blocks from 9am to noon.",
            sourceSessionID: sessionID,
            timestamp: Date(timeIntervalSince1970: 1_739_920_100)
        )

        // When
        try manager.appendEntries(entries: [firstEntry, distinctEntry])

        // Then
        let content = try String(contentsOf: manager.memoryFileURL, encoding: .utf8)
        XCTAssertTrue(content.contains("Prefers evening workouts after 7pm on weekdays."))
        XCTAssertTrue(content.contains("Keeps notifications disabled during deep work blocks from 9am to noon."))
    }

    func test_ensureMemoryStructureExists_legacyMemoryUpdateSections_removedByMigration() throws {
        // Given
        let manager = self.makeManager()
        try manager.ensureMemoryStructureExists()

        let legacyContent = """
# Ora Memory

## Memory Update

- [fact] Temporary migration artifact should be removed

## Profile

- [fact] Name is Alex

## Preferences

## People

## Projects

## Ongoing Goals
"""
        try legacyContent.write(to: manager.memoryFileURL, atomically: true, encoding: .utf8)

        // When
        try manager.ensureMemoryStructureExists()

        // Then
        let content = try String(contentsOf: manager.memoryFileURL, encoding: .utf8)
        XCTAssertFalse(content.contains("## Memory Update"))
        XCTAssertFalse(content.contains("Temporary migration artifact should be removed"))
        XCTAssertTrue(content.contains("## Profile"))
        XCTAssertTrue(content.contains("## Preferences"))
        XCTAssertTrue(content.contains("## People"))
        XCTAssertTrue(content.contains("## Projects"))
        XCTAssertTrue(content.contains("## Ongoing Goals"))
    }

    // MARK: - Helpers

    private func makeManager() -> MemoryFileManager {
        let memoryDirectory = self.temporaryDirectoryURL.appendingPathComponent("memory", isDirectory: true)
        return MemoryFileManager(memoryDirectory: memoryDirectory)
    }

    private func occurrenceCount(of token: String, in content: String) -> Int {
        content.components(separatedBy: token).count - 1
    }

    private func entryLineAppearsInsideSection(
        content: String,
        sectionHeading: String,
        entryPrefix: String
    ) -> Bool {
        guard let sectionRange = content.range(of: sectionHeading) else {
            return false
        }

        let afterSection = content[sectionRange.upperBound...]
        let nextSectionRange = afterSection.range(of: "\n## ")
        let sectionBody: Substring
        if let nextSectionRange {
            sectionBody = afterSection[..<nextSectionRange.lowerBound]
        } else {
            sectionBody = afterSection
        }

        return sectionBody.contains(entryPrefix)
    }
}
