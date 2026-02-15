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
        let documentsDirectory = self.temporaryDirectoryURL.appendingPathComponent("Documents", isDirectory: true)
        let manager = MemoryFileManager(documentsDirectory: documentsDirectory)

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
        let documentsDirectory = self.temporaryDirectoryURL.appendingPathComponent("Documents", isDirectory: true)
        let manager = MemoryFileManager(documentsDirectory: documentsDirectory)
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
        XCTAssertEqual(content, customContent)
        XCTAssertTrue(FileManager.default.fileExists(atPath: manager.summariesDirectory.path))
    }
}
