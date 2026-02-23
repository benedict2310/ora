//
//  SkillsFeatureGate.swift
//  Ora
//
//  Central feature toggle checks for skills runtime.
//

import Foundation

enum SkillsFeatureGate {

    static func isEnabled() async -> Bool {
        return await MainActor.run {
            PersistenceManager.shared.settings.skillsEnabled
        }
    }

    static func requireEnabled() async throws {
        let enabled = await isEnabled()
        if !enabled {
            throw SkillError.featureDisabled
        }
    }
}
