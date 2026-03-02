//
//  SkillError.swift
//  Ora
//
//  Skills runtime errors.
//

import Foundation

enum SkillError: LocalizedError, Equatable {
    case notFound
    case invalidFrontmatter(String)
    case invalidPath(String)
    case fileTooLarge
    case featureDisabled
    case invalidName
    case invalidDescription
    case reservedID(String)
    case idConflict(String, SkillMetadata.Source)
    case immutableSource(String, SkillMetadata.Source)
    case slugExhausted(String)

    var errorDescription: String? {
        switch self {
        case .notFound:
            return "Skill not found."
        case .invalidFrontmatter(let reason):
            return "Invalid skill frontmatter: \(reason)"
        case .invalidPath(let path):
            return "Invalid skill file path: \(path)"
        case .fileTooLarge:
            return "Skill file is too large."
        case .featureDisabled:
            return "Skills feature is disabled."
        case .invalidName:
            return "Skill name must not be empty."
        case .invalidDescription:
            return "Skill description must not be empty."
        case .reservedID(let id):
            return "Skill id '\(id)' is reserved."
        case .idConflict(let id, let source):
            return "Skill id '\(id)' conflicts with an existing \(source.rawValue) skill."
        case .immutableSource(let id, let source):
            return "Skill '\(id)' is \(source.rawValue) and cannot be modified by Ora."
        case .slugExhausted(let slug):
            return "Unable to create a unique skill id for '\(slug)'."
        }
    }
}
