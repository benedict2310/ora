//
//  SessionSummaryTests.swift
//  OraTests
//
//  Tests for summary template markdown rendering.
//

import XCTest
@testable import Ora

final class SessionSummaryTests: XCTestCase {

    // MARK: - Tests

    func test_renderMarkdown_populatedSummary_includesAllSectionsAndContent() {
        // Given
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let summary = SessionSummary(
            tldr: "Discussed launch priorities and next steps.",
            bullets: [
                "Reviewed memory system milestones.",
                "Prioritized summary rendering for this sprint."
            ],
            decisionsAndCommitments: [
                SessionSummary.DecisionCommitment(
                    decision: "Ship MEM.07 this sprint",
                    rationale: "Unlocks MEM.08 integration with a stable format.",
                    timestamp: timestamp
                )
            ],
            openLoops: [
                "Who owns final QA verification?"
            ]
        )

        // When
        let markdown = summary.renderMarkdown()

        // Then
        XCTAssertTrue(markdown.contains("## TL;DR"))
        XCTAssertTrue(markdown.contains("Discussed launch priorities and next steps."))
        XCTAssertTrue(markdown.contains("## Bullets"))
        XCTAssertTrue(markdown.contains("- Reviewed memory system milestones."))
        XCTAssertTrue(markdown.contains("## Decisions & Commitments"))
        XCTAssertTrue(markdown.contains("1. **Decision:** Ship MEM.07 this sprint"))
        XCTAssertTrue(markdown.contains("**Rationale:** Unlocks MEM.08 integration with a stable format."))
        XCTAssertTrue(markdown.contains("**Timestamp:** 2023-11-14 22:13 UTC"))
        XCTAssertTrue(markdown.contains("## Open Loops"))
        XCTAssertTrue(markdown.contains("- Who owns final QA verification?"))
    }

    func test_renderMarkdown_emptySummary_includesAllSectionsWithPlaceholders() {
        // Given
        let summary = SessionSummary()

        // When
        let markdown = summary.renderMarkdown()

        // Then
        XCTAssertTrue(markdown.contains("# Session Summary"))
        XCTAssertTrue(markdown.contains("## TL;DR"))
        XCTAssertTrue(markdown.contains("_No TL;DR yet._"))
        XCTAssertTrue(markdown.contains("## Bullets"))
        XCTAssertTrue(markdown.contains("- _No key points yet._"))
        XCTAssertTrue(markdown.contains("## Decisions & Commitments"))
        XCTAssertTrue(markdown.contains("- _No decisions or commitments yet._"))
        XCTAssertTrue(markdown.contains("## Open Loops"))
        XCTAssertTrue(markdown.contains("- _No open loops yet._"))
    }

    func test_placeholder_defaultPlaceholder_containsPendingMessage() {
        // Given
        let summary = SessionSummary.placeholder

        // When
        let markdown = summary.renderMarkdown()

        // Then
        XCTAssertTrue(markdown.contains("Summary pending. Ora will distill this conversation in a later pass."))
        XCTAssertTrue(markdown.contains("- Placeholder summary created for this session."))
    }
}
