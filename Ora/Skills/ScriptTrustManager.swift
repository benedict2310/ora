//
//  ScriptTrustManager.swift
//  Ora
//
//  Persists and validates trust state for user-installed skill scripts.
//

import Foundation

actor ScriptTrustManager {
    enum TrustLevel: String, Sendable {
        case bundled
        case trusted
        case untrusted
    }

    struct Status: Sendable {
        let level: TrustLevel
        let currentHashes: [String: String]
        let storedHashes: [String: String]
        let acknowledgedNetworkHashes: Set<String>
    }

    static let shared = ScriptTrustManager()

    private let sandbox: ScriptSandbox

    init(sandbox: ScriptSandbox = ScriptSandbox()) {
        self.sandbox = sandbox
    }

    func status(for metadata: SkillMetadata) async throws -> Status {
        let currentHashes = try self.currentHashes(for: metadata.rootURL)

        if metadata.source == .bundled {
            return Status(
                level: .bundled,
                currentHashes: currentHashes,
                storedHashes: currentHashes,
                acknowledgedNetworkHashes: Set(currentHashes.values)
            )
        }

        let persisted = await MainActor.run { () -> (storedHashes: [String: String], acknowledged: Set<String>)? in
            guard let record = PersistenceManager.shared.scriptTrustRecord(skillID: metadata.id) else {
                return nil
            }
            return (record.scriptHashes, record.acknowledgedNetworkHashes)
        }

        guard let persisted else {
            return Status(
                level: .untrusted,
                currentHashes: currentHashes,
                storedHashes: [:],
                acknowledgedNetworkHashes: []
            )
        }

        let storedHashes = persisted.storedHashes
        if storedHashes != currentHashes {
            await MainActor.run {
                PersistenceManager.shared.deleteScriptTrustRecord(skillID: metadata.id)
            }
            return Status(
                level: .untrusted,
                currentHashes: currentHashes,
                storedHashes: storedHashes,
                acknowledgedNetworkHashes: []
            )
        }

        return Status(
            level: .trusted,
            currentHashes: currentHashes,
            storedHashes: storedHashes,
            acknowledgedNetworkHashes: persisted.acknowledged
        )
    }

    func grantTrust(skillID: String, skillRoot: URL, acknowledgedNetworkHashes: Set<String> = []) async throws {
        let hashes = try self.currentHashes(for: skillRoot)
        await MainActor.run {
            PersistenceManager.shared.upsertScriptTrustRecord(
                skillID: skillID,
                scriptHashes: hashes,
                acknowledgedNetworkHashes: acknowledgedNetworkHashes
            )
        }
    }

    func revokeTrust(skillID: String) async {
        await MainActor.run {
            PersistenceManager.shared.deleteScriptTrustRecord(skillID: skillID)
        }
    }

    func acknowledgeNetworkWarning(skillID: String, scriptHash: String) async {
        await MainActor.run {
            let existing = PersistenceManager.shared.scriptTrustRecord(skillID: skillID)
            let hashes = existing?.scriptHashes ?? [:]
            var acknowledged = existing?.acknowledgedNetworkHashes ?? []
            acknowledged.insert(scriptHash)
            PersistenceManager.shared.upsertScriptTrustRecord(
                skillID: skillID,
                scriptHashes: hashes,
                acknowledgedNetworkHashes: acknowledged,
                trustedAt: existing?.trustedAt ?? Date()
            )
        }
    }
    private func currentHashes(for skillRoot: URL) throws -> [String: String] {
        let scripts = try self.sandbox.listScripts(skillRoot: skillRoot)
        var hashes: [String: String] = [:]
        for script in scripts {
            hashes[script.lastPathComponent] = try self.sandbox.scriptHash(at: script)
        }
        return hashes
    }
}
