//
//  ScriptSandbox.swift
//  Ora
//
//  Validates script paths and resolves interpreters for skill scripts.
//

import CryptoKit
import Foundation

struct ScriptSandbox: Sendable {
    static let maxScriptFileBytes: Int64 = 100 * 1024
    private static let maxShebangCharacters = 256

    func resolve(skillRoot: URL, scriptPath: String) throws -> URL {
        // resolvingSymlinksInPath() is required instead of standardizedFileURL because
        // standardizedFileURL does NOT follow symlinks. Without resolving symlinks a
        // scripts/evil.sh → /tmp/exploit.sh symlink would pass the prefix check below
        // and execute the target outside the skill root (P1-1 fix).
        let resolvedSkillRoot = skillRoot.resolvingSymlinksInPath()
        let scriptsRoot = resolvedSkillRoot
            .appendingPathComponent("scripts", isDirectory: true)
            .resolvingSymlinksInPath()

        // Guard that scripts/ itself was not symlinked outside the skill bundle.
        // e.g. skillRoot/scripts → /tmp/attacker_scripts escapes the sandbox boundary.
        guard scriptsRoot.path.hasPrefix(resolvedSkillRoot.path + "/") || scriptsRoot == resolvedSkillRoot else {
            throw ScriptSandboxError.pathTraversal("scripts")
        }

        let candidate = scriptsRoot
            .appendingPathComponent(scriptPath, isDirectory: false)
            .resolvingSymlinksInPath()

        guard candidate.path.hasPrefix(scriptsRoot.path + "/") || candidate == scriptsRoot else {
            throw ScriptSandboxError.pathTraversal(scriptPath)
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            throw ScriptSandboxError.scriptNotFound(scriptPath)
        }

        if candidate.lastPathComponent == "manifest.json" {
            throw ScriptSandboxError.scriptNotFound(scriptPath)
        }

        try self.validateSize(of: candidate)
        return candidate
    }

    func parseInterpreter(at scriptURL: URL) throws -> String {
        let data = try Data(contentsOf: scriptURL)
        let firstLine = Self.firstLine(in: data)

        if let shebang = firstLine, shebang.hasPrefix("#!") {
            return try self.resolveInterpreter(from: shebang, scriptURL: scriptURL)
        }

        return try self.extensionFallbackInterpreter(for: scriptURL)
    }

    func scriptHash(at scriptURL: URL) throws -> String {
        let data = try Data(contentsOf: scriptURL)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func listScripts(skillRoot: URL) throws -> [URL] {
        let scriptsRoot = skillRoot
            .appendingPathComponent("scripts", isDirectory: true)
            .standardizedFileURL
        guard FileManager.default.fileExists(atPath: scriptsRoot.path) else {
            return []
        }

        let contents = try FileManager.default.contentsOfDirectory(
            at: scriptsRoot,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )

        return contents
            .filter { $0.lastPathComponent != "manifest.json" }
            .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
            .sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
    }

    private func validateSize(of url: URL) throws {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else {
            return
        }

        if Int64(size) > Self.maxScriptFileBytes {
            throw ScriptSandboxError.fileTooLarge
        }
    }

    private static func firstLine(in data: Data) -> String? {
        guard let content = String(data: data, encoding: .utf8) else {
            return nil
        }

        // Use components(separatedBy: .newlines) rather than split(separator: "\n")
        // because Swift treats the CRLF sequence "\r\n" as a single extended grapheme
        // cluster that does NOT match the LF Character "\n". Foundation's
        // components(separatedBy:) handles CR, LF, and CRLF as distinct separators
        // and strips them from the returned components.
        return content.components(separatedBy: .newlines).first
    }

    private func resolveInterpreter(from shebang: String, scriptURL: URL) throws -> String {
        guard shebang.count <= Self.maxShebangCharacters else {
            throw ScriptSandboxError.invalidShebang("Shebang exceeds \(Self.maxShebangCharacters) characters.")
        }

        let trimmed = shebang.dropFirst(2).trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            throw ScriptSandboxError.invalidShebang("Missing interpreter path.")
        }

        if trimmed.hasPrefix("/usr/bin/env ") {
            let parts = trimmed.split(separator: " ").map(String.init)
            guard parts.count == 2 else {
                throw ScriptSandboxError.invalidShebang("Unsupported env shebang format.")
            }
            let command = parts[1]
            guard command != "-S" else {
                throw ScriptSandboxError.invalidShebang("env -S is not supported.")
            }
            return try self.resolveCommand(command)
        }

        if trimmed.hasPrefix("/usr/bin/env") {
            throw ScriptSandboxError.invalidShebang("Unsupported env shebang format.")
        }

        guard trimmed.hasPrefix("/") else {
            throw ScriptSandboxError.invalidShebang("Interpreter must be an absolute path.")
        }

        // isExecutableFile is sufficient: it implies existence and checks execute permission.
        // The previous `|| fileExists` allowed non-executable files through, which caused
        // process.run() to fail at launch time and leaked the pipe reader tasks (P1-3 fix).
        guard FileManager.default.isExecutableFile(atPath: trimmed) else {
            throw ScriptSandboxError.interpreterNotFound(trimmed)
        }

        return trimmed
    }

    private func resolveCommand(_ command: String) throws -> String {
        let allowedPaths = ScriptEnvironment.allowedExecutablePaths()
        for path in allowedPaths {
            let candidate = URL(fileURLWithPath: path, isDirectory: true)
                .appendingPathComponent(command, isDirectory: false)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate.path
            }
        }

        throw ScriptSandboxError.interpreterNotFound(command)
    }

    private func extensionFallbackInterpreter(for scriptURL: URL) throws -> String {
        let ext = scriptURL.pathExtension.lowercased()
        let interpreter: String?

        switch ext {
        case "sh":
            interpreter = "/bin/bash"
        case "zsh":
            interpreter = "/bin/zsh"
        case "py":
            interpreter = try? self.resolveCommand("python3")
        case "scpt", "applescript":
            interpreter = "/usr/bin/osascript"
        case "rb":
            interpreter = try? self.resolveCommand("ruby")
        case "js", "mjs":
            interpreter = try? self.resolveCommand("node")
        default:
            interpreter = nil
        }

        guard let interpreter else {
            throw ScriptSandboxError.invalidShebang("Script must have a shebang or a supported extension.")
        }

        guard FileManager.default.fileExists(atPath: interpreter) else {
            throw ScriptSandboxError.interpreterNotFound(interpreter)
        }

        return interpreter
    }
}

enum ScriptSandboxError: LocalizedError, Equatable {
    case pathTraversal(String)
    case scriptNotFound(String)
    case invalidShebang(String)
    case interpreterNotFound(String)
    case fileTooLarge

    var errorDescription: String? {
        switch self {
        case .pathTraversal(let path):
            return "Invalid script path: \(path)"
        case .scriptNotFound(let path):
            return "Script not found: \(path)"
        case .invalidShebang(let message):
            return "Invalid shebang: \(message)"
        case .interpreterNotFound(let interpreter):
            return "Required interpreter not found: \(interpreter)"
        case .fileTooLarge:
            return "Script file is too large."
        }
    }
}
