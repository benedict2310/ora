//
//  MemoryFileManager.swift
//  Ora
//
//  Manages on-disk memory files in ~/.ora/memory.
//

import Foundation

struct MemoryFileManager {

    // MARK: - Constants

    static let initialMemoryTemplate = """
# Ora Memory

This file is user-editable.
Add or remove details that you want Ora to remember long-term.

## Profile

## Preferences

## People

## Projects

## Ongoing Goals
"""

    private static let writeLock = NSLock()
    private static let fuzzyDedupThreshold = 0.95
    private static let containmentDedupMinLength = 20

    // MARK: - Properties

    private let fileManager: FileManager
    let memoryDirectory: URL

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

    init(fileManager: FileManager = .default, memoryDirectory: URL? = nil) {
        self.fileManager = fileManager
        if let memoryDirectory {
            self.memoryDirectory = memoryDirectory
        } else {
            self.memoryDirectory = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
                .appendingPathComponent(".ora", isDirectory: true)
                .appendingPathComponent("memory", isDirectory: true)
        }
    }

    // MARK: - Directory Management

    static func ensureDirectories() throws {
        try MemoryFileManager().ensureMemoryStructureExists()
    }

    func ensureMemoryStructureExists() throws {
        try self.fileManager.createDirectory(at: self.summariesDirectory, withIntermediateDirectories: true)
        try self.ensureMemoryTemplateExists()
        try self.migrateLegacySectionsIfNeeded()
    }

    func writeSummary(sessionId: UUID, content: String) throws {
        try self.ensureMemoryStructureExists()
        let summaryURL = self.summaryFileURL(for: sessionId)
        try content.write(to: summaryURL, atomically: true, encoding: .utf8)
    }

    func writePlaceholderSummary(sessionId: UUID) throws {
        try self.writeSummary(sessionId: sessionId, content: SessionSummary.placeholder.renderMarkdown())
    }

    func appendEntries(entries: [MemoryEntry]) throws {
        let normalizedEntries = entries.filter { !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !normalizedEntries.isEmpty else {
            return
        }

        try self.ensureMemoryStructureExists()
        try Self.withWriteLock {
            let existingContent = (try? String(contentsOf: self.memoryFileURL, encoding: .utf8)) ?? Self.initialMemoryTemplate
            let contentWithSections = Self.ensureRequiredSections(in: existingContent)
            var lines = Self.splitLines(contentWithSections)
            let existingFingerprints = Self.existingEntryFingerprints(in: lines)
            let existingSectionContent = Self.existingEntryContentBySection(in: lines)
            let entriesToAppend = Self.deduplicatedEntries(
                from: normalizedEntries,
                existingFingerprints: existingFingerprints,
                existingSectionContentBySection: existingSectionContent
            )

            guard !entriesToAppend.isEmpty else {
                return
            }

            let groupedEntries = Dictionary(grouping: entriesToAppend, by: { $0.section })
            for section in MemoryEntry.Section.allCases.reversed() {
                guard let sectionEntries = groupedEntries[section], !sectionEntries.isEmpty else {
                    continue
                }

                let sectionRanges = Self.sectionRanges(in: lines)
                guard let range = sectionRanges[section] else {
                    continue
                }

                let insertionIndex = Self.insertionIndex(for: range, lines: lines)
                lines.insert(contentsOf: sectionEntries.map(\.renderedLine), at: insertionIndex)
            }

            let updatedContent = lines.joined(separator: "\n")
            try updatedContent.write(to: self.memoryFileURL, atomically: true, encoding: .utf8)
        }
    }

    // MARK: - Private Helpers

    private func ensureMemoryTemplateExists() throws {
        guard !self.fileManager.fileExists(atPath: self.memoryFileURL.path) else {
            return
        }

        try Self.initialMemoryTemplate.write(to: self.memoryFileURL, atomically: true, encoding: .utf8)
    }

    private func migrateLegacySectionsIfNeeded() throws {
        guard self.fileManager.fileExists(atPath: self.memoryFileURL.path) else {
            return
        }

        try Self.withWriteLock {
            let existingContent = (try? String(contentsOf: self.memoryFileURL, encoding: .utf8)) ?? Self.initialMemoryTemplate
            let normalizedContent = Self.ensureRequiredSections(in: existingContent)
            guard normalizedContent != existingContent else {
                return
            }
            try normalizedContent.write(to: self.memoryFileURL, atomically: true, encoding: .utf8)
        }
    }

    private static func withWriteLock<T>(_ operation: () throws -> T) throws -> T {
        self.writeLock.lock()
        defer {
            self.writeLock.unlock()
        }
        return try operation()
    }

    private static func splitLines(_ content: String) -> [String] {
        content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    private static func ensureRequiredSections(in content: String) -> String {
        var lines = self.splitLines(content)

        if lines.isEmpty {
            lines = self.splitLines(Self.initialMemoryTemplate)
        }

        lines = self.removingLegacyMemoryUpdateSections(from: lines)

        for section in MemoryEntry.Section.allCases {
            if lines.contains(section.heading) {
                continue
            }
            if lines.last?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                lines.append("")
            }
            lines.append(section.heading)
            lines.append("")
        }

        return lines.joined(separator: "\n")
    }

    private static func removingLegacyMemoryUpdateSections(from lines: [String]) -> [String] {
        var output: [String] = []
        var isSkippingLegacySection = false

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            let isLevelTwoHeading = trimmed.hasPrefix("## ")

            if isLevelTwoHeading {
                if self.isLegacyMemoryUpdateHeading(trimmed) {
                    isSkippingLegacySection = true
                    continue
                }
                isSkippingLegacySection = false
            }

            if isSkippingLegacySection {
                continue
            }

            output.append(line)
        }

        return output
    }

    private static func isLegacyMemoryUpdateHeading(_ heading: String) -> Bool {
        heading
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .hasPrefix("## memory update")
    }

    private static func deduplicatedEntries(
        from entries: [MemoryEntry],
        existingFingerprints: Set<String>,
        existingSectionContentBySection: [MemoryEntry.Section: [String]]
    ) -> [MemoryEntry] {
        var output: [MemoryEntry] = []
        var seenFingerprints = existingFingerprints
        var seenKeys: Set<String> = []
        var seenSectionContentBySection = existingSectionContentBySection

        for entry in entries {
            let fingerprint = entry.dedupFingerprint
            if seenFingerprints.contains(fingerprint) {
                continue
            }

            if let key = entry.normalizedKeyToken {
                if seenKeys.contains(key) {
                    continue
                }
                seenKeys.insert(key)
            }

            // Always run fuzzy dedup against existing entries regardless of
            // normalizedKey. Previously this was gated on normalizedKeyToken == nil
            // which allowed near-duplicate entries to accumulate across sessions
            // when the distiller assigned different keys.
            let existingContent = seenSectionContentBySection[entry.section] ?? []
            let normalizedContent = MemoryEntry.normalizeForDedup(entry.content)
            if self.hasFuzzyDuplicate(normalizedContent, against: existingContent) {
                continue
            }

            output.append(entry)
            seenFingerprints.insert(fingerprint)
            seenSectionContentBySection[entry.section, default: []].append(normalizedContent)
        }

        return output
    }

    private static func hasFuzzyDuplicate(_ normalizedContent: String, against candidates: [String]) -> Bool {
        let strippedContent = Self.stripPunctuation(normalizedContent)

        for candidate in candidates {
            // Containment check: if one entry's core text is a substring of the
            // other, it's a duplicate (e.g., "user sent a message to alex" vs
            // "user sent a message to alex, which was successfully delivered").
            // Punctuation is stripped so that "alex." matches "alex," etc.
            let strippedCandidate = Self.stripPunctuation(candidate)
            if strippedContent.count >= Self.containmentDedupMinLength
                || strippedCandidate.count >= Self.containmentDedupMinLength {
                if strippedCandidate.contains(strippedContent) || strippedContent.contains(strippedCandidate) {
                    return true
                }
            }

            let similarity = StringSimilarity.jaroWinkler(normalizedContent, candidate)
            if similarity >= Self.fuzzyDedupThreshold {
                return true
            }
        }
        return false
    }

    private static func stripPunctuation(_ text: String) -> String {
        text.unicodeScalars.filter { !CharacterSet.punctuationCharacters.contains($0) }
            .map { String($0) }
            .joined()
    }

    private static func existingEntryFingerprints(in lines: [String]) -> Set<String> {
        let ranges = self.sectionRanges(in: lines)
        var fingerprints: Set<String> = []

        for (section, range) in ranges {
            guard range.count > 1 else {
                continue
            }

            for line in lines[(range.lowerBound + 1)..<range.upperBound] {
                guard let prefix = self.entryPrefix(from: line) else {
                    continue
                }
                let token = MemoryEntry.normalizeForDedup(prefix)
                fingerprints.insert("\(section.rawValue)|\(token)")
            }
        }

        return fingerprints
    }

    private static func existingEntryContentBySection(in lines: [String]) -> [MemoryEntry.Section: [String]] {
        let ranges = self.sectionRanges(in: lines)
        var contentBySection: [MemoryEntry.Section: [String]] = [:]

        for (section, range) in ranges {
            guard range.count > 1 else {
                continue
            }

            for line in lines[(range.lowerBound + 1)..<range.upperBound] {
                guard let content = self.entryContent(from: line) else {
                    continue
                }
                contentBySection[section, default: []].append(content)
            }
        }

        return contentBySection
    }

    private static func entryPrefix(from line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("- ") else {
            return nil
        }

        let body = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else {
            return nil
        }

        if let sourceRange = body.range(of: " (source:", options: [.caseInsensitive, .backwards]) {
            let prefix = body[..<sourceRange.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
            return prefix.isEmpty ? nil : prefix
        }

        return body
    }

    private static func entryContent(from line: String) -> String? {
        guard let prefix = self.entryPrefix(from: line) else {
            return nil
        }

        let withoutTag = prefix
            .replacingOccurrences(of: #"^\[[^\]]+\](?:\[[^\]]+\])?\s*"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !withoutTag.isEmpty else {
            return nil
        }

        return MemoryEntry.normalizeForDedup(withoutTag)
    }

    private static func sectionRanges(in lines: [String]) -> [MemoryEntry.Section: Range<Int>] {
        var sectionStarts: [(section: MemoryEntry.Section, index: Int)] = []

        for (index, line) in lines.enumerated() {
            for section in MemoryEntry.Section.allCases where line == section.heading {
                sectionStarts.append((section: section, index: index))
            }
        }

        guard !sectionStarts.isEmpty else {
            return [:]
        }

        sectionStarts.sort { $0.index < $1.index }
        var ranges: [MemoryEntry.Section: Range<Int>] = [:]

        for (currentIndex, start) in sectionStarts.enumerated() {
            let end = currentIndex + 1 < sectionStarts.count
                ? sectionStarts[currentIndex + 1].index
                : lines.count
            ranges[start.section] = start.index..<end
        }

        return ranges
    }

    private static func insertionIndex(for sectionRange: Range<Int>, lines: [String]) -> Int {
        var insertion = sectionRange.upperBound
        while insertion > sectionRange.lowerBound + 1 {
            let candidate = lines[insertion - 1].trimmingCharacters(in: .whitespacesAndNewlines)
            if candidate.isEmpty {
                insertion -= 1
                continue
            }
            break
        }
        return insertion
    }
}
