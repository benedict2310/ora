//
//  SkillPathSandbox.swift
//  Ora
//
//  Path sandbox for skills.read.
//

import Foundation

enum SkillPathSandbox {

    private static let allowedPrefixes = ["references/", "assets/"]

    static func resolve(root: URL, relativePath: String) throws -> URL {
        let trimmed = relativePath.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmed.isEmpty else {
            throw SkillError.invalidPath(relativePath)
        }

        guard !trimmed.hasPrefix("/") else {
            throw SkillError.invalidPath(relativePath)
        }

        let normalizedPath = trimmed.replacingOccurrences(of: "\\", with: "/")
        guard allowedPrefixes.contains(where: { normalizedPath.hasPrefix($0) }) else {
            throw SkillError.invalidPath(relativePath)
        }

        let segments = normalizedPath.split(separator: "/")
        guard !segments.contains("..") else {
            throw SkillError.invalidPath(relativePath)
        }

        let candidate = root.appendingPathComponent(normalizedPath, isDirectory: false)
        let canonicalCandidate = candidate.resolvingSymlinksInPath().standardizedFileURL
        let canonicalRoot = root.resolvingSymlinksInPath().standardizedFileURL

        let candidatePath = canonicalCandidate.path
        let rootPath = canonicalRoot.path

        guard candidatePath == rootPath || candidatePath.hasPrefix(rootPath + "/") else {
            throw SkillError.invalidPath(relativePath)
        }

        return canonicalCandidate
    }
}
