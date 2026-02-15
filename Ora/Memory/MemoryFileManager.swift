//
//  MemoryFileManager.swift
//  Ora
//
//  Manages on-disk memory files in ~/Documents/Ora/Memory.
//

import Foundation

struct MemoryFileManager {

    // MARK: - Constants

    static let initialMemoryTemplate = """
# Ora Memory

This file is user-editable.
Add or remove details that you want Ora to remember long-term.
"""

    // MARK: - Properties

    private let fileManager: FileManager
    let documentsDirectory: URL

    var oraDirectory: URL {
        self.documentsDirectory.appendingPathComponent("Ora", isDirectory: true)
    }

    var memoryDirectory: URL {
        self.oraDirectory.appendingPathComponent("Memory", isDirectory: true)
    }

    var summariesDirectory: URL {
        self.memoryDirectory.appendingPathComponent("Summaries", isDirectory: true)
    }

    var memoryFileURL: URL {
        self.memoryDirectory.appendingPathComponent("MEMORY.md", isDirectory: false)
    }

    // MARK: - Paths

    func summaryFileURL(for sessionId: UUID) -> URL {
        self.summariesDirectory.appendingPathComponent("\(sessionId.uuidString).md", isDirectory: false)
    }

    // MARK: - Initialization

    init(fileManager: FileManager = .default, documentsDirectory: URL? = nil) {
        self.fileManager = fileManager
        if let documentsDirectory {
            self.documentsDirectory = documentsDirectory
        } else if let resolvedDocumentsDirectory = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first {
            self.documentsDirectory = resolvedDocumentsDirectory
        } else {
            self.documentsDirectory = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
                .appendingPathComponent("Documents", isDirectory: true)
        }
    }

    // MARK: - Directory Management

    static func ensureDirectories() throws {
        try MemoryFileManager().ensureMemoryStructureExists()
    }

    func ensureMemoryStructureExists() throws {
        try self.fileManager.createDirectory(at: self.summariesDirectory, withIntermediateDirectories: true)
        try self.ensureMemoryTemplateExists()
    }

    func writeSummary(sessionId: UUID, content: String) throws {
        try self.ensureMemoryStructureExists()
        let summaryURL = self.summaryFileURL(for: sessionId)
        try content.write(to: summaryURL, atomically: true, encoding: .utf8)
    }

    func writePlaceholderSummary(sessionId: UUID) throws {
        try self.writeSummary(sessionId: sessionId, content: SessionSummary.placeholder.renderMarkdown())
    }

    // MARK: - Private Helpers

    private func ensureMemoryTemplateExists() throws {
        guard !self.fileManager.fileExists(atPath: self.memoryFileURL.path) else {
            return
        }

        try Self.initialMemoryTemplate.write(to: self.memoryFileURL, atomically: true, encoding: .utf8)
    }
}
