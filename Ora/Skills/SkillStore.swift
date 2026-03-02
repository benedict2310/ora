//
//  SkillStore.swift
//  Ora
//
//  Skill discovery, indexing, and content loading.
//

import Foundation
import os

actor SkillStore {

    // MARK: - Roots

    struct Roots: Sendable {
        let bundled: URL
        let user: URL
        let agent: URL
    }

    // MARK: - Singleton

    static let shared = SkillStore()

    // MARK: - Constants

    static let maxSkillFileBytes: Int64 = 100 * 1024
    static let fuzzyMatchThreshold: Double = 0.80

    // MARK: - Properties

    private let logger = Logger.ora(category: "skills")
    private let roots: Roots
    private var index: [String: SkillMetadata] = [:]
    private let scriptSandbox = ScriptSandbox()

    // MARK: - Initialization

    init(roots: Roots = SkillStore.defaultRoots()) {
        self.roots = roots
    }

    static func makeTestInstance(roots: Roots) -> SkillStore {
        return SkillStore(roots: roots)
    }

    // MARK: - Public API

    func rebuildIndex() async {
        await self.ensureWritableRootsExist()

        var discovered: [String: SkillMetadata] = [:]
        await self.scanRoot(url: self.roots.bundled, source: .bundled, into: &discovered)
        await self.scanRoot(url: self.roots.user, source: .user, into: &discovered)
        await self.scanRoot(url: self.roots.agent, source: .agent, into: &discovered)

        self.index = discovered
        self.logger.info("Indexed \(self.index.count) skills")
    }

    func list() -> [SkillMetadata] {
        self.index.values.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    func load(id: String) throws -> SkillDocument {
        let metadata = try resolveSkill(for: id)
        let skillURL = metadata.rootURL.appendingPathComponent("SKILL.md", isDirectory: false)
        try validateFileSize(at: skillURL)

        let markdown = try String(contentsOf: skillURL, encoding: .utf8)
        let sanitized: String
        if metadata.source == .user {
            sanitized = ContentSanitizer.sanitize(markdown)
        } else {
            sanitized = markdown
        }

        return SkillDocument(meta: metadata, markdown: sanitized)
    }

    func readFile(id: String, relativePath: String) throws -> (data: Data, metadata: SkillMetadata) {
        let metadata = try resolveSkill(for: id)
        let fileURL = try SkillPathSandbox.resolve(root: metadata.rootURL, relativePath: relativePath)

        try validateFileSize(at: fileURL)
        return (try Data(contentsOf: fileURL), metadata)
    }

    func metadata(id: String) throws -> SkillMetadata {
        try resolveSkill(for: id)
    }

    func metadataExact(id: String) throws -> SkillMetadata {
        try self.resolveExactSkill(for: id)
    }

    func create(name: String, content: String) async throws -> SkillMetadata {
        let skillID = try await self.writeNewAgentSkill(name: name, content: content)
        return try self.resolveExactSkill(for: skillID)
    }

    func update(id: String, content: String) async throws -> SkillMetadata {
        let metadata = try self.resolveExactAgentSkill(for: id)
        let sanitized = try self.sanitizedSkillContent(content)
        try self.validateWritableContentSize(sanitized)
        let skillURL = metadata.rootURL.appendingPathComponent("SKILL.md", isDirectory: false)

        try sanitized.write(to: skillURL, atomically: true, encoding: .utf8)
        await self.rebuildIndex()
        return try self.resolveExactSkill(for: id)
    }

    func delete(id: String) async throws -> SkillMetadata {
        let metadata = try self.resolveExactAgentSkill(for: id)
        try FileManager.default.removeItem(at: metadata.rootURL)
        await self.rebuildIndex()
        return metadata
    }

    func scriptManifest(id: String) throws -> ScriptManifest {
        let metadata = try resolveSkill(for: id)
        return try ScriptManifest.load(from: metadata.rootURL)
    }

    func scriptFiles(id: String) throws -> [URL] {
        let metadata = try resolveSkill(for: id)
        return try self.scriptSandbox.listScripts(skillRoot: metadata.rootURL)
    }

    func resolveMatch(for query: String, threshold: Double = SkillStore.fuzzyMatchThreshold) -> SkillMetadata? {
        let skills = list()
        guard !skills.isEmpty else {
            return nil
        }

        let normalizedQuery = normalizeLookupQuery(query)
        guard !normalizedQuery.isEmpty else {
            return nil
        }

        if let exact = skills.first(where: { meta in
            let id = meta.id.lowercased()
            let name = meta.name.lowercased()
            return id == normalizedQuery || name == normalizedQuery
        }) {
            return exact
        }

        if let substring = skills.first(where: { meta in
            let id = meta.id.lowercased()
            let name = meta.name.lowercased()
            return id.contains(normalizedQuery) ||
                name.contains(normalizedQuery) ||
                normalizedQuery.contains(id) ||
                normalizedQuery.contains(name)
        }) {
            return substring
        }

        let ranked = skills
            .map { metadata in
                let score = max(
                    StringSimilarity.jaroWinkler(normalizedQuery, metadata.id.lowercased()),
                    StringSimilarity.jaroWinkler(normalizedQuery, metadata.name.lowercased())
                )
                return (metadata: metadata, score: score)
            }
            .sorted { lhs, rhs in
                if lhs.score == rhs.score {
                    return lhs.metadata.name.localizedCaseInsensitiveCompare(rhs.metadata.name) == .orderedAscending
                }
                return lhs.score > rhs.score
            }

        guard let best = ranked.first, best.score >= threshold else {
            return nil
        }

        return best.metadata
    }

    func userSkillsFolderURL() -> URL {
        return self.roots.user
    }

    // MARK: - Private

    private static func defaultRoots() -> Roots {
        let bundled = Bundle.main.resourceURL?
            .appendingPathComponent("Skills", isDirectory: true)
            .standardizedFileURL
            ?? URL(fileURLWithPath: "/nonexistent", isDirectory: true)

        let user = ModelPaths.skillsRoot.standardizedFileURL
        let agent = ModelPaths.agentSkillsRoot
            .standardizedFileURL

        return Roots(bundled: bundled, user: user, agent: agent)
    }

    private func scanRoot(url: URL, source: SkillMetadata.Source, into discovered: inout [String: SkillMetadata]) async {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            if source == .bundled {
                self.logger.warning("Bundled skills root missing: \(url.path)")
            }
            return
        }

        guard let children = try? fileManager.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            self.logger.error("Failed to enumerate skills root: \(url.path)")
            return
        }

        for child in children {
            guard (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                continue
            }

            let skillID = child.lastPathComponent
            let skillFile = child.appendingPathComponent("SKILL.md", isDirectory: false)

            guard fileManager.fileExists(atPath: skillFile.path) else {
                self.logger.warning("Skipping skill '\(skillID)' (missing SKILL.md)")
                continue
            }

            do {
                let frontmatter = try loadFrontmatterOnly(from: skillFile)
                discovered[skillID] = SkillMetadata(
                    id: skillID,
                    name: frontmatter.name,
                    description: frontmatter.description,
                    source: source,
                    rootURL: child,
                    version: frontmatter.version,
                    hasScripts: self.skillHasScripts(at: child)
                )
            } catch {
                self.logger.warning("Skipping skill '\(skillID)' (\(error.localizedDescription))")
            }
        }
    }

    private func loadFrontmatterOnly(from url: URL) throws -> SkillFrontmatterParser.Frontmatter {
        let fileHandle = try FileHandle(forReadingFrom: url)
        defer {
            try? fileHandle.close()
        }

        let chunk = try fileHandle.read(upToCount: 16_384) ?? Data()
        guard let preview = String(data: chunk, encoding: .utf8) else {
            throw SkillError.invalidFrontmatter("SKILL.md is not valid UTF-8")
        }

        return try SkillFrontmatterParser.parse(from: preview)
    }

    private func ensureWritableRootsExist() async {
        let fileManager = FileManager.default
        let writableRoots = [
            ("user", self.roots.user),
            ("agent", self.roots.agent)
        ]

        for (label, root) in writableRoots {
            do {
                try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
            } catch {
                self.logger.error("Failed to create \(label) skills root: \(error.localizedDescription)")
            }
        }
    }

    private func writeNewAgentSkill(name: String, content: String) async throws -> String {
        let skillID = try self.generatedID(for: name)
        let skillRoot = self.roots.agent.appendingPathComponent(skillID, isDirectory: true)
        let skillFile = skillRoot.appendingPathComponent("SKILL.md", isDirectory: false)
        let sanitized = try self.sanitizedSkillContent(content)
        try self.validateWritableContentSize(sanitized)

        try FileManager.default.createDirectory(at: skillRoot, withIntermediateDirectories: true)
        do {
            try sanitized.write(to: skillFile, atomically: true, encoding: .utf8)
        } catch {
            try? FileManager.default.removeItem(at: skillRoot)
            throw error
        }
        await self.rebuildIndex()
        return skillID
    }

    private func generatedID(for name: String) throws -> String {
        let blockedIDs = self.index.values.reduce(into: [String: SkillMetadata.Source]()) { partialResult, metadata in
            guard metadata.source == .bundled || metadata.source == .user else {
                return
            }
            partialResult[metadata.id] = metadata.source
        }
        let agentIDs = Set(
            self.index.values
                .filter { $0.source == .agent }
                .map(\.id)
        )

        return try SkillSlugGenerator.resolveUniqueSlug(
            from: name,
            existingAgentIDs: agentIDs,
            blockedIDs: blockedIDs
        )
    }

    private func sanitizedSkillContent(_ content: String) throws -> String {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        let sanitized = ContentSanitizer.sanitize(trimmed)
        _ = try SkillFrontmatterParser.parse(from: sanitized)
        return sanitized
    }

    private func resolveSkill(for idOrName: String) throws -> SkillMetadata {
        if let metadata = self.index[idOrName] {
            return metadata
        }

        if let matched = resolveMatch(for: idOrName) {
            return matched
        }

        throw SkillError.notFound
    }

    private func resolveExactSkill(for id: String) throws -> SkillMetadata {
        guard let metadata = self.index[id] else {
            throw SkillError.notFound
        }
        return metadata
    }

    private func resolveExactAgentSkill(for id: String) throws -> SkillMetadata {
        let metadata = try self.resolveExactSkill(for: id)
        guard metadata.source == .agent else {
            throw SkillError.immutableSource(id, metadata.source)
        }
        return metadata
    }

    private func validateFileSize(at url: URL) throws {
        guard let fileSize = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else {
            return
        }

        if Int64(fileSize) > Self.maxSkillFileBytes {
            throw SkillError.fileTooLarge
        }
    }

    private func validateWritableContentSize(_ content: String) throws {
        if Int64(content.utf8.count) > Self.maxSkillFileBytes {
            throw SkillError.contentTooLarge
        }
    }

    private func normalizeLookupQuery(_ query: String) -> String {
        let lowered = query.lowercased()
        let cleaned = lowered
            .replacingOccurrences(of: "[^a-z0-9\\s-]", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !cleaned.isEmpty else {
            return ""
        }

        let ignored = Set(["use", "the", "skill", "skills", "please", "activate"])
        let tokens = cleaned
            .split(separator: " ")
            .map(String.init)
            .filter { !ignored.contains($0) }

        return tokens.joined(separator: " ")
    }

    private func skillHasScripts(at skillRoot: URL) -> Bool {
        let scriptsRoot = skillRoot.appendingPathComponent("scripts", isDirectory: true)
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: scriptsRoot,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return false
        }

        return contents.contains { url in
            guard url.lastPathComponent != "manifest.json" else {
                return false
            }
            return (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }
    }
}
