//
//  SkillsToolsTests.swift
//  OraTests
//

import XCTest
@testable import Ora

final class SkillsToolsTests: XCTestCase {

    private var rootDirectory: URL!
    private var bundledRoot: URL!
    private var userRoot: URL!
    private var store: SkillStore!

    override func setUp() async throws {
        rootDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SkillsToolsTests-\(UUID().uuidString)", isDirectory: true)
        bundledRoot = rootDirectory.appendingPathComponent("bundled", isDirectory: true)
        userRoot = rootDirectory.appendingPathComponent("user", isDirectory: true)

        try FileManager.default.createDirectory(at: bundledRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: userRoot, withIntermediateDirectories: true)

        try self.writeSkill(root: bundledRoot, id: "daily-briefing", name: "Daily Briefing", description: "Morning summary")

        let skillRoot = bundledRoot.appendingPathComponent("daily-briefing", isDirectory: true)
        let referencesRoot = skillRoot.appendingPathComponent("references", isDirectory: true)
        try FileManager.default.createDirectory(at: referencesRoot, withIntermediateDirectories: true)
        try "Reference text".write(to: referencesRoot.appendingPathComponent("guide.txt"), atomically: true, encoding: .utf8)

        store = SkillStore.makeTestInstance(roots: .init(bundled: bundledRoot, user: userRoot))
        await store.rebuildIndex()

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
        if let rootDirectory {
            try? FileManager.default.removeItem(at: rootDirectory)
        }
    }

    func test_skillsList_returnsMetadataArray() async throws {
        let tool = SkillsListTool(skillStore: store)

        let result = try await tool.execute(args: [:])
        guard case .array(let items) = result.json else {
            return XCTFail("Expected array payload")
        }

        XCTAssertEqual(items.count, 1)
        guard case .object(let object) = items[0] else {
            return XCTFail("Expected object item")
        }

        XCTAssertEqual(object["id"]?.stringValue, "daily-briefing")
        XCTAssertEqual(object["name"]?.stringValue, "Daily Briefing")
        XCTAssertEqual(object["source"]?.stringValue, "bundled")
    }

    func test_skillsLoad_truncatesContentOverFiveThousandCharacters() async throws {
        let veryLong = String(repeating: "a", count: 5_200)
        try self.writeSkill(
            root: bundledRoot,
            id: "long-skill",
            name: "Long Skill",
            description: "Long skill",
            body: veryLong
        )
        await store.rebuildIndex()

        let tool = SkillsLoadTool(skillStore: store)
        let result = try await tool.execute(args: ["id": .string("long-skill")])

        guard case .object(let object) = result.json,
              let content = object["content"]?.stringValue else {
            return XCTFail("Expected object payload with content")
        }

        XCTAssertTrue(content.contains("[truncated]"))
        XCTAssertEqual(object["truncated"]?.boolValue, true)
        XCTAssertTrue(content.count > 5_000)
    }

    func test_skillsRead_rejectsPathTraversal() async {
        let tool = SkillsReadTool(skillStore: store)

        do {
            _ = try await tool.execute(args: [
                "id": .string("daily-briefing"),
                "path": .string("references/../secret.txt")
            ])
            XCTFail("Expected invalid path error")
        } catch let error as SkillError {
            XCTAssertEqual(error, .invalidPath("references/../secret.txt"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func test_skillsLoad_fuzzyMatching_resolvesASRMangledName() async throws {
        let tool = SkillsLoadTool(skillStore: store)

        let result = try await tool.execute(args: ["id": .string("daly breifing")])
        guard case .object(let object) = result.json else {
            return XCTFail("Expected object payload")
        }

        XCTAssertEqual(object["id"]?.stringValue, "daily-briefing")
        XCTAssertEqual(object["name"]?.stringValue, "Daily Briefing")
    }

    func test_toolHost_recordsSkillAuditCategories() async throws {
        await ToolRegistry.shared.register(SkillsListTool(skillStore: store))
        await ToolRegistry.shared.register(SkillsLoadTool(skillStore: store))
        await ToolRegistry.shared.register(SkillsReadTool(skillStore: store))

        _ = try await ToolHost.shared.executeWithAudit(
            toolName: "skills.list",
            args: [:],
            confirmed: false
        )

        _ = try await ToolHost.shared.executeWithAudit(
            toolName: "skills.load",
            args: ["id": .string("daily-briefing")],
            confirmed: false
        )

        _ = try await ToolHost.shared.executeWithAudit(
            toolName: "skills.read",
            args: [
                "id": .string("daily-briefing"),
                "path": .string("references/guide.txt")
            ],
            confirmed: false
        )

        let entries = await AuditLogger.shared.fetchEntries(limit: 10)

        XCTAssertTrue(entries.contains(where: { $0.category == .skillList }))
        XCTAssertTrue(entries.contains(where: { $0.category == .skillLoad }))
        XCTAssertTrue(entries.contains(where: { $0.category == .skillRead }))

        let loadEntry = entries.first(where: { $0.category == .skillLoad })
        XCTAssertEqual(loadEntry?.parameters?["id"] as? String, "daily-briefing")

        let readEntry = entries.first(where: { $0.category == .skillRead })
        XCTAssertEqual(readEntry?.parameters?["path"] as? String, "references/guide.txt")
    }

    // MARK: - Helpers

    private func writeSkill(
        root: URL,
        id: String,
        name: String,
        description: String,
        body: String = "Skill body"
    ) throws {
        let skillRoot = root.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: skillRoot, withIntermediateDirectories: true)

        let content = """
        ---
        name: \(name)
        description: \(description)
        ---

        \(body)
        """

        try content.write(
            to: skillRoot.appendingPathComponent("SKILL.md", isDirectory: false),
            atomically: true,
            encoding: .utf8
        )
    }
}
