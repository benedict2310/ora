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
        await ensureUserRootExists()

        var discovered: [String: SkillMetadata] = [:]
        await scanRoot(url: roots.bundled, source: .bundled, into: &discovered)
        await scanRoot(url: roots.user, source: .user, into: &discovered)

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

        let user = ModelPaths.oraRoot
            .appendingPathComponent("Skills", isDirectory: true)
            .standardizedFileURL

        return Roots(bundled: bundled, user: user)
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

    private func ensureUserRootExists() async {
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(at: self.roots.user, withIntermediateDirectories: true)
        } catch {
            self.logger.error("Failed to create user skills root: \(error.localizedDescription)")
        }
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

    private func validateFileSize(at url: URL) throws {
        guard let fileSize = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else {
            return
        }

        if Int64(fileSize) > Self.maxSkillFileBytes {
            throw SkillError.fileTooLarge
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
