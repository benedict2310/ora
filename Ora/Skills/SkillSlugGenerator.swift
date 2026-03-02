//
//  SkillSlugGenerator.swift
//  Ora
//
//  Generates stable, filesystem-safe skill identifiers.
//

import Foundation

struct SkillSlugGenerator {

    // MARK: - Constants

    static let maxLength = 40

    private static let reservedSlugs: Set<String> = [
        ".", "..", "assets", "references", "scripts"
    ]

    // MARK: - Public API

    static func slug(from name: String) throws -> String {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            throw SkillError.invalidName
        }

        let transliterated = trimmedName.applyingTransform(.toLatin, reverse: false) ?? trimmedName
        let normalized = transliterated.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )

        let hyphenated = normalized
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))

        let truncated = String(hyphenated.prefix(Self.maxLength))
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))

        guard !truncated.isEmpty else {
            throw SkillError.invalidName
        }

        guard !Self.reservedSlugs.contains(truncated) else {
            throw SkillError.reservedID(truncated)
        }

        return truncated
    }

    static func resolveUniqueSlug(
        from name: String,
        existingAgentIDs: Set<String>,
        blockedIDs: [String: SkillMetadata.Source]
    ) throws -> String {
        let base = try Self.slug(from: name)

        if let source = blockedIDs[base] {
            throw SkillError.idConflict(base, source)
        }

        guard existingAgentIDs.contains(base) else {
            return base
        }

        for suffix in 2...9 {
            let candidate = Self.candidate(base: base, suffix: suffix)
            guard !Self.reservedSlugs.contains(candidate) else {
                continue
            }
            if blockedIDs[candidate] != nil || existingAgentIDs.contains(candidate) {
                continue
            }
            return candidate
        }

        throw SkillError.slugExhausted(base)
    }

    // MARK: - Private

    private static func candidate(base: String, suffix: Int) -> String {
        let suffixText = "-\(suffix)"
        let remainingLength = max(1, Self.maxLength - suffixText.count)
        let trimmedBase = String(base.prefix(remainingLength))
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return "\(trimmedBase)\(suffixText)"
    }
}
