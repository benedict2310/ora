//
//  SkillMetadata.swift
//  Ora
//
//  Metadata for discovered skills.
//

import Foundation

struct SkillMetadata: Sendable, Codable, Hashable {
    enum Source: String, Codable, Sendable {
        case bundled
        case user
        case agent
    }

    let id: String
    let name: String
    let description: String
    let source: Source
    let rootURL: URL
    let version: String?
    let hasScripts: Bool
}
