//
//  HybridScorerTests.swift
//  OraTests
//
//  Tests for hybrid retrieval scoring.
//

import XCTest
@testable import Ora

final class HybridScorerTests: XCTestCase {

    func test_rank_mixedSignals_combinesCosineAndBM25WithConfiguredWeights() {
        // Given
        let scorer = HybridScorer(
            configuration: .init(
                cosineWeight: 0.7,
                bm25Weight: 0.3,
                recencyHalfLifeDays: 30,
                maxRecencyBoost: 0.0
            )
        )

        let queryEmbedding: [Float] = [1.0, 0.0]
        let now = Date(timeIntervalSince1970: 1_739_600_000)

        let candidates: [HybridScorer.Candidate] = [
            .init(
                rowID: 1,
                content: "Exact semantic match",
                documentType: .memory,
                sessionID: nil,
                sectionName: "Preferences",
                lastModified: now,
                bm25Score: 0.2,
                embedding: [1.0, 0.0]
            ),
            .init(
                rowID: 2,
                content: "Strong keyword but weak semantic",
                documentType: .memory,
                sessionID: nil,
                sectionName: "Projects",
                lastModified: now,
                bm25Score: 1.0,
                embedding: [0.0, 1.0]
            )
        ]

        // When
        let ranked = scorer.rank(queryEmbedding: queryEmbedding, candidates: candidates, now: now)

        // Then
        XCTAssertEqual(ranked.count, 2)
        XCTAssertEqual(ranked[0].chunk.content, "Exact semantic match")
        XCTAssertEqual(ranked[0].chunk.score, 0.76, accuracy: 0.001)
        XCTAssertEqual(ranked[1].chunk.score, 0.30, accuracy: 0.001)
    }

    func test_rank_recencyBoost_prefersMoreRecentChunkWhenOtherSignalsTie() {
        // Given
        let scorer = HybridScorer(
            configuration: .init(
                cosineWeight: 0.7,
                bm25Weight: 0.3,
                recencyHalfLifeDays: 14,
                maxRecencyBoost: 0.10
            )
        )

        let now = Date(timeIntervalSince1970: 1_739_600_000)
        let oldDate = now.addingTimeInterval(-90 * 86_400)
        let recentDate = now.addingTimeInterval(-1 * 86_400)

        let candidates: [HybridScorer.Candidate] = [
            .init(
                rowID: 1,
                content: "Old memory",
                documentType: .memory,
                sessionID: nil,
                sectionName: "Projects",
                lastModified: oldDate,
                bm25Score: 1.0,
                embedding: [1.0, 0.0]
            ),
            .init(
                rowID: 2,
                content: "Recent memory",
                documentType: .memory,
                sessionID: nil,
                sectionName: "Projects",
                lastModified: recentDate,
                bm25Score: 1.0,
                embedding: [1.0, 0.0]
            )
        ]

        // When
        let ranked = scorer.rank(queryEmbedding: [1.0, 0.0], candidates: candidates, now: now)

        // Then
        XCTAssertEqual(ranked.count, 2)
        XCTAssertEqual(ranked[0].chunk.content, "Recent memory")
        XCTAssertGreaterThan(ranked[0].recencyBoost, ranked[1].recencyBoost)
    }

    func test_isTopScoreAboveThreshold_lowScoringCandidates_returnsFalse() {
        // Given
        let scorer = HybridScorer(
            configuration: .init(
                cosineWeight: 0.7,
                bm25Weight: 0.3,
                recencyHalfLifeDays: 30,
                maxRecencyBoost: 0.0
            )
        )

        let candidates: [HybridScorer.Candidate] = [
            .init(
                rowID: 1,
                content: "Weak candidate",
                documentType: .memory,
                sessionID: nil,
                sectionName: "General",
                lastModified: Date(timeIntervalSince1970: 1_600_000_000),
                bm25Score: 0.0,
                embedding: [0.0, 1.0]
            )
        ]

        // When
        let ranked = scorer.rank(queryEmbedding: [1.0, 0.0], candidates: candidates)

        // Then
        XCTAssertFalse(scorer.isTopScoreAboveThreshold(ranked, threshold: 0.30))
    }
}
