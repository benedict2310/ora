//
//  SkillsRunScriptTool.swift
//  Ora
//
//  Executes skill-owned scripts after shared ToolHost authorization preflight.
//

import Foundation

struct SkillsRunScriptTool: Tool {
    let name = "skills.run_script"
    let kind: ToolKind = .read

    private let skillStore: SkillStore
    private let worker: SkillScriptWorker
    private let sandbox: ScriptSandbox
    private let trustManager: ScriptTrustManager
    private let authorizationPolicy: ScriptAuthorizationPolicy

    init(
        skillStore: SkillStore = .shared,
        worker: SkillScriptWorker = .shared,
        sandbox: ScriptSandbox = ScriptSandbox(),
        trustManager: ScriptTrustManager = .shared
    ) {
        self.skillStore = skillStore
        self.worker = worker
        self.sandbox = sandbox
        self.trustManager = trustManager
        self.authorizationPolicy = ScriptAuthorizationPolicy(trustManager: trustManager)
    }

    var schema: ToolSchema {
        ToolSchema(
            name: self.name,
            description: "Run a script from a skill's scripts folder. Call skills.load first to learn the expected arguments.",
            parameters: [
                "skill_id": ParameterSchema(type: "string", description: "Skill id or spoken skill name"),
                "script": ParameterSchema(type: "string", description: "Script filename relative to scripts/"),
                "args": ParameterSchema(type: "array", description: "Positional string arguments for the script")
            ],
            requiredParameters: ["skill_id", "script"],
            requiresConfirmation: false
        )
    }

    func validate(args: [String: JSONValue]) throws {
        guard let skillID = args["skill_id"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !skillID.isEmpty else {
            throw ToolHostError.validationFailed(self.name, "Missing required parameter: skill_id")
        }

        guard let script = args["script"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !script.isEmpty else {
            throw ToolHostError.validationFailed(self.name, "Missing required parameter: script")
        }

        if let values = args["args"] {
            guard case .array(let items) = values else {
                throw ToolHostError.validationFailed(self.name, "args must be an array of strings")
            }
            guard items.allSatisfy({ $0.stringValue != nil }) else {
                throw ToolHostError.validationFailed(self.name, "args must contain only strings")
            }
        }
    }

    func authorizationPlan(args: [String: JSONValue]) async throws -> ToolAuthorizationPlan {
        let requestedSkillID = args["skill_id"]?.stringValue ?? ""
        let scriptName = args["script"]?.stringValue ?? ""
        let scriptArgs = Self.argumentValues(from: args)

        let metadata = try await self.skillStore.metadata(id: requestedSkillID)
        let manifest = try await self.skillStore.scriptManifest(id: metadata.id)
        let scriptURL = try self.sandbox.resolve(skillRoot: metadata.rootURL, scriptPath: scriptName)
        let scriptHash = try self.sandbox.scriptHash(at: scriptURL)
        let config = manifest.config(for: scriptURL.lastPathComponent)
        let evaluation = try await self.authorizationPolicy.evaluate(
            metadata: metadata,
            scriptName: scriptURL.lastPathComponent,
            scriptHash: scriptHash,
            args: scriptArgs,
            manifest: manifest,
            config: config
        )

        return ToolAuthorizationPlan(
            requirement: evaluation.requirement,
            auditMetadata: evaluation.auditMetadata,
            context: evaluation.context
        )
    }

    func handleAuthorizationDecision(
        args: [String: JSONValue],
        context: [String: JSONValue],
        decision: ToolAuthorizationDecision
    ) async throws {
        let metadata = try await self.skillStore.metadata(id: args["skill_id"]?.stringValue ?? "")
        let scriptHash = context["script_hash"]?.stringValue ?? ""
        let requiresNetworkWarning = context["requires_network_warning"]?.boolValue ?? false

        switch decision {
        case .approveAndTrust:
            var acknowledged: Set<String> = []
            if requiresNetworkWarning, !scriptHash.isEmpty {
                acknowledged.insert(scriptHash)
            }
            try await self.trustManager.grantTrust(
                skillID: metadata.id,
                skillRoot: metadata.rootURL,
                acknowledgedNetworkHashes: acknowledged
            )

        case .approveOnce:
            if metadata.source == .user, requiresNetworkWarning, !scriptHash.isEmpty {
                await self.trustManager.acknowledgeNetworkWarning(
                    skillID: metadata.id,
                    scriptHash: scriptHash
                )
            }

        case .deny:
            break
        }
    }

    func execute(args: [String: JSONValue]) async throws -> ToolResult {
        try await SkillsFeatureGate.requireEnabled()

        let requestedSkillID = args["skill_id"]?.stringValue ?? ""
        let requestedScript = args["script"]?.stringValue ?? ""
        let scriptArgs = Self.argumentValues(from: args)

        let metadata = try await self.skillStore.metadata(id: requestedSkillID)
        let manifest = try await self.skillStore.scriptManifest(id: metadata.id)
        let scriptURL = try self.sandbox.resolve(skillRoot: metadata.rootURL, scriptPath: requestedScript)
        let config = manifest.config(for: scriptURL.lastPathComponent)
        let scriptHash = try self.sandbox.scriptHash(at: scriptURL)

        // TOCTOU mitigation (P1-2): re-validate trust status at execution time.
        // If a trusted skill's script was modified after preflight granted auto-approval,
        // ScriptTrustManager.status() will have revoked the trust record and returned
        // .untrusted with non-empty storedHashes — the signature of a mid-flight hash change.
        if metadata.source == .user {
            let trustStatus = try await self.trustManager.status(for: metadata)
            if trustStatus.level == .untrusted, !trustStatus.storedHashes.isEmpty {
                throw ScriptToolFailure(
                    message: "'\(scriptURL.lastPathComponent)' was modified since it was authorized. Please run the command again.",
                    payload: [
                        "skill_id": .string(metadata.id),
                        "script": .string(scriptURL.lastPathComponent),
                        "script_hash": .string(scriptHash)
                    ]
                )
            }
        }

        do {
            let result = try await self.worker.run(
                skillID: metadata.id,
                skillRoot: metadata.rootURL,
                scriptPath: requestedScript,
                arguments: scriptArgs,
                timeout: config.timeout
            )

            let auditPayload = self.auditPayload(
                skillID: metadata.id,
                scriptName: scriptURL.lastPathComponent,
                scriptHash: scriptHash,
                result: result
            )

            guard result.exitCode == 0 else {
                let message = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? "Script exited with code \(result.exitCode)."
                    : result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                throw ScriptToolFailure(message: message, payload: auditPayload)
            }

            var payload: [String: JSONValue] = [
                "skill_id": .string(metadata.id),
                "script": .string(scriptURL.lastPathComponent),
                "exit_code": .number(Double(result.exitCode)),
                "stdout": .string(result.stdout),
                "stderr": .string(result.stderr),
                "execution_time_ms": .number(Double(result.executionTimeMs)),
                "truncated": .bool(result.truncated)
            ]

            if config.output == .json, !result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                do {
                    let data = Data(result.stdout.utf8)
                    let raw = try JSONSerialization.jsonObject(with: data, options: .allowFragments)
                    payload["output"] = Self.jsonValueFrom(raw)
                } catch {
                    throw ScriptToolFailure(
                        message: "Script declared JSON output but returned invalid JSON.",
                        payload: auditPayload
                    )
                }
            }

            return .success(
                .object(payload),
                summary: "Ran script '\(scriptURL.lastPathComponent)' from skill '\(metadata.name)'.",
                auditPayload: auditPayload
            )
        } catch let error as ScriptToolFailure {
            throw error
        } catch let error as SkillScriptWorker.ScriptError {
            throw ScriptToolFailure(
                message: error.localizedDescription,
                payload: [
                    "skill_id": .string(metadata.id),
                    "script": .string(scriptURL.lastPathComponent),
                    "script_hash": .string(scriptHash)
                ]
            )
        } catch {
            throw ScriptToolFailure(
                message: error.localizedDescription,
                payload: [
                    "skill_id": .string(metadata.id),
                    "script": .string(scriptURL.lastPathComponent),
                    "script_hash": .string(scriptHash)
                ]
            )
        }
    }

    /// Converts a JSONSerialization-produced value to JSONValue.
    /// JSONSerialization produces NSNumber for booleans and numbers; CFBooleanGetTypeID()
    /// distinguishes booleans from numeric types (Bool is bridged as __NSCFBoolean).
    private static func jsonValueFrom(_ any: Any) -> JSONValue {
        switch any {
        case let string as String:
            return .string(string)
        case let number as NSNumber:
            if CFBooleanGetTypeID() == CFGetTypeID(number) {
                return .bool(number.boolValue)
            }
            return .number(number.doubleValue)
        case let array as [Any]:
            return .array(array.map { jsonValueFrom($0) })
        case let dict as [String: Any]:
            return .object(dict.mapValues { jsonValueFrom($0) })
        case is NSNull:
            return .null
        default:
            return .string(String(describing: any))
        }
    }

    private static func argumentValues(from args: [String: JSONValue]) -> [String] {
        guard case .array(let values)? = args["args"] else {
            return []
        }
        return values.compactMap(\.stringValue)
    }

    private func auditPayload(
        skillID: String,
        scriptName: String,
        scriptHash: String,
        result: SkillScriptWorker.ScriptResult
    ) -> [String: JSONValue] {
        [
            "skill_id": .string(skillID),
            "script": .string(scriptName),
            "script_hash": .string(scriptHash),
            "exit_code": .number(Double(result.exitCode)),
            "stdout": .string(result.stdout),
            "stderr": .string(result.stderr),
            "execution_time_ms": .number(Double(result.executionTimeMs)),
            "truncated": .bool(result.truncated)
        ]
    }
}

private struct ScriptToolFailure: ToolAuditableFailure {
    let message: String
    let payload: [String: JSONValue]

    var errorDescription: String? {
        self.message
    }

    var auditPayload: [String: JSONValue]? {
        self.payload
    }

    var auditCategoryOverride: AuditCategory? {
        .scriptExecution
    }
}
