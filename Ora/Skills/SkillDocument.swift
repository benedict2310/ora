//
//  SkillDocument.swift
//  Ora
//
//  Full skill document payload.
//

import Foundation

struct SkillDocument: Sendable {
    let meta: SkillMetadata
    let markdown: String
}
