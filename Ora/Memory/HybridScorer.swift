//
//  HybridScorer.swift
//  Ora
//
//  Hybrid scoring for memory retrieval using embeddings, BM25, and recency.
//

import Foundation

struct HybridScorer: Sendable {

    // MARK: - Types

    struct Configuration: Sendable, Equatable {
        let cosineWeight: Double
        let bm25Weight: Double
        let recencyHalfLifeDays: Double
        let maxRecencyBoost: Double

        static let `default` = Configuration(
            cosineWeight: 0.7,
            bm25Weight: 0.3,
            recencyHalfLifeDays: 30,
            maxRecencyBoost: 0.08
        )
    }

    struct Candidate: Sendable {
        let rowID: Int64
        let content: String
        let documentType: MemoryDocumentType
        let sessionID: UUID?
        let sectionName: String
        let lastModified: Date
        let bm25Score: Double
        let embedding: [Float]?
    }

    struct ScoredChunk: Sendable, Equatable {
        let rowID: Int64
        let chunk: MemoryChunk
        let cosineSimilarity: Double
        let bm25Score: Double
        let normalizedBM25Score: Double
        let recencyBoost: Double
    }

    // MARK: - Properties

    private let configuration: Configuration

    // MARK: - Initialization

    init(configuration: Configuration = .default) {
        self.configuration = configuration
    }

    // MARK: - Public API

    func rank(
        queryEmbedding: [Float],
        candidates: [Candidate],
        now: Date = Date()
    ) -> [ScoredChunk] {
        guard !candidates.isEmpty else {
            return []
        }

        let maxBM25 = candidates.reduce(0.0) { partial, candidate in
            return max(partial, candidate.bm25Score)
        }

        let scored = candidates.map { candidate in
            let cosineRaw = Self.cosineSimilarity(queryEmbedding, candidate.embedding ?? [])
            let cosine = max(0.0, min(cosineRaw, 1.0))
            let normalizedBM25: Double
            if maxBM25 > 0 {
                normalizedBM25 = max(0.0, candidate.bm25Score) / maxBM25
            } else {
                normalizedBM25 = 0.0
            }

            let recencyBoost = self.recencyBoost(lastModified: candidate.lastModified, now: now)
            let hybridScore =
                (self.configuration.cosineWeight * cosine)
                + (self.configuration.bm25Weight * normalizedBM25)
                + recencyBoost

            return ScoredChunk(
                rowID: candidate.rowID,
                chunk: MemoryChunk(
                    content: candidate.content,
                    documentType: candidate.documentType,
                    sessionID: candidate.sessionID,
                    sectionName: candidate.sectionName,
                    lastModified: candidate.lastModified,
                    score: hybridScore,
                    embedding: candidate.embedding
                ),
                cosineSimilarity: cosine,
                bm25Score: candidate.bm25Score,
                normalizedBM25Score: normalizedBM25,
                recencyBoost: recencyBoost
            )
        }

        return scored.sorted { lhs, rhs in
            return lhs.chunk.score > rhs.chunk.score
        }
    }

    func isTopScoreAboveThreshold(_ scored: [ScoredChunk], threshold: Double) -> Bool {
        guard let top = scored.first else {
            return false
        }

        return top.chunk.score >= threshold
    }

    // MARK: - Helpers

    private func recencyBoost(lastModified: Date, now: Date) -> Double {
        let ageInSeconds = max(0.0, now.timeIntervalSince(lastModified))
        guard self.configuration.recencyHalfLifeDays > 0 else {
            return 0.0
        }

        let halfLifeSeconds = self.configuration.recencyHalfLifeDays * 86_400
        let decay = exp(-ageInSeconds / halfLifeSeconds)
        return self.configuration.maxRecencyBoost * decay
    }

    static func cosineSimilarity(_ lhs: [Float], _ rhs: [Float]) -> Double {
        guard !lhs.isEmpty, lhs.count == rhs.count else {
            return 0.0
        }

        var dotProduct = Double.zero
        var lhsMagnitude = Double.zero
        var rhsMagnitude = Double.zero

        for index in lhs.indices {
            let left = Double(lhs[index])
            let right = Double(rhs[index])
            dotProduct += left * right
            lhsMagnitude += left * left
            rhsMagnitude += right * right
        }

        guard lhsMagnitude > 0, rhsMagnitude > 0 else {
            return 0.0
        }

        return dotProduct / (sqrt(lhsMagnitude) * sqrt(rhsMagnitude))
    }
}
