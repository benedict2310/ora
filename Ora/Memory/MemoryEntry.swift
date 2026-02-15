//
//  MemoryEntry.swift
//  Ora
//
//  Typed memory entry persisted in MEMORY.md.
//

import Foundation

struct MemoryEntry: Sendable, Equatable {

    // MARK: - Nested Types

    enum Section: String, CaseIterable, Sendable {
        case profile
        case preferences
        case people
        case projects
        case ongoingGoals

        var heading: String {
            switch self {
            case .profile:
                return "## Profile"
            case .preferences:
                return "## Preferences"
            case .people:
                return "## People"
            case .projects:
                return "## Projects"
            case .ongoingGoals:
                return "## Ongoing Goals"
            }
        }

        init?(rawSection: String) {
            let normalized = rawSection
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
                .replacingOccurrences(of: "_", with: "")
                .replacingOccurrences(of: "-", with: "")
                .replacingOccurrences(of: " ", with: "")

            switch normalized {
            case "profile":
                self = .profile
            case "preference", "preferences":
                self = .preferences
            case "people", "person":
                self = .people
            case "project", "projects":
                self = .projects
            case "ongoinggoal", "ongoinggoals", "goals":
                self = .ongoingGoals
            default:
                return nil
            }
        }
    }

    enum Tag: String, Sendable {
        case fact
        case preference
        case factSensitive

        var marker: String {
            switch self {
            case .fact:
                return "[fact]"
            case .preference:
                return "[preference]"
            case .factSensitive:
                return "[fact][sensitive]"
            }
        }

        init?(rawTag: String) {
            let normalized = rawTag
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
                .replacingOccurrences(of: "_", with: "")
                .replacingOccurrences(of: "-", with: "")
                .replacingOccurrences(of: " ", with: "")
                .replacingOccurrences(of: "[", with: "")
                .replacingOccurrences(of: "]", with: "")

            switch normalized {
            case "fact":
                self = .fact
            case "preference":
                self = .preference
            case "factsensitive":
                self = .factSensitive
            default:
                return nil
            }
        }
    }

    // MARK: - Properties

    let section: Section
    let tag: Tag
    let content: String
    let sourceSessionID: UUID
    let timestamp: Date
    let normalizedKey: String?

    var normalizedKeyToken: String? {
        guard let normalizedKey else {
            return nil
        }
        let token = normalizedKey
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return token.isEmpty ? nil : token
    }

    var linePrefix: String {
        "\(self.tag.marker) \(self.content.trimmingCharacters(in: .whitespacesAndNewlines))"
    }

    var renderedLine: String {
        let timestamp = Self.formatTimestamp(self.timestamp)
        return "- \(self.linePrefix) (source: \(self.sourceSessionID.uuidString) @ \(timestamp))"
    }

    var dedupFingerprint: String {
        let normalizedPrefix = Self.normalizeForDedup(self.linePrefix)
        return "\(self.section.rawValue)|\(normalizedPrefix)"
    }

    // MARK: - Initialization

    init(
        section: Section,
        tag: Tag,
        content: String,
        sourceSessionID: UUID,
        timestamp: Date,
        normalizedKey: String? = nil
    ) {
        self.section = section
        self.tag = tag
        self.content = content.trimmingCharacters(in: .whitespacesAndNewlines)
        self.sourceSessionID = sourceSessionID
        self.timestamp = timestamp
        self.normalizedKey = normalizedKey
    }

    // MARK: - Helpers

    static func normalizeForDedup(_ text: String) -> String {
        text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }

    private static func formatTimestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}
