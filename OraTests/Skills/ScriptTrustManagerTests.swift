//
//  ScriptTrustManagerTests.swift
//  OraTests
//

import XCTest
@testable import Ora

final class ScriptTrustManagerTests: XCTestCase {
    private var rootDirectory: URL!
    private var skillRoot: URL!

    override func setUp() async throws {
        self.rootDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScriptTrustManagerTests-\(UUID().uuidString)", isDirectory: true)
        self.skillRoot = self.rootDirectory.appendingPathComponent("trusted-skill", isDirectory: true)
        let scriptsRoot = self.skillRoot.appendingPathComponent("scripts", isDirectory: true)

        try FileManager.default.createDirectory(at: scriptsRoot, withIntermediateDirectories: true)
        try "#!/bin/bash\necho hi\n".write(
            to: scriptsRoot.appendingPathComponent("echo.sh"),
            atomically: true,
            encoding: .utf8
        )

        await MainActor.run {
            PersistenceManager.shared.clearScriptTrustRecords()
        }
    }

    override func tearDown() async throws {
        await MainActor.run {
            PersistenceManager.shared.clearScriptTrustRecords()
        }
        if let rootDirectory {
            try? FileManager.default.removeItem(at: rootDirectory)
        }
    }

    func test_grantTrust_marksUserSkillAsTrusted() async throws {
        let metadata = SkillMetadata(
            id: "trusted-skill",
            name: "Trusted Skill",
            description: "Test",
            source: .user,
            rootURL: self.skillRoot,
            version: nil,
            hasScripts: true
        )

        try await ScriptTrustManager.shared.grantTrust(
            skillID: metadata.id,
            skillRoot: metadata.rootURL
        )

        let status = try await ScriptTrustManager.shared.status(for: metadata)
        XCTAssertEqual(status.level, .trusted)
        XCTAssertEqual(status.currentHashes.count, 1)
    }

    func test_status_revokesTrustWhenScriptHashChanges() async throws {
        let metadata = SkillMetadata(
            id: "trusted-skill",
            name: "Trusted Skill",
            description: "Test",
            source: .user,
            rootURL: self.skillRoot,
            version: nil,
            hasScripts: true
        )

        try await ScriptTrustManager.shared.grantTrust(
            skillID: metadata.id,
            skillRoot: metadata.rootURL
        )

        let scriptURL = self.skillRoot
            .appendingPathComponent("scripts", isDirectory: true)
            .appendingPathComponent("echo.sh", isDirectory: false)
        try "#!/bin/bash\necho changed\n".write(to: scriptURL, atomically: true, encoding: .utf8)

        let status = try await ScriptTrustManager.shared.status(for: metadata)
        XCTAssertEqual(status.level, .untrusted)
    }
}
