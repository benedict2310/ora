//
//  SkillScriptWorker.swift
//  Ora
//
//  Executes skill scripts in a controlled child-process environment.
//

import Darwin
import Foundation

actor SkillScriptWorker {
    struct ScriptResult: Sendable, Equatable {
        let exitCode: Int32
        let stdout: String
        let stderr: String
        let executionTimeMs: Int
        let truncated: Bool
    }

    enum ScriptError: LocalizedError, Equatable {
        case timeout(TimeInterval)

        var errorDescription: String? {
            switch self {
            case .timeout(let seconds):
                return "Script timed out after \(Int(seconds)) seconds."
            }
        }
    }

    static let shared = SkillScriptWorker()

    private let sandbox: ScriptSandbox
    private let maxOutputBytes = 64 * 1024
    private let defaultTimeout: TimeInterval = ScriptManifest.defaultTimeout
    private let killGracePeriod: TimeInterval = 5

    init(sandbox: ScriptSandbox = ScriptSandbox()) {
        self.sandbox = sandbox
    }

    func run(
        skillID: String,
        skillRoot: URL,
        scriptPath: String,
        arguments: [String],
        timeout: TimeInterval? = nil,
        requestID: UUID = UUID()
    ) async throws -> ScriptResult {
        let resolvedScript = try self.sandbox.resolve(skillRoot: skillRoot, scriptPath: scriptPath)
        let interpreter = try self.sandbox.parseInterpreter(at: resolvedScript)
        let environment = ScriptEnvironment.build(
            requestID: requestID,
            skillID: skillID,
            skillRoot: skillRoot,
            scriptName: resolvedScript.lastPathComponent
        )

        return try await self.execute(
            interpreter: interpreter,
            script: resolvedScript,
            arguments: arguments,
            workingDirectory: resolvedScript.deletingLastPathComponent(),
            environment: environment.values,
            timeout: timeout ?? self.defaultTimeout
        )
    }

    private func execute(
        interpreter: String,
        script: URL,
        arguments: [String],
        workingDirectory: URL,
        environment: [String: String],
        timeout: TimeInterval
    ) async throws -> ScriptResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: interpreter)
        process.arguments = [script.path] + arguments
        process.currentDirectoryURL = workingDirectory
        process.environment = environment

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let start = Date()
        let stdoutTask = Task.detached(priority: .utility) {
            try await Self.readAllBytes(from: stdoutPipe.fileHandleForReading)
        }
        let stderrTask = Task.detached(priority: .utility) {
            try await Self.readAllBytes(from: stderrPipe.fileHandleForReading)
        }

        try process.run()

        let exitCode: Int32
        do {
            exitCode = try await self.waitForExit(process: process, timeout: timeout)
        } catch {
            stdoutPipe.fileHandleForReading.closeFile()
            stderrPipe.fileHandleForReading.closeFile()
            _ = try? await stdoutTask.value
            _ = try? await stderrTask.value
            throw error
        }

        let stdoutData = (try? await stdoutTask.value) ?? Data()
        let stderrData = (try? await stderrTask.value) ?? Data()
        let elapsedMs = Int(Date().timeIntervalSince(start) * 1000.0)
        let stdoutCapture = Self.truncate(stdoutData, limit: self.maxOutputBytes)
        let stderrCapture = Self.truncate(stderrData, limit: self.maxOutputBytes)

        return ScriptResult(
            exitCode: exitCode,
            stdout: stdoutCapture.string,
            stderr: stderrCapture.string,
            executionTimeMs: elapsedMs,
            truncated: stdoutCapture.truncated || stderrCapture.truncated
        )
    }

    private func waitForExit(process: Process, timeout: TimeInterval) async throws -> Int32 {
        try await withThrowingTaskGroup(of: Int32.self) { group in
            group.addTask {
                await Self.awaitTermination(process)
            }

            group.addTask {
                let duration = UInt64(timeout * 1_000_000_000.0)
                try await Task.sleep(nanoseconds: duration)
                try await self.terminate(process: process)
                throw ScriptError.timeout(timeout)
            }

            let exitCode = try await group.next() ?? 0
            group.cancelAll()
            return exitCode
        }
    }

    private func terminate(process: Process) async {
        guard process.isRunning else {
            return
        }

        process.terminate()

        let duration = UInt64(self.killGracePeriod * 1_000_000_000.0)
        try? await Task.sleep(nanoseconds: duration)

        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }

        _ = await Self.awaitTermination(process)
    }

    private static func awaitTermination(_ process: Process) async -> Int32 {
        await withCheckedContinuation { continuation in
            if !process.isRunning {
                continuation.resume(returning: process.terminationStatus)
                return
            }

            process.terminationHandler = { terminatedProcess in
                continuation.resume(returning: terminatedProcess.terminationStatus)
            }
        }
    }

    private static func readAllBytes(from handle: FileHandle) async throws -> Data {
        defer {
            try? handle.close()
        }

        var data = Data()
        for try await byte in handle.bytes {
            data.append(byte)
        }
        return data
    }

    private static func truncate(_ data: Data, limit: Int) -> (string: String, truncated: Bool) {
        guard data.count > limit else {
            return (String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self), false)
        }

        var truncated = data.prefix(limit)
        truncated.append(contentsOf: Array("\n[truncated]".utf8))
        return (String(decoding: truncated, as: UTF8.self), true)
    }
}
