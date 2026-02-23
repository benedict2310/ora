//
//  SkillFrontmatterParser.swift
//  Ora
//
//  Lightweight YAML frontmatter parser for SKILL.md.
//

import Foundation

enum SkillFrontmatterParser {

    struct Frontmatter: Equatable, Sendable {
        let name: String
        let description: String
        let version: String?
    }

    static func parse(from markdown: String) throws -> Frontmatter {
        guard let rawMap = extractMap(from: markdown) else {
            throw SkillError.invalidFrontmatter("Missing YAML frontmatter block")
        }

        let name = rawMap["name"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let description = rawMap["description"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let version = rawMap["version"]?.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !name.isEmpty else {
            throw SkillError.invalidFrontmatter("Missing required field: name")
        }

        guard !description.isEmpty else {
            throw SkillError.invalidFrontmatter("Missing required field: description")
        }

        return Frontmatter(name: name, description: description, version: version)
    }

    static func parse(from data: Data) throws -> Frontmatter {
        guard let markdown = String(data: data, encoding: .utf8) else {
            throw SkillError.invalidFrontmatter("SKILL.md is not valid UTF-8")
        }
        return try parse(from: markdown)
    }

    static func extractMap(from markdown: String) -> [String: String]? {
        let normalized = markdown.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalized.components(separatedBy: "\n")

        guard lines.first?.trimmingCharacters(in: .whitespacesAndNewlines) == "---" else {
            return nil
        }

        var map: [String: String] = [:]
        var hasClosingFence = false

        for line in lines.dropFirst() {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed == "---" {
                hasClosingFence = true
                break
            }

            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                continue
            }

            guard let colonIndex = line.firstIndex(of: ":") else {
                continue
            }

            let key = line[..<colonIndex].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            var value = line[line.index(after: colonIndex)...].trimmingCharacters(in: .whitespacesAndNewlines)

            if (value.hasPrefix("\"") && value.hasSuffix("\"")) ||
                (value.hasPrefix("'") && value.hasSuffix("'")) {
                value.removeFirst()
                value.removeLast()
            }

            if !key.isEmpty {
                map[key] = value
            }
        }

        guard hasClosingFence else {
            return nil
        }

        return map
    }
}
