//
//  ScriptManifest.swift
//  Ora
//
//  Parses optional scripts/manifest.json metadata for skill scripts.
//

import Foundation

struct ScriptManifest: Sendable {
    struct Argument: Sendable, Codable, Equatable {
        let name: String
        let type: String
        let required: Bool
        let description: String?
    }

    enum OutputType: String, Sendable, Codable {
        case text
        case json
    }

    struct ScriptConfig: Sendable, Equatable {
        let description: String?
        let arguments: [Argument]
        let output: OutputType
        let timeout: TimeInterval
        let capabilities: Set<String>
        let declaredInManifest: Bool
    }

    static let defaultTimeout: TimeInterval = 30

    let isPresent: Bool
    private let scripts: [String: ScriptConfig]

    init(isPresent: Bool, scripts: [String: ScriptConfig]) {
        self.isPresent = isPresent
        self.scripts = scripts
    }

    func config(for scriptName: String) -> ScriptConfig {
        self.scripts[scriptName] ?? ScriptConfig(
            description: nil,
            arguments: [],
            output: .text,
            timeout: Self.defaultTimeout,
            capabilities: [],
            declaredInManifest: false
        )
    }

    static func load(from skillRoot: URL) throws -> ScriptManifest {
        let manifestURL = skillRoot
            .appendingPathComponent("scripts", isDirectory: true)
            .appendingPathComponent("manifest.json", isDirectory: false)

        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            return ScriptManifest(isPresent: false, scripts: [:])
        }

        do {
            let data = try Data(contentsOf: manifestURL)
            let decoded = try JSONDecoder().decode(ManifestDocument.self, from: data)
            let mapped = decoded.scripts.mapValues { entry in
                ScriptConfig(
                    description: entry.description,
                    arguments: entry.arguments ?? [],
                    output: entry.output ?? .text,
                    timeout: entry.timeout ?? Self.defaultTimeout,
                    capabilities: Set((entry.capabilities ?? []).map { $0.lowercased() }),
                    declaredInManifest: true
                )
            }
            return ScriptManifest(isPresent: true, scripts: mapped)
        } catch {
            throw ScriptManifestError.invalidManifest(error.localizedDescription)
        }
    }
}

enum ScriptManifestError: LocalizedError, Equatable {
    case invalidManifest(String)

    var errorDescription: String? {
        switch self {
        case .invalidManifest(let message):
            return "Invalid script manifest: \(message)"
        }
    }
}

private struct ManifestDocument: Decodable {
    let scripts: [String: ManifestEntry]
}

private struct ManifestEntry: Decodable {
    let description: String?
    let arguments: [ScriptManifest.Argument]?
    let output: ScriptManifest.OutputType?
    let timeout: TimeInterval?
    let capabilities: [String]?
}
