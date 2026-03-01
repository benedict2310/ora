//
//  ScriptAuthorizationPolicy.swift
//  Ora
//
//  Maps script trust state and manifest metadata into authorization requirements.
//

import Foundation

struct ScriptAuthorizationPolicy: Sendable {
    struct Evaluation: Sendable {
        let requirement: ToolAuthorizationRequirement
        let auditMetadata: [String: String]
        let context: [String: JSONValue]
    }

    let trustManager: ScriptTrustManager

    init(trustManager: ScriptTrustManager = .shared) {
        self.trustManager = trustManager
    }

    func evaluate(
        metadata: SkillMetadata,
        scriptName: String,
        scriptHash: String,
        args: [String],
        manifest: ScriptManifest,
        config: ScriptManifest.ScriptConfig
    ) async throws -> Evaluation {
        let scriptsEnabled = await MainActor.run {
            PersistenceManager.shared.settings.scriptsEnabled
        }
        guard scriptsEnabled else {
            throw ScriptAuthorizationPolicyError.scriptsDisabled
        }

        let trustStatus = try await self.trustManager.status(for: metadata)
        let requiresNetworkWarning = (!manifest.isPresent) || config.capabilities.contains("network")
        let networkAlreadyAcknowledged = trustStatus.acknowledgedNetworkHashes.contains(scriptHash)

        let promptNeeded: Bool
        let allowsTrustGrant: Bool

        switch trustStatus.level {
        case .bundled:
            promptNeeded = false
            allowsTrustGrant = false
        case .trusted:
            promptNeeded = requiresNetworkWarning && !networkAlreadyAcknowledged
            allowsTrustGrant = false
        case .untrusted:
            promptNeeded = true
            allowsTrustGrant = metadata.source == .user
        }

        let details = Self.promptDetails(
            metadata: metadata,
            scriptName: scriptName,
            args: args,
            requiresNetworkWarning: requiresNetworkWarning
        )

        let requirement: ToolAuthorizationRequirement
        if promptNeeded {
            requirement = .userConfirmation(
                prompt: ToolAuthorizationPrompt(
                    title: "Run Script?",
                    summary: "Run \(scriptName) from skill '\(metadata.name)'?",
                    details: details,
                    confirmLabel: allowsTrustGrant ? "Run Once" : "Run Script",
                    cancelLabel: "Cancel",
                    trustLabel: allowsTrustGrant ? "Run + Trust" : nil
                )
            )
        } else {
            requirement = .none
        }

        return Evaluation(
            requirement: requirement,
            auditMetadata: [
                "skill_id": metadata.id,
                "skill_source": metadata.source.rawValue,
                "script": scriptName,
                "script_hash": scriptHash,
                "trust_level": trustStatus.level.rawValue,
                "network_warning": requiresNetworkWarning ? "true" : "false"
            ],
            context: [
                "script_hash": .string(scriptHash),
                "requires_network_warning": .bool(requiresNetworkWarning)
            ]
        )
    }

    private static func promptDetails(
        metadata: SkillMetadata,
        scriptName: String,
        args: [String],
        requiresNetworkWarning: Bool
    ) -> String {
        var lines = [
            "Skill: \(metadata.id) (\(metadata.source.rawValue))",
            "Script: \(scriptName)",
            "Args: \(args.isEmpty ? "[]" : args.joined(separator: ", "))",
            "This script will run with your user permissions."
        ]

        if requiresNetworkWarning {
            lines.append("Warning: this script will have unrestricted network access, including local network hosts.")
        }

        return lines.joined(separator: "\n")
    }
}

enum ScriptAuthorizationPolicyError: LocalizedError, Equatable {
    case scriptsDisabled

    var errorDescription: String? {
        switch self {
        case .scriptsDisabled:
            return "Script execution is disabled in Preferences."
        }
    }
}
