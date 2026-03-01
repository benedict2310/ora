//
//  ScriptEnvironment.swift
//  Ora
//
//  Builds a filtered environment for skill script execution.
//

import Foundation

struct ScriptEnvironment: Sendable {
    let values: [String: String]

    static func build(
        requestID: UUID = UUID(),
        skillID: String,
        skillRoot: URL,
        scriptName: String
    ) -> ScriptEnvironment {
        let processEnvironment = ProcessInfo.processInfo.environment
        var values: [String: String] = [:]

        let allowedKeys = ["HOME", "USER", "LANG", "TZ"]
        for key in allowedKeys {
            if let value = processEnvironment[key], !value.isEmpty {
                values[key] = value
            }
        }

        values["PATH"] = Self.allowedExecutablePaths().joined(separator: ":")
        values["ORA_SKILL_ID"] = skillID
        values["ORA_SKILL_ROOT"] = skillRoot.path
        values["ORA_SCRIPT_NAME"] = scriptName
        values["ORA_REQUEST_ID"] = requestID.uuidString

        return ScriptEnvironment(values: values)
    }

    static func allowedExecutablePaths() -> [String] {
        let candidates = [
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin",
            "/usr/local/bin",
            "/opt/homebrew/bin"
        ]

        return candidates.filter { FileManager.default.fileExists(atPath: $0) }
    }
}
