//
//  SkillsRunScriptToolTests.swift
//  OraTests
//

import XCTest
@testable import Ora

final class SkillsRunScriptToolTests: XCTestCase {
    private var rootDirectory: URL!
    private var bundledRoot: URL!
    private var userRoot: URL!
    private var store: SkillStore!

    override func setUp() async throws {
        self.rootDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SkillsRunScriptToolTests-\(UUID().uuidString)", isDirectory: true)
        self.bundledRoot = self.rootDirectory.appendingPathComponent("bundled", isDirectory: true)
        self.userRoot = self.rootDirectory.appendingPathComponent("user", isDirectory: true)

        try FileManager.default.createDirectory(at: self.bundledRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: self.userRoot, withIntermediateDirectories: true)

        try self.writeSkill(
            root: self.bundledRoot,
            id: "bundled-script",
            scriptName: "echo.sh",
            scriptContents: "#!/bin/bash\necho hello\n"
        )
        try self.writeSkill(
            root: self.userRoot,
            id: "user-script",
            scriptName: "payload.sh",
            scriptContents: "#!/bin/bash\nprintf '{\"ok\":true}'\n",
            manifest: """
            {
              "scripts": {
                "payload.sh": {
                  "output": "json",
                  "timeout": 5
                }
              }
            }
            """
        )

        self.store = SkillStore.makeTestInstance(roots: .init(bundled: self.bundledRoot, user: self.userRoot))
        await self.store.rebuildIndex()

        await MainActor.run {
            PersistenceManager.shared.updateSettings { settings in
                settings.skillsEnabled = true
                settings.scriptsEnabled = true
            }
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

    func test_authorizationPlan_bundledSkill_autoAllows() async throws {
        let tool = SkillsRunScriptTool(skillStore: self.store)

        let plan = try await tool.authorizationPlan(args: [
            "skill_id": .string("bundled-script"),
            "script": .string("echo.sh")
        ])

        XCTAssertEqual(plan.requirement, .none)
    }

    func test_authorizationPlan_untrustedUserSkill_requiresPromptWithTrustOption() async throws {
        let tool = SkillsRunScriptTool(skillStore: self.store)

        let plan = try await tool.authorizationPlan(args: [
            "skill_id": .string("user-script"),
            "script": .string("payload.sh")
        ])

        guard case .userConfirmation(let prompt) = plan.requirement else {
            return XCTFail("Expected interactive prompt")
        }

        XCTAssertEqual(prompt.trustLabel, "Run + Trust")
        XCTAssertEqual(prompt.confirmLabel, "Run Once")
    }

    func test_execute_jsonScript_returnsStructuredOutput() async throws {
        let tool = SkillsRunScriptTool(skillStore: self.store)

        let result = try await tool.execute(args: [
            "skill_id": .string("user-script"),
            "script": .string("payload.sh")
        ])

        guard case .object(let payload) = result.json else {
            return XCTFail("Expected object payload")
        }

        XCTAssertEqual(payload["exit_code"]?.numberValue, 0)
        XCTAssertEqual(payload["output"]?.objectValue?["ok"]?.boolValue, true)
    }

    private func writeSkill(
        root: URL,
        id: String,
        scriptName: String,
        scriptContents: String,
        manifest: String? = nil
    ) throws {
        let skillRoot = root.appendingPathComponent(id, isDirectory: true)
        let scriptsRoot = skillRoot.appendingPathComponent("scripts", isDirectory: true)
        try FileManager.default.createDirectory(at: scriptsRoot, withIntermediateDirectories: true)

        try """
        ---
        name: \(id)
        description: Test skill
        ---

        Script skill
        """.write(
            to: skillRoot.appendingPathComponent("SKILL.md"),
            atomically: true,
            encoding: .utf8
        )

        try scriptContents.write(
            to: scriptsRoot.appendingPathComponent(scriptName),
            atomically: true,
            encoding: .utf8
        )

        if let manifest {
            try manifest.write(
                to: scriptsRoot.appendingPathComponent("manifest.json"),
                atomically: true,
                encoding: .utf8
            )
        }
    }
}
