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

        // Start readers before run() so the pipes are drained as the process writes.
        // Size-limited reads prevent unbounded memory growth (P0-1).
        let start = Date()
        let limit = self.maxOutputBytes
        let stdoutTask = Task.detached(priority: .utility) {
            try await Self.readLimited(from: stdoutPipe.fileHandleForReading, limit: limit)
        }
        let stderrTask = Task.detached(priority: .utility) {
            try await Self.readLimited(from: stderrPipe.fileHandleForReading, limit: limit)
        }

        // Clean up reader tasks if process.run() fails (P0-2).
        do {
            try process.run()
        } catch {
            stdoutPipe.fileHandleForReading.closeFile()
            stderrPipe.fileHandleForReading.closeFile()
            _ = try? await stdoutTask.value
            _ = try? await stderrTask.value
            throw error
        }

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

        let stdoutResult = (try? await stdoutTask.value) ?? (data: Data(), truncated: false)
        let stderrResult = (try? await stderrTask.value) ?? (data: Data(), truncated: false)
        let elapsedMs = Int(Date().timeIntervalSince(start) * 1000.0)

        return ScriptResult(
            exitCode: exitCode,
            stdout: String(data: stdoutResult.data, encoding: .utf8) ?? String(decoding: stdoutResult.data, as: UTF8.self),
            stderr: String(data: stderrResult.data, encoding: .utf8) ?? String(decoding: stderrResult.data, as: UTF8.self),
            executionTimeMs: elapsedMs,
            truncated: stdoutResult.truncated || stderrResult.truncated
        )
    }

    private func waitForExit(process: Process, timeout: TimeInterval) async throws -> Int32 {
        try await withThrowingTaskGroup(of: Int32.self) { group in
            group.addTask {
                await Self.awaitTermination(process)
            }

            group.addTask {
                // Clamp to a minimum of 1 second to prevent UInt64 underflow on
                // negative values loaded from user-controlled manifest.json.
                let safeTimeout = max(1, timeout)
                let duration = UInt64(safeTimeout * 1_000_000_000.0)
                try await Task.sleep(nanoseconds: duration)
                await self.terminate(process: process)
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

        // Do NOT call awaitTermination here. waitForExit already has a task holding
        // the process.terminationHandler via awaitTermination. Registering a second
        // handler overwrites the first, orphaning that continuation and potentially
        // hanging the task group indefinitely (P2 fix).
    }

    private static func awaitTermination(_ process: Process) async -> Int32 {
        await withCheckedContinuation { continuation in
            // Set the handler first to avoid the race where the process exits
            // between an isRunning check and handler registration (P1-4).
            nonisolated(unsafe) var didResume = false
            process.terminationHandler = { terminatedProcess in
                guard !didResume else { return }
                didResume = true
                continuation.resume(returning: terminatedProcess.terminationStatus)
            }
            // If the process already exited before we set the handler,
            // the handler won't fire — resume manually.
            if !process.isRunning, !didResume {
                didResume = true
                continuation.resume(returning: process.terminationStatus)
            }
        }
    }

    /// Reads bytes from `handle` up to `limit`, then drains (discards) the rest.
    ///
    /// Draining is required to prevent the child process from blocking when the
    /// pipe buffer fills. The returned `truncated` flag is true when output was
    /// discarded. Bounded reads prevent unbounded memory growth (P0-1 fix).
    private static func readLimited(
        from handle: FileHandle,
        limit: Int
    ) async throws -> (data: Data, truncated: Bool) {
        defer { try? handle.close() }
        var data = Data()
        var truncated = false
        for try await byte in handle.bytes {
            if data.count < limit {
                data.append(byte)
            } else {
                truncated = true
                // Continue draining so the child process is never blocked on a full pipe.
            }
        }
        if truncated {
            data.append(contentsOf: Array("\n[truncated]".utf8))
        }
        return (data, truncated)
    }
}
