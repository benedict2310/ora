//
//  ScriptAuthorizationPolicyTests.swift
//  OraTests
//

import XCTest
@testable import Ora

final class ScriptAuthorizationPolicyTests: XCTestCase {
    private var rootDirectory: URL!
    private var skillRoot: URL!
    private var scriptURL: URL!
    private var scriptHash: String!
    private let sandbox = ScriptSandbox()

    override func setUp() async throws {
        self.rootDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScriptAuthorizationPolicyTests-\(UUID().uuidString)", isDirectory: true)
        self.skillRoot = self.rootDirectory.appendingPathComponent("test-skill", isDirectory: true)
        let scriptsRoot = self.skillRoot.appendingPathComponent("scripts", isDirectory: true)
        try FileManager.default.createDirectory(at: scriptsRoot, withIntermediateDirectories: true)
        self.scriptURL = scriptsRoot.appendingPathComponent("echo.sh")
        try "#!/bin/bash\necho hi\n".write(to: self.scriptURL, atomically: true, encoding: .utf8)
        self.scriptHash = try self.sandbox.scriptHash(at: self.scriptURL)

        await MainActor.run {
            PersistenceManager.shared.clearScriptTrustRecords()
            PersistenceManager.shared.updateSettings { $0.scriptsEnabled = true }
        }
        // Explicit revoke in case clearScriptTrustRecords() leaves an in-flight
        // write from a prior test that SwiftData hasn't flushed yet.
        await ScriptTrustManager.shared.revokeTrust(skillID: "test-skill")
    }

    override func tearDown() async throws {
        await ScriptTrustManager.shared.revokeTrust(skillID: "test-skill")
        await MainActor.run {
            PersistenceManager.shared.clearScriptTrustRecords()
            PersistenceManager.shared.updateSettings { $0.scriptsEnabled = true }
        }
        try? FileManager.default.removeItem(at: self.rootDirectory)
    }

    // MARK: - Helpers

    private func makeMetadata(source: SkillMetadata.Source = .user) -> SkillMetadata {
        SkillMetadata(
            id: "test-skill",
            name: "Test Skill",
            description: "Test",
            source: source,
            rootURL: self.skillRoot,
            version: nil,
            hasScripts: true
        )
    }

    private var noManifest: ScriptManifest {
        ScriptManifest(isPresent: false, scripts: [:])
    }

    private var plainManifest: ScriptManifest {
        ScriptManifest(isPresent: true, scripts: [
            "echo.sh": ScriptManifest.ScriptConfig(
                description: nil,
                arguments: [],
                output: .text,
                timeout: 30,
                capabilities: [],
                declaredInManifest: true
            )
        ])
    }

    private var networkManifest: ScriptManifest {
        ScriptManifest(isPresent: true, scripts: [
            "echo.sh": ScriptManifest.ScriptConfig(
                description: nil,
                arguments: [],
                output: .text,
                timeout: 30,
                capabilities: ["network"],
                declaredInManifest: true
            )
        ])
    }

    private func evaluate(
        metadata: SkillMetadata,
        manifest: ScriptManifest,
        hash: String? = nil
    ) async throws -> ScriptAuthorizationPolicy.Evaluation {
        let policy = ScriptAuthorizationPolicy(trustManager: .shared)
        let config = manifest.config(for: "echo.sh")
        return try await policy.evaluate(
            metadata: metadata,
            scriptName: "echo.sh",
            scriptHash: hash ?? self.scriptHash,
            args: [],
            manifest: manifest,
            config: config
        )
    }

    // MARK: - Tests

    func test_bundledSkill_requiresNoPrompt() async throws {
        let eval = try await self.evaluate(metadata: makeMetadata(source: .bundled), manifest: noManifest)
        XCTAssertEqual(eval.requirement, .none)
    }

    func test_untrustedUserSkill_promptsWithTrustOption() async throws {
        let eval = try await self.evaluate(metadata: makeMetadata(source: .user), manifest: noManifest)
        guard case .userConfirmation(let prompt) = eval.requirement else {
            return XCTFail("Expected userConfirmation, got \(eval.requirement)")
        }
        XCTAssertNotNil(prompt.trustLabel, "Untrusted user skill must offer a trust option")
    }

    func test_trustedUserSkill_noNetworkCapability_requiresNoPrompt() async throws {
        let metadata = makeMetadata(source: .user)
        try await ScriptTrustManager.shared.grantTrust(skillID: metadata.id, skillRoot: metadata.rootURL)

        let eval = try await self.evaluate(metadata: metadata, manifest: plainManifest)
        XCTAssertEqual(eval.requirement, .none)
    }

    func test_trustedUserSkill_networkCapability_notYetAcknowledged_prompts() async throws {
        let metadata = makeMetadata(source: .user)
        try await ScriptTrustManager.shared.grantTrust(skillID: metadata.id, skillRoot: metadata.rootURL)

        let eval = try await self.evaluate(metadata: metadata, manifest: networkManifest)
        guard case .userConfirmation(let prompt) = eval.requirement else {
            return XCTFail("Expected userConfirmation for unacknowledged network warning, got \(eval.requirement)")
        }
        // Already trusted — should not offer re-grant
        XCTAssertNil(prompt.trustLabel, "Trusted skill with pending network warning must not offer re-trust")
    }

    func test_trustedUserSkill_networkCapability_alreadyAcknowledged_requiresNoPrompt() async throws {
        let metadata = makeMetadata(source: .user)
        try await ScriptTrustManager.shared.grantTrust(
            skillID: metadata.id,
            skillRoot: metadata.rootURL,
            acknowledgedNetworkHashes: [self.scriptHash]
        )

        let eval = try await self.evaluate(metadata: metadata, manifest: networkManifest)
        XCTAssertEqual(eval.requirement, .none)
    }

    func test_hashMismatch_promptsAfterAutoRevoke() async throws {
        let metadata = makeMetadata(source: .user)
        try await ScriptTrustManager.shared.grantTrust(skillID: metadata.id, skillRoot: metadata.rootURL)

        // Simulate script modification between authorization and execution
        try "#!/bin/bash\necho changed\n".write(to: self.scriptURL, atomically: true, encoding: .utf8)
        let newHash = try self.sandbox.scriptHash(at: self.scriptURL)

        let eval = try await self.evaluate(metadata: metadata, manifest: noManifest, hash: newHash)
        guard case .userConfirmation = eval.requirement else {
            return XCTFail("Expected userConfirmation after hash mismatch, got \(eval.requirement)")
        }
    }

    func test_scriptsDisabled_throwsError() async throws {
        await MainActor.run { PersistenceManager.shared.settings.scriptsEnabled = false }

        do {
            _ = try await self.evaluate(metadata: makeMetadata(source: .bundled), manifest: noManifest)
            XCTFail("Expected ScriptAuthorizationPolicyError.scriptsDisabled")
        } catch let error as ScriptAuthorizationPolicyError {
            XCTAssertEqual(error, .scriptsDisabled)
        }
    }

    func test_noManifest_impliesNetworkWarning() async throws {
        // When no manifest is present, network access is unknown → warning assumed
        let metadata = makeMetadata(source: .user)
        try await ScriptTrustManager.shared.grantTrust(skillID: metadata.id, skillRoot: metadata.rootURL)

        // No manifest (isPresent: false) → requiresNetworkWarning = true
        let eval = try await self.evaluate(metadata: metadata, manifest: noManifest)
        guard case .userConfirmation = eval.requirement else {
            return XCTFail("Trusted skill with no manifest should still require network-warning confirmation")
        }
    }
}
