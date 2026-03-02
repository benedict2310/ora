//
//  SkillAuthoringToolsTests.swift
//  OraTests
//

import XCTest
@testable import Ora

final class SkillAuthoringToolsTests: XCTestCase {

    private var rootDirectory: URL!
    private var bundledRoot: URL!
    private var userRoot: URL!
    private var agentRoot: URL!
    private var store: SkillStore!

    override func setUp() async throws {
        self.rootDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SkillAuthoringToolsTests-\(UUID().uuidString)", isDirectory: true)
        self.bundledRoot = self.rootDirectory.appendingPathComponent("bundled", isDirectory: true)
        self.userRoot = self.rootDirectory.appendingPathComponent("user", isDirectory: true)
        self.agentRoot = self.rootDirectory.appendingPathComponent("agent", isDirectory: true)

        try FileManager.default.createDirectory(at: self.bundledRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: self.userRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: self.agentRoot, withIntermediateDirectories: true)

        self.store = SkillStore.makeTestInstance(
            roots: .init(bundled: self.bundledRoot, user: self.userRoot, agent: self.agentRoot)
        )
        await self.store.rebuildIndex()

        await MainActor.run {
            PersistenceManager.shared.updateSettings { settings in
                settings.skillsEnabled = true
            }
        }

        await ToolRegistry.shared.clear()
        await AuditLogger.shared.clearAll()
    }

    override func tearDown() async throws {
        await ToolRegistry.shared.clear()
        if let rootDirectory = self.rootDirectory {
            try? FileManager.default.removeItem(at: rootDirectory)
        }
    }

    func test_create_writesSanitizedSkillAndRebuildsIndex() async throws {
        let tool = SkillsCreateTool(skillStore: self.store)
        let args = self.createArguments(name: "Monday Planning Routine", content: """
        ---
        name: Monday Planning Routine
        description: Reviews the week.\u{0007}
        version: 1.0
        ---

        # Monday Planning Routine

        Review the week.\u{0008}
        """)

        let plan = try await tool.authorizationPlan(args: args)
        guard case .userConfirmation(let prompt) = plan.requirement else {
            return XCTFail("Expected confirmation prompt")
        }
        guard case .skillDocumentPreview(let preview) = prompt.presentation else {
            return XCTFail("Expected modal document preview")
        }
        XCTAssertFalse(preview.contains("\u{0007}"))
        XCTAssertFalse(preview.contains("\u{0008}"))

        let result = try await tool.execute(args: args)
        guard case .object(let payload) = result.json else {
            return XCTFail("Expected object result")
        }

        XCTAssertEqual(payload["id"]?.stringValue, "monday-planning-routine")
        XCTAssertEqual(payload["source"]?.stringValue, "agent")

        let skillFile = self.agentRoot
            .appendingPathComponent("monday-planning-routine", isDirectory: true)
            .appendingPathComponent("SKILL.md", isDirectory: false)
        let written = try String(contentsOf: skillFile, encoding: .utf8)
        XCTAssertFalse(written.contains("\u{0007}"))
        XCTAssertFalse(written.contains("\u{0008}"))

        let skills = await self.store.list()
        XCTAssertTrue(skills.contains(where: { $0.id == "monday-planning-routine" && $0.source == .agent }))
    }

    func test_create_existingAgentSlug_appendsNumericSuffix() async throws {
        try self.writeSkill(root: self.agentRoot, id: "monday-planning-routine", name: "Monday Planning Routine", description: "Existing")
        await self.store.rebuildIndex()

        let tool = SkillsCreateTool(skillStore: self.store)
        let result = try await tool.execute(args: self.createArguments(name: "Monday Planning Routine"))

        guard case .object(let payload) = result.json else {
            return XCTFail("Expected object result")
        }
        XCTAssertEqual(payload["id"]?.stringValue, "monday-planning-routine-2")
    }

    func test_create_conflictingBundledSlug_returnsConflictError() async throws {
        try self.writeSkill(root: self.bundledRoot, id: "daily-briefing", name: "Daily Briefing", description: "Bundled")
        await self.store.rebuildIndex()

        let tool = SkillsCreateTool(skillStore: self.store)

        do {
            _ = try await tool.execute(args: self.createArguments(name: "Daily Briefing"))
            XCTFail("Expected conflict error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("conflicts with an existing bundled skill"))
        }
    }

    func test_update_overwritesAgentSkill_andRejectsNonExactIDs() async throws {
        try self.writeSkill(root: self.agentRoot, id: "weekly-planning", name: "Weekly Planning", description: "Old")
        await self.store.rebuildIndex()

        let tool = SkillsUpdateTool(skillStore: self.store)
        let updatedContent = """
        ---
        name: Weekly Planning
        description: Updated description
        version: 2.0
        ---

        # Weekly Planning

        Updated body.
        """

        let plan = try await tool.authorizationPlan(args: [
            "id": .string("weekly-planning"),
            "content": .string(updatedContent)
        ])
        guard case .userConfirmation(let prompt) = plan.requirement else {
            return XCTFail("Expected confirmation prompt")
        }
        guard case .skillDocumentPreview = prompt.presentation else {
            return XCTFail("Expected document preview")
        }

        _ = try await tool.execute(args: [
            "id": .string("weekly-planning"),
            "content": .string(updatedContent)
        ])

        let updatedFile = self.agentRoot
            .appendingPathComponent("weekly-planning", isDirectory: true)
            .appendingPathComponent("SKILL.md", isDirectory: false)
        let written = try String(contentsOf: updatedFile, encoding: .utf8)
        XCTAssertTrue(written.contains("Updated description"))

        do {
            _ = try await tool.execute(args: [
                "id": .string("weekly planning"),
                "content": .string(updatedContent)
            ])
            XCTFail("Expected exact-id failure")
        } catch {
            XCTAssertEqual(error.localizedDescription, "Skill not found.")
        }
    }

    func test_update_rejectsBundledSkill() async throws {
        try self.writeSkill(root: self.bundledRoot, id: "daily-briefing", name: "Daily Briefing", description: "Bundled")
        await self.store.rebuildIndex()

        let tool = SkillsUpdateTool(skillStore: self.store)

        do {
            _ = try await tool.authorizationPlan(args: [
                "id": .string("daily-briefing"),
                "content": .string(self.validContent(name: "Daily Briefing", description: "Bundled"))
            ])
            XCTFail("Expected immutable source error")
        } catch let error as SkillError {
            XCTAssertEqual(error, .immutableSource("daily-briefing", .bundled))
        }
    }

    func test_delete_removesAgentSkill_andRejectsNonExactIDs() async throws {
        try self.writeSkill(root: self.agentRoot, id: "weekly-planning", name: "Weekly Planning", description: "Delete me")
        await self.store.rebuildIndex()

        let tool = SkillsDeleteTool(skillStore: self.store)

        let plan = try await tool.authorizationPlan(args: ["id": .string("weekly-planning")])
        guard case .userConfirmation(let prompt) = plan.requirement else {
            return XCTFail("Expected confirmation prompt")
        }
        guard case .skillDeletion(let name, let description) = prompt.presentation else {
            return XCTFail("Expected delete preview")
        }
        XCTAssertEqual(name, "Weekly Planning")
        XCTAssertEqual(description, "Delete me")

        _ = try await tool.execute(args: ["id": .string("weekly-planning")])
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: self.agentRoot.appendingPathComponent("weekly-planning", isDirectory: true).path
            )
        )

        do {
            _ = try await tool.execute(args: ["id": .string("weekly planning")])
            XCTFail("Expected exact-id failure")
        } catch {
            XCTAssertEqual(error.localizedDescription, "Skill not found.")
        }
    }

    func test_toolHost_recordsAuthoringAuditEntriesWithContentHash() async throws {
        let createContent = self.validContent(name: "Weekly Planning", description: "Reviews the week")
        let updatedContent = self.validContent(name: "Weekly Planning", description: "Updated review")

        await ToolRegistry.shared.register(SkillsCreateTool(skillStore: self.store))
        await ToolRegistry.shared.register(SkillsUpdateTool(skillStore: self.store))
        await ToolRegistry.shared.register(SkillsDeleteTool(skillStore: self.store))

        let createExecution = try await ToolHost.shared.executeWithAudit(
            toolName: "skills.create",
            args: self.createArguments(name: "Weekly Planning", description: "Reviews the week", content: createContent),
            confirmed: true
        )

        guard case .object(let createPayload) = createExecution.result.json,
              let skillID = createPayload["id"]?.stringValue else {
            return XCTFail("Expected created skill id")
        }

        _ = try await ToolHost.shared.executeWithAudit(
            toolName: "skills.update",
            args: [
                "id": .string(skillID),
                "content": .string(updatedContent)
            ],
            confirmed: true
        )

        _ = try await ToolHost.shared.executeWithAudit(
            toolName: "skills.delete",
            args: ["id": .string(skillID)],
            confirmed: true
        )

        try await Task.sleep(for: .milliseconds(350))
        let entries = await MainActor.run {
            PersistenceManager.shared.flushSave()
            return PersistenceManager.shared.recentAuditEntries(limit: 10).map { $0.toAuditLogEntry() }
        }
        XCTAssertTrue(entries.contains(where: { $0.category == .skillCreate }))
        XCTAssertTrue(entries.contains(where: { $0.category == .skillUpdate }))
        XCTAssertTrue(entries.contains(where: { $0.category == .skillDelete }))

        let createEntry = try XCTUnwrap(entries.first(where: { $0.category == .skillCreate }))
        let updateEntry = try XCTUnwrap(entries.first(where: { $0.category == .skillUpdate }))
        let deleteEntry = try XCTUnwrap(entries.first(where: { $0.category == .skillDelete }))

        XCTAssertEqual((createEntry.parameters?["contentLength"] as? NSNumber)?.doubleValue, Double(createContent.count))
        XCTAssertTrue(createEntry.result?.contains("\"contentHash\"") == true)
        XCTAssertTrue(updateEntry.result?.contains("\"contentHash\"") == true)
        XCTAssertEqual(deleteEntry.parameters?["skillName"] as? String, "Weekly Planning")
    }

    // MARK: - Helpers

    private func createArguments(
        name: String,
        description: String = "Reviews the week",
        content: String? = nil
    ) -> [String: JSONValue] {
        let skillContent = content ?? self.validContent(name: name, description: description)
        return [
            "name": .string(name),
            "description": .string(description),
            "content": .string(skillContent)
        ]
    }

    private func validContent(name: String, description: String) -> String {
        """
        ---
        name: \(name)
        description: \(description)
        version: 1.0
        ---

        # \(name)

        Use when the user asks for \(name.lowercased()).
        """
    }

    private func writeSkill(
        root: URL,
        id: String,
        name: String,
        description: String
    ) throws {
        let skillRoot = root.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: skillRoot, withIntermediateDirectories: true)
        try self.validContent(name: name, description: description).write(
            to: skillRoot.appendingPathComponent("SKILL.md", isDirectory: false),
            atomically: true,
            encoding: .utf8
        )
    }
}
