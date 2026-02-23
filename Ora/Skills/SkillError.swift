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
        }
    }
}
