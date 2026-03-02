//
//  SkillStoreTests.swift
//  OraTests
//

import XCTest
@testable import Ora

final class SkillStoreTests: XCTestCase {

    private var rootDirectory: URL!
    private var bundledRoot: URL!
    private var userRoot: URL!
    private var agentRoot: URL!

    override func setUpWithError() throws {
        rootDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SkillStoreTests-\(UUID().uuidString)", isDirectory: true)
        bundledRoot = rootDirectory.appendingPathComponent("bundled", isDirectory: true)
        userRoot = rootDirectory.appendingPathComponent("user", isDirectory: true)
        agentRoot = rootDirectory.appendingPathComponent("agent", isDirectory: true)

        try FileManager.default.createDirectory(at: bundledRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: userRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: agentRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let rootDirectory {
            try? FileManager.default.removeItem(at: rootDirectory)
        }
    }

    func test_rebuildIndex_discoversBundledUserAndAgentSkills() async throws {
        XCTAssertEqual(SkillStore.fuzzyMatchThreshold, 0.80, accuracy: 0.0001)

        try self.writeSkill(root: bundledRoot, id: "daily-briefing", name: "Daily Briefing", description: "Morning summary")
        try self.writeSkill(root: userRoot, id: "meeting-scheduler", name: "Meeting Scheduler", description: "Schedule meetings")
        try self.writeSkill(root: agentRoot, id: "weekly-planning", name: "Weekly Planning", description: "Review the week")

        let store = SkillStore.makeTestInstance(
            roots: .init(bundled: bundledRoot, user: userRoot, agent: agentRoot)
        )

        await store.rebuildIndex()
        let skills = await store.list()

        XCTAssertEqual(skills.count, 3)
        XCTAssertTrue(skills.contains(where: { $0.id == "daily-briefing" && $0.source == .bundled }))
        XCTAssertTrue(skills.contains(where: { $0.id == "meeting-scheduler" && $0.source == .user }))
        XCTAssertTrue(skills.contains(where: { $0.id == "weekly-planning" && $0.source == .agent }))
    }

    func test_rebuildIndex_ignoresInvalidSkills() async throws {
        let missingFileFolder = bundledRoot.appendingPathComponent("missing-file", isDirectory: true)
        try FileManager.default.createDirectory(at: missingFileFolder, withIntermediateDirectories: true)

        try self.writeSkill(
            root: userRoot,
            id: "invalid-frontmatter",
            content: "---\nname: Missing Description\n---"
        )

        let store = SkillStore.makeTestInstance(
            roots: .init(bundled: bundledRoot, user: userRoot, agent: agentRoot)
        )

        await store.rebuildIndex()
        let skills = await store.list()

        XCTAssertTrue(skills.isEmpty)
    }

    func test_load_userSkill_sanitizesContent() async throws {
        let skillContent = """
        ---
        name: User Skill
        description: User provided
        ---

        Line one\u{0007}\u{0008}

        \t\tLine two
        """

        try self.writeSkill(root: userRoot, id: "user-skill", content: skillContent)

        let store = SkillStore.makeTestInstance(
            roots: .init(bundled: bundledRoot, user: userRoot, agent: agentRoot)
        )

        await store.rebuildIndex()
        let loaded = try await store.load(id: "user-skill")

        XCTAssertFalse(loaded.markdown.contains("\u{0007}"))
        XCTAssertFalse(loaded.markdown.contains("\u{0008}"))
    }

    func test_load_fuzzyMatch_resolvesSkillName() async throws {
        try self.writeSkill(root: bundledRoot, id: "daily-briefing", name: "Daily Briefing", description: "Morning summary")

        let store = SkillStore.makeTestInstance(
            roots: .init(bundled: bundledRoot, user: userRoot, agent: agentRoot)
        )

        await store.rebuildIndex()

        let exact = await store.resolveMatch(for: "daily-briefing")
        XCTAssertEqual(exact?.id, "daily-briefing")

        let fuzzy = await store.resolveMatch(for: "daly breifing")
        XCTAssertEqual(fuzzy?.id, "daily-briefing")

        let noMatch = await store.resolveMatch(for: "completely unrelated request")
        XCTAssertNil(noMatch)
    }

    func test_readFile_readsReferencesPath() async throws {
        try self.writeSkill(root: bundledRoot, id: "daily-briefing", name: "Daily Briefing", description: "Morning summary")

        let skillRoot = bundledRoot.appendingPathComponent("daily-briefing", isDirectory: true)
        let referencesRoot = skillRoot.appendingPathComponent("references", isDirectory: true)
        try FileManager.default.createDirectory(at: referencesRoot, withIntermediateDirectories: true)

        let expected = "reference-body"
        try expected.write(to: referencesRoot.appendingPathComponent("guide.txt"), atomically: true, encoding: .utf8)

        let store = SkillStore.makeTestInstance(
            roots: .init(bundled: bundledRoot, user: userRoot, agent: agentRoot)
        )

        await store.rebuildIndex()
        let (data, metadata) = try await store.readFile(id: "daily-briefing", relativePath: "references/guide.txt")

        XCTAssertEqual(String(data: data, encoding: .utf8), expected)
        XCTAssertEqual(metadata.id, "daily-briefing")
    }

    func test_create_rejectsOversizedContentAtWriteTime() async throws {
        let store = SkillStore.makeTestInstance(
            roots: .init(bundled: bundledRoot, user: userRoot, agent: agentRoot)
        )

        await store.rebuildIndex()

        do {
            _ = try await store.create(
                name: "Large Skill",
                content: self.oversizedContent(name: "Large Skill", description: "Too large")
            )
            XCTFail("Expected oversized content error")
        } catch let error as SkillError {
            XCTAssertEqual(error, .contentTooLarge)
        }

        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: agentRoot.appendingPathComponent("large-skill", isDirectory: true).path
            )
        )
    }

    func test_update_rejectsOversizedContentAtWriteTime() async throws {
        try self.writeSkill(root: agentRoot, id: "weekly-planning", name: "Weekly Planning", description: "Original")

        let store = SkillStore.makeTestInstance(
            roots: .init(bundled: bundledRoot, user: userRoot, agent: agentRoot)
        )

        await store.rebuildIndex()

        let skillFile = agentRoot
            .appendingPathComponent("weekly-planning", isDirectory: true)
            .appendingPathComponent("SKILL.md", isDirectory: false)
        let original = try String(contentsOf: skillFile, encoding: .utf8)

        do {
            _ = try await store.update(
                id: "weekly-planning",
                content: self.oversizedContent(name: "Weekly Planning", description: "Too large")
            )
            XCTFail("Expected oversized content error")
        } catch let error as SkillError {
            XCTAssertEqual(error, .contentTooLarge)
        }

        let written = try String(contentsOf: skillFile, encoding: .utf8)
        XCTAssertEqual(written, original)
    }

    // MARK: - Helpers

    private func writeSkill(
        root: URL,
        id: String,
        name: String = "Test Skill",
        description: String = "Skill description",
        content: String? = nil
    ) throws {
        let skillRoot = root.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: skillRoot, withIntermediateDirectories: true)

        let defaultContent = """
        ---
        name: \(name)
        description: \(description)
        ---

        # \(name)
        """

        let skillFile = skillRoot.appendingPathComponent("SKILL.md", isDirectory: false)
        try (content ?? defaultContent).write(to: skillFile, atomically: true, encoding: .utf8)
    }

    private func oversizedContent(name: String, description: String) -> String {
        let header = """
        ---
        name: \(name)
        description: \(description)
        version: 1.0
        ---

        # \(name)

        """

        let requiredBytes = Int(SkillStore.maxSkillFileBytes) - header.utf8.count + 1
        let filler = String(repeating: "A", count: max(requiredBytes, 1))
        return header + filler
    }
}
