//
//  MemoryTriggerDetector.swift
//  Ora
//
//  Detects whether a user prompt likely needs memory retrieval.
//

import Foundation
import os

enum MemoryTriggerType: String, Sendable, Equatable {
    case none
    case linguistic
    case entityOverlap
    case taskFraming
}

struct MemoryTriggerResult: Sendable, Equatable {
    let shouldTrigger: Bool
    let confidence: Double
    let triggerType: MemoryTriggerType
    let matchedSignals: [String]
}

protocol MemoryTriggerDetecting: Sendable {
    func detect(userText: String) -> MemoryTriggerResult
}

protocol MemoryRetrievalCoordinating: Sendable {
    func prepareRetrievalIfNeeded(
        userText: String,
        triggerResult: MemoryTriggerResult,
        conversationManager: ConversationManager
    ) async
}

struct NoopMemoryRetrievalCoordinator: MemoryRetrievalCoordinating {
    func prepareRetrievalIfNeeded(
        userText: String,
        triggerResult: MemoryTriggerResult,
        conversationManager: ConversationManager
    ) async {
        return
    }
}

struct KeywordMemoryRetrievalCoordinator: MemoryRetrievalCoordinating {

    // MARK: - Configuration

    struct Configuration: Sendable, Equatable {
        let minTopScore: Double
        let minChunkCount: Int
        let maxChunkCount: Int
        let scoreWindowRatio: Double

        static let `default` = Configuration(
            minTopScore: 0.30,
            minChunkCount: 3,
            maxChunkCount: 7,
            scoreWindowRatio: 0.70
        )
    }

    // MARK: - Properties

    private let logger = Logger(subsystem: "com.ora.app", category: "memory")
    private let memoryIndex: any MemoryIndexing
    private let configuration: Configuration

    // MARK: - Initialization

    init(
        memoryIndex: any MemoryIndexing = MemoryIndex.shared,
        configuration: Configuration = .default
    ) {
        self.memoryIndex = memoryIndex
        self.configuration = configuration
    }

    // MARK: - MemoryRetrievalCoordinating

    func prepareRetrievalIfNeeded(
        userText: String,
        triggerResult: MemoryTriggerResult,
        conversationManager: ConversationManager
    ) async {
        guard triggerResult.shouldTrigger else {
            await conversationManager.clearMemoryContext()
            return
        }

        let retrievedChunks = await self.memoryIndex.search(
            query: userText,
            limit: self.configuration.maxChunkCount
        )
        guard let topChunk = retrievedChunks.first else {
            await conversationManager.clearMemoryContext()
            self.logger.debug("Memory retrieval produced no chunks")
            return
        }

        guard topChunk.score >= self.configuration.minTopScore else {
            await conversationManager.clearMemoryContext()
            self.logger.debug(
                "Memory retrieval skipped due to low confidence (score: \(topChunk.score), threshold: \(self.configuration.minTopScore))"
            )
            return
        }

        let selectedChunks = self.selectChunks(from: retrievedChunks)
        guard !selectedChunks.isEmpty else {
            await conversationManager.clearMemoryContext()
            return
        }

        let context = self.renderContext(chunks: selectedChunks)
        await conversationManager.setMemoryContext(context)
        self.logger.debug("Injected \(selectedChunks.count) memory chunk(s) into prompt context")
    }

    // MARK: - Private Helpers

    private func selectChunks(from chunks: [MemoryChunk]) -> [MemoryChunk] {
        guard let topScore = chunks.first?.score else {
            return []
        }

        let dynamicFloor = topScore * self.configuration.scoreWindowRatio
        var shortlisted = chunks.filter { chunk in
            return chunk.score >= dynamicFloor
        }

        if shortlisted.count < self.configuration.minChunkCount {
            let fallbackCount = min(self.configuration.minChunkCount, chunks.count)
            shortlisted = Array(chunks.prefix(fallbackCount))
        }

        return Array(shortlisted.prefix(self.configuration.maxChunkCount))
    }

    private func renderContext(chunks: [MemoryChunk]) -> String {
        let header = """
        Relevant memory retrieved from MEMORY.md and prior session summaries.
        Use this context only when it directly helps answer the user.
        """

        let lines = chunks.enumerated().map { index, chunk in
            let source: String
            switch chunk.documentType {
            case .memory:
                source = "memory"
            case .summary:
                if let sessionID = chunk.sessionID {
                    source = "summary \(sessionID.uuidString)"
                } else {
                    source = "summary"
                }
            }

            return "\(index + 1). [\(source) • \(chunk.sectionName)] \(chunk.content)"
        }

        return ([header, ""] + lines).joined(separator: "\n")
    }
}

struct MemoryTriggerDetector: MemoryTriggerDetecting, Sendable {

    // MARK: - Configuration

    struct Configuration: Sendable, Equatable {
        let activationThreshold: Double
        let minimumEntityTokenLength: Int

        static let `default` = Configuration(
            activationThreshold: 0.0,
            minimumEntityTokenLength: 3
        )
    }

    // MARK: - Types

    private struct SignalMatch: Sendable {
        let type: MemoryTriggerType
        let confidence: Double
        let signals: [String]
    }

    private final class EntityIndexCache: @unchecked Sendable {
        private struct FileSignature: Equatable {
            let modificationDate: Date?
            let fileSize: Int?
            let fileSystemNumber: Int64?
        }

        private var cachedTokens: Set<String>?
        private var cachedFileSignature: FileSignature?
        private let lock = NSLock()

        func tokens(for fileURL: URL, load: () throws -> Set<String>) -> Set<String> {
            self.lock.lock()
            defer {
                self.lock.unlock()
            }

            let currentFileSignature = Self.makeFileSignature(for: fileURL)
            if let cachedTokens = self.cachedTokens,
                self.cachedFileSignature == currentFileSignature {
                return cachedTokens
            }

            do {
                let loadedTokens = try load()
                self.cachedTokens = loadedTokens
                self.cachedFileSignature = currentFileSignature
                return loadedTokens
            } catch {
                if let cachedTokens = self.cachedTokens {
                    return cachedTokens
                }
                return []
            }
        }

        private static func makeFileSignature(for fileURL: URL) -> FileSignature? {
            guard let fileAttributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path) else {
                return nil
            }

            return FileSignature(
                modificationDate: fileAttributes[.modificationDate] as? Date,
                fileSize: (fileAttributes[.size] as? NSNumber)?.intValue,
                fileSystemNumber: (fileAttributes[.systemFileNumber] as? NSNumber)?.int64Value
            )
        }
    }

    // MARK: - Properties

    private let configuration: Configuration
    private let memoryFileURL: URL
    private let loadFileContent: @Sendable (URL) throws -> String
    private let entityIndexCache: EntityIndexCache

    // MARK: - Initialization

    init(
        configuration: Configuration = .default,
        memoryFileURL: URL = MemoryFileManager().memoryFileURL,
        loadFileContent: @escaping @Sendable (URL) throws -> String = { url in
            return try String(contentsOf: url, encoding: .utf8)
        }
    ) {
        self.configuration = configuration
        self.memoryFileURL = memoryFileURL
        self.loadFileContent = loadFileContent
        self.entityIndexCache = EntityIndexCache()
    }

    // MARK: - Public API

    func detect(userText: String) -> MemoryTriggerResult {
        let normalizedText = Self.normalizeForPhraseMatching(userText)
        let userTokens = Set(Self.extractTokens(from: userText))
        var matches: [SignalMatch] = []

        if let linguisticMatch = self.detectLinguisticSignal(in: normalizedText) {
            matches.append(linguisticMatch)
        }

        if let taskFramingMatch = self.detectTaskFramingSignal(in: normalizedText) {
            matches.append(taskFramingMatch)
        }

        if let entityMatch = self.detectEntityOverlapSignal(userTokens: userTokens) {
            matches.append(entityMatch)
        }

        guard let strongestMatch = matches.max(by: { $0.confidence < $1.confidence }) else {
            return MemoryTriggerResult(
                shouldTrigger: false,
                confidence: 0.0,
                triggerType: .none,
                matchedSignals: []
            )
        }

        let additionalMatchBoost = min(Double(max(matches.count - 1, 0)) * 0.04, 0.08)
        let confidence = min(strongestMatch.confidence + additionalMatchBoost, 1.0)
        let shouldTrigger = confidence > self.configuration.activationThreshold
        let allSignals = matches.flatMap(\.signals)

        return MemoryTriggerResult(
            shouldTrigger: shouldTrigger,
            confidence: confidence,
            triggerType: strongestMatch.type,
            matchedSignals: allSignals
        )
    }

    // MARK: - Detection

    private func detectLinguisticSignal(in normalizedText: String) -> SignalMatch? {
        let matches = Self.linguisticTriggers.filter { normalizedText.contains($0) }
        guard !matches.isEmpty else {
            return nil
        }

        return SignalMatch(
            type: .linguistic,
            confidence: 0.92,
            signals: matches
        )
    }

    private func detectTaskFramingSignal(in normalizedText: String) -> SignalMatch? {
        let matches = Self.taskFramingTriggers.filter { normalizedText.contains($0) }
        guard !matches.isEmpty else {
            return nil
        }

        return SignalMatch(
            type: .taskFraming,
            confidence: 0.82,
            signals: matches
        )
    }

    private func detectEntityOverlapSignal(userTokens: Set<String>) -> SignalMatch? {
        guard !userTokens.isEmpty else {
            return nil
        }

        let memoryTokens = self.entityIndexCache.tokens(for: self.memoryFileURL) {
            return try self.loadEntityTokens()
        }
        guard !memoryTokens.isEmpty else {
            return nil
        }

        let overlap = userTokens.intersection(memoryTokens)
        guard !overlap.isEmpty else {
            return nil
        }

        let overlapCount = min(overlap.count, 3)
        let confidence = min(0.55 + (Double(overlapCount) * 0.11), 0.88)
        return SignalMatch(
            type: .entityOverlap,
            confidence: confidence,
            signals: overlap.sorted()
        )
    }

    // MARK: - Entity Index

    private func loadEntityTokens() throws -> Set<String> {
        let content = try self.loadFileContent(self.memoryFileURL)

        var tokens: Set<String> = []
        let lines = content.components(separatedBy: .newlines)

        for line in lines {
            let cleanedLine = Self.cleanMemoryLine(line)
            guard !cleanedLine.isEmpty else {
                continue
            }

            let lineTokens = Self.extractTokens(from: cleanedLine).filter { token in
                return token.count >= self.configuration.minimumEntityTokenLength &&
                    !Self.entityTokenStopWords.contains(token)
            }
            guard !lineTokens.isEmpty else {
                continue
            }

            tokens.formUnion(lineTokens)
            tokens.formUnion(Self.bigrams(from: lineTokens))
        }

        return tokens
    }

    // MARK: - Text Normalization

    private static func normalizeForPhraseMatching(_ text: String) -> String {
        return text
            .lowercased()
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func cleanMemoryLine(_ line: String) -> String {
        var cleaned = line.trimmingCharacters(in: .whitespacesAndNewlines)

        if cleaned.hasPrefix("#") {
            cleaned = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
        }

        if cleaned.hasPrefix("- ") {
            cleaned = String(cleaned.dropFirst(2))
        }

        if let sourceRange = cleaned.range(of: " (source:", options: [.caseInsensitive, .backwards]) {
            cleaned = String(cleaned[..<sourceRange.lowerBound])
        }

        cleaned = cleaned.replacingOccurrences(
            of: "\\[[^\\]]+\\]",
            with: " ",
            options: .regularExpression
        )

        return cleaned
    }

    private static func extractTokens(from text: String) -> [String] {
        return text
            .lowercased()
            .split(whereSeparator: { character in
                return !character.isLetter && !character.isNumber
            })
            .map(String.init)
            .filter { token in
                return !token.isEmpty
            }
    }

    private static func bigrams(from tokens: [String]) -> [String] {
        guard tokens.count > 1 else {
            return []
        }

        var results: [String] = []
        results.reserveCapacity(tokens.count - 1)

        for index in 0..<(tokens.count - 1) {
            results.append("\(tokens[index]) \(tokens[index + 1])")
        }

        return results
    }

    // MARK: - Constants

    private static let linguisticTriggers: [String] = [
        "remember",
        "last time",
        "as we discussed",
        "what did we decide",
        "my preference",
        "you told me",
        "we agreed"
    ]

    private static let taskFramingTriggers: [String] = [
        "next steps",
        "did we decide",
        "why did we choose",
        "follow up on",
        "follow-up on"
    ]

    private static let entityTokenStopWords: Set<String> = [
        "a",
        "an",
        "and",
        "are",
        "as",
        "at",
        "be",
        "did",
        "for",
        "from",
        "has",
        "have",
        "in",
        "is",
        "it",
        "my",
        "of",
        "on",
        "or",
        "ora",
        "our",
        "profile",
        "preferences",
        "people",
        "projects",
        "ongoing",
        "goals",
        "that",
        "the",
        "this",
        "to",
        "was",
        "we",
        "were",
        "what",
        "when",
        "where",
        "who",
        "why",
        "with",
        "you",
        "your"
    ]
}
