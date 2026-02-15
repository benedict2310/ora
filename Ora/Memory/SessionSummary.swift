//
//  SessionSummary.swift
//  Ora
//
//  Structured session summary template rendered as markdown.
//

import Foundation

struct SessionSummary: Codable, Sendable, Equatable {

    // MARK: - Nested Types

    struct DecisionCommitment: Codable, Sendable, Equatable {
        let decision: String
        let rationale: String
        let timestamp: Date
    }

    // MARK: - Properties

    let tldr: String
    let bullets: [String]
    let decisionsAndCommitments: [DecisionCommitment]
    let openLoops: [String]

    // MARK: - Initialization

    init(
        tldr: String = "",
        bullets: [String] = [],
        decisionsAndCommitments: [DecisionCommitment] = [],
        openLoops: [String] = []
    ) {
        self.tldr = tldr
        self.bullets = bullets
        self.decisionsAndCommitments = decisionsAndCommitments
        self.openLoops = openLoops
    }

    // MARK: - Factory

    static var placeholder: SessionSummary {
        return SessionSummary(
            tldr: "Summary pending. Ora will distill this conversation in a later pass.",
            bullets: [
                "Placeholder summary created for this session."
            ]
        )
    }

    // MARK: - Rendering

    func renderMarkdown() -> String {
        let sections = [
            "# Session Summary",
            "",
            "## TL;DR",
            self.renderTLDR(),
            "",
            "## Bullets",
            self.renderBullets(),
            "",
            "## Decisions & Commitments",
            self.renderDecisionsAndCommitments(),
            "",
            "## Open Loops",
            self.renderOpenLoops()
        ]

        return sections.joined(separator: "\n")
    }

    // MARK: - Private Rendering Helpers

    private func renderTLDR() -> String {
        let normalizedTLDR = self.tldr.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalizedTLDR.isEmpty {
            return "_No TL;DR yet._"
        }
        return normalizedTLDR
    }

    private func renderBullets() -> String {
        guard !self.bullets.isEmpty else {
            return "- _No key points yet._"
        }
        return self.bullets
            .map { "- \($0.trimmingCharacters(in: .whitespacesAndNewlines))" }
            .joined(separator: "\n")
    }

    private func renderDecisionsAndCommitments() -> String {
        guard !self.decisionsAndCommitments.isEmpty else {
            return "- _No decisions or commitments yet._"
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd HH:mm 'UTC'"

        return self.decisionsAndCommitments.enumerated().map { index, item in
            let timestamp = formatter.string(from: item.timestamp)
            return [
                "\(index + 1). **Decision:** \(item.decision)",
                "   **Rationale:** \(item.rationale)",
                "   **Timestamp:** \(timestamp)"
            ].joined(separator: "\n")
        }.joined(separator: "\n\n")
    }

    private func renderOpenLoops() -> String {
        guard !self.openLoops.isEmpty else {
            return "- _No open loops yet._"
        }
        return self.openLoops
            .map { "- \($0.trimmingCharacters(in: .whitespacesAndNewlines))" }
            .joined(separator: "\n")
    }

}
