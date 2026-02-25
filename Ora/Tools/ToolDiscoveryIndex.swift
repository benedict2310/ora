//
//  ToolDiscoveryIndex.swift
//  Ora
//
//  Lightweight in-memory tool discovery index with deterministic matching
//  and BM25 fallback scoring.
//

import Foundation

struct ToolDiscoveryMatch: Sendable {
    let schema: ToolSchema
    let score: Double
}

struct ToolDiscoveryIndex: Sendable {

    // MARK: - Constants

    static let defaultTopK = 5
    static let maxTopK = 8

    // MARK: - Private Types

    private struct Entry: Sendable {
        let schema: ToolSchema
        let domain: String
        let normalizedName: String
        let keywordSet: Set<String>
        let termFrequencies: [String: Int]
        let documentLength: Int
    }

    private struct RankedCandidate {
        let schema: ToolSchema
        let score: Double
    }

    // MARK: - Properties

    private let entries: [Entry]
    private let documentFrequency: [String: Int]
    private let averageDocumentLength: Double

    // MARK: - Initialization

    init(schemas: [ToolSchema]) {
        var builtEntries: [Entry] = []
        builtEntries.reserveCapacity(schemas.count)

        var docFrequency: [String: Int] = [:]
        var totalLength = 0

        for schema in schemas.sorted(by: { $0.name < $1.name }) {
            let domain = Self.domainForToolName(schema.name)
            let nameTokens = Self.tokenize(schema.name)
            let descriptionTokens = Self.tokenize(schema.description)
            let parameterTokens = schema.parameters.keys.flatMap { Self.tokenize($0) }

            let documentTokens = nameTokens + descriptionTokens + parameterTokens
            let termFrequencies = Self.termFrequency(documentTokens)
            let documentLength = max(documentTokens.count, 1)
            totalLength += documentLength

            let keywordSet = Self.keywordSet(
                domain: domain,
                nameTokens: nameTokens,
                descriptionTokens: descriptionTokens,
                parameterTokens: parameterTokens
            )

            for token in Set(documentTokens) {
                docFrequency[token, default: 0] += 1
            }

            builtEntries.append(
                Entry(
                    schema: schema,
                    domain: domain,
                    normalizedName: Self.normalize(schema.name),
                    keywordSet: keywordSet,
                    termFrequencies: termFrequencies,
                    documentLength: documentLength
                )
            )
        }

        self.entries = builtEntries
        self.documentFrequency = docFrequency
        self.averageDocumentLength = builtEntries.isEmpty
            ? 1.0
            : Double(totalLength) / Double(builtEntries.count)
    }

    // MARK: - Public API

    var indexedToolNames: [String] {
        self.entries.map { $0.schema.name }
    }

    func search(query: String, topK: Int = ToolDiscoveryIndex.defaultTopK) -> [ToolDiscoveryMatch] {
        let normalizedQuery = Self.normalize(query)
        guard !normalizedQuery.isEmpty else {
            return []
        }

        let queryTokens = Self.queryTokenSet(query)
        guard !queryTokens.isEmpty else {
            return []
        }

        let clampedTopK = min(max(topK, 1), Self.maxTopK)
        var ranked: [RankedCandidate] = []
        var seenNames: Set<String> = []

        let deterministic = self.deterministicCandidates(
            normalizedQuery: normalizedQuery,
            queryTokens: queryTokens
        )

        for candidate in deterministic {
            ranked.append(candidate)
            seenNames.insert(candidate.schema.name)
            if ranked.count >= clampedTopK {
                return ranked.prefix(clampedTopK).map {
                    ToolDiscoveryMatch(schema: $0.schema, score: Self.roundedScore($0.score))
                }
            }
        }

        let bm25 = self.bm25Candidates(
            normalizedQuery: normalizedQuery,
            queryTokens: queryTokens,
            excluding: seenNames
        )

        for candidate in bm25 {
            ranked.append(candidate)
            if ranked.count >= clampedTopK {
                break
            }
        }

        return ranked.prefix(clampedTopK).map {
            ToolDiscoveryMatch(schema: $0.schema, score: Self.roundedScore($0.score))
        }
    }

    // MARK: - Deterministic Ranking

    private func deterministicCandidates(
        normalizedQuery: String,
        queryTokens: Set<String>
    ) -> [RankedCandidate] {
        var candidates: [RankedCandidate] = []

        for entry in self.entries {
            var score = 0.0

            if normalizedQuery == entry.normalizedName {
                score = max(score, 1.0)
            } else if entry.normalizedName.contains(normalizedQuery) || normalizedQuery.contains(entry.normalizedName) {
                score = max(score, 0.97)
            }

            let overlapCount = queryTokens.intersection(entry.keywordSet).count
            if overlapCount > 0 {
                let overlapRatio = Double(overlapCount) / Double(max(queryTokens.count, 1))
                let overlapScore = 0.82 + (0.15 * min(overlapRatio, 1.0))
                score = max(score, overlapScore)
            }

            if queryTokens.contains(entry.domain) {
                score = max(score, 0.78)
            }

            let similarity = StringSimilarity.jaroWinkler(normalizedQuery, entry.normalizedName)
            if similarity >= 0.93 {
                score = max(score, 0.9)
            }

            if score > 0 {
                candidates.append(RankedCandidate(schema: entry.schema, score: min(score, 1.0)))
            }
        }

        return candidates.sorted {
            if $0.score == $1.score {
                return $0.schema.name < $1.schema.name
            }
            return $0.score > $1.score
        }
    }

    // MARK: - BM25 Ranking

    private func bm25Candidates(
        normalizedQuery: String,
        queryTokens: Set<String>,
        excluding excludedNames: Set<String>
    ) -> [RankedCandidate] {
        let k1 = 1.5
        let b = 0.75
        let totalDocuments = Double(max(self.entries.count, 1))

        var rawCandidates: [(schema: ToolSchema, rawScore: Double)] = []
        rawCandidates.reserveCapacity(self.entries.count)

        for entry in self.entries where !excludedNames.contains(entry.schema.name) {
            var score = 0.0

            for token in queryTokens {
                guard let tf = entry.termFrequencies[token], tf > 0 else {
                    continue
                }

                let df = Double(self.documentFrequency[token] ?? 0)
                let idf = log(1.0 + ((totalDocuments - df + 0.5) / (df + 0.5)))
                let frequency = Double(tf)
                let denominator = frequency + (k1 * (1.0 - b + b * (Double(entry.documentLength) / self.averageDocumentLength)))
                score += idf * ((frequency * (k1 + 1.0)) / denominator)
            }

            if score > 0 {
                let similarity = StringSimilarity.jaroWinkler(normalizedQuery, entry.normalizedName)
                let similarityBoost = 0.35 * similarity
                let domainBoost = queryTokens.contains(entry.domain) ? 0.1 : 0.0
                rawCandidates.append((entry.schema, score + similarityBoost + domainBoost))
            }
        }

        guard !rawCandidates.isEmpty else {
            return []
        }

        let maxRawScore = rawCandidates.reduce(0.0) { max($0, $1.rawScore) }

        return rawCandidates
            .sorted {
                if $0.rawScore == $1.rawScore {
                    return $0.schema.name < $1.schema.name
                }
                return $0.rawScore > $1.rawScore
            }
            .map { candidate in
                let normalized = maxRawScore > 0 ? candidate.rawScore / maxRawScore : 0
                let scaled = max(0.05, min(0.79, normalized * 0.79))
                return RankedCandidate(schema: candidate.schema, score: scaled)
            }
    }

    // MARK: - Helpers

    private static let stopWords: Set<String> = [
        "a", "an", "and", "at", "by", "for", "from", "in", "is", "it",
        "me", "my", "of", "on", "or", "the", "to", "with", "you", "your"
    ]

    private static func queryTokenSet(_ value: String) -> Set<String> {
        Set(Self.tokenize(value))
    }

    private static func domainForToolName(_ toolName: String) -> String {
        guard let dot = toolName.firstIndex(of: ".") else {
            return toolName.lowercased()
        }
        return String(toolName[..<dot]).lowercased()
    }

    private static func termFrequency(_ tokens: [String]) -> [String: Int] {
        var frequencies: [String: Int] = [:]
        for token in tokens where !token.isEmpty {
            frequencies[token, default: 0] += 1
        }
        return frequencies
    }

    private static func keywordSet(
        domain: String,
        nameTokens: [String],
        descriptionTokens: [String],
        parameterTokens: [String]
    ) -> Set<String> {
        var tokens: Set<String> = [domain]
        for token in nameTokens {
            tokens.formUnion(Self.expandedTokenForms(token))
        }
        for token in descriptionTokens where token.count >= 4 {
            tokens.insert(token)
        }
        for token in parameterTokens {
            tokens.formUnion(Self.expandedTokenForms(token))
        }
        return tokens
    }

    private static func expandedTokenForms(_ token: String) -> Set<String> {
        guard !token.isEmpty else {
            return []
        }

        var values: Set<String> = [token]
        if token.hasSuffix("s"), token.count > 3 {
            values.insert(String(token.dropLast()))
        } else if token.count > 3 {
            values.insert("\(token)s")
        }
        return values
    }

    private static func tokenize(_ value: String) -> [String] {
        let normalized = Self.normalize(value)
        guard !normalized.isEmpty else {
            return []
        }

        return normalized
            .split(separator: " ")
            .map(String.init)
            .filter { token in
                token.count >= 2 && !Self.stopWords.contains(token)
            }
    }

    private static func normalize(_ value: String) -> String {
        let lowercase = value.lowercased()
        let scalars = lowercase.unicodeScalars.map { scalar -> Character in
            if CharacterSet.alphanumerics.contains(scalar) {
                return Character(scalar)
            }
            return " "
        }

        return String(scalars)
            .split(separator: " ")
            .map(String.init)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func roundedScore(_ score: Double) -> Double {
        Double((score * 1000).rounded() / 1000)
    }
}
