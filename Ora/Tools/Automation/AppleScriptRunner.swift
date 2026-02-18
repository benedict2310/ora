//
//  AppleScriptRunner.swift
//  Ora
//
//  Core runner for executing AppleScripts via osascript
//

import Foundation
import os.log

/// Result of an AppleScript execution
struct AppleScriptResult: Sendable {
    /// Raw stdout from the script
    let stdout: String

    /// Parsed JSON payload (if script returned JSON envelope)
    let json: JSONValue?

    /// Execution duration
    let duration: TimeInterval
}

/// Configuration for AppleScript execution
struct AppleScriptConfig: Sendable {
    /// Timeout in seconds (default: 10s)
    let timeout: TimeInterval

    /// Whether to parse output as JSON envelope
    let expectsJSON: Bool

    /// Default configuration
    static let `default` = AppleScriptConfig(timeout: 10, expectsJSON: false)

    /// JSON-expecting configuration
    static func json(timeout: TimeInterval = 10) -> AppleScriptConfig {
        AppleScriptConfig(timeout: timeout, expectsJSON: true)
    }
}

/// Protocol for AppleScript execution (allows mocking in tests)
protocol AppleScriptRunning: Sendable {
    func execute(script: String, config: AppleScriptConfig) async throws -> AppleScriptResult
    func execute(script: String, arguments: [String], config: AppleScriptConfig) async throws -> AppleScriptResult
}

extension AppleScriptRunning {
    func execute(script: String, arguments: [String], config: AppleScriptConfig) async throws -> AppleScriptResult {
        try await execute(script: script, config: config)
    }
}

/// Executes AppleScripts with timeout, error normalization, and JSON parsing
actor AppleScriptRunner {
    private let logger = Logger.ora(category: "AppleScriptRunner")

    /// Active processes for cancellation support
    private var activeProcesses: [UUID: Process] = [:]

    // MARK: - Public API

    /// Execute an AppleScript string
    /// - Parameters:
    ///   - script: The AppleScript source code
    ///   - config: Execution configuration (timeout, JSON parsing)
    /// - Returns: The execution result
    /// - Throws: AppleScriptError on failure
    func execute(script: String, config: AppleScriptConfig = .default) async throws -> AppleScriptResult {
        let startTime = Date()
        let processId = UUID()

        logger.debug("Executing script (id: \(processId.uuidString.prefix(8)))")

        // Create process
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        // Track for cancellation
        self.activeProcesses[processId] = process

        defer {
            self.activeProcesses.removeValue(forKey: processId)
        }

        do {
            // Run with timeout
            let result = try await self.runWithTimeout(
                process: process,
                stdoutPipe: stdoutPipe,
                stderrPipe: stderrPipe,
                timeout: config.timeout,
                processId: processId
            )

            let duration = Date().timeIntervalSince(startTime)
            logger.debug("Script completed in \(String(format: "%.2f", duration))s")

            // Parse JSON if expected
            var json: JSONValue?
            if config.expectsJSON {
                json = AppleScriptUtils.parseJSONEnvelope(result)
            }

            return AppleScriptResult(stdout: result, json: json, duration: duration)

        } catch let error as AppleScriptError {
            throw error
        } catch {
            throw AppleScriptError.processStartFailed(reason: error.localizedDescription)
        }
    }

    /// Execute an AppleScript string with argv arguments
    /// - Parameters:
    ///   - script: The AppleScript source code
    ///   - arguments: Arguments passed as argv
    ///   - config: Execution configuration (timeout, JSON parsing)
    /// - Returns: The execution result
    /// - Throws: AppleScriptError on failure
    func execute(
        script: String,
        arguments: [String],
        config: AppleScriptConfig = .default
    ) async throws -> AppleScriptResult {
        let startTime = Date()
        let processId = UUID()

        logger.debug("Executing script (id: \(processId.uuidString.prefix(8))) with argv count \(arguments.count)")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")

        var processArgs = ["-e", script]
        if !arguments.isEmpty {
            processArgs.append("--")
            processArgs.append(contentsOf: arguments)
        }
        process.arguments = processArgs

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        self.activeProcesses[processId] = process

        defer {
            self.activeProcesses.removeValue(forKey: processId)
        }

        do {
            let result = try await self.runWithTimeout(
                process: process,
                stdoutPipe: stdoutPipe,
                stderrPipe: stderrPipe,
                timeout: config.timeout,
                processId: processId
            )

            let duration = Date().timeIntervalSince(startTime)
            logger.debug("Script completed in \(String(format: "%.2f", duration))s")

            var json: JSONValue?
            if config.expectsJSON {
                json = AppleScriptUtils.parseJSONEnvelope(result)
            }

            return AppleScriptResult(stdout: result, json: json, duration: duration)
        } catch let error as AppleScriptError {
            throw error
        } catch {
            throw AppleScriptError.processStartFailed(reason: error.localizedDescription)
        }
    }

    /// Execute an AppleScript file
    /// - Parameters:
    ///   - url: URL to the .scpt or .applescript file
    ///   - config: Execution configuration
    /// - Returns: The execution result
    /// - Throws: AppleScriptError on failure
    func execute(file url: URL, config: AppleScriptConfig = .default) async throws -> AppleScriptResult {
        let startTime = Date()
        let processId = UUID()

        logger.debug("Executing script file: \(url.lastPathComponent) (id: \(processId.uuidString.prefix(8)))")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = [url.path]

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        self.activeProcesses[processId] = process

        defer {
            self.activeProcesses.removeValue(forKey: processId)
        }

        do {
            let result = try await self.runWithTimeout(
                process: process,
                stdoutPipe: stdoutPipe,
                stderrPipe: stderrPipe,
                timeout: config.timeout,
                processId: processId
            )

            let duration = Date().timeIntervalSince(startTime)
            logger.debug("Script file completed in \(String(format: "%.2f", duration))s")

            var json: JSONValue?
            if config.expectsJSON {
                json = AppleScriptUtils.parseJSONEnvelope(result)
            }

            return AppleScriptResult(stdout: result, json: json, duration: duration)

        } catch let error as AppleScriptError {
            throw error
        } catch {
            throw AppleScriptError.processStartFailed(reason: error.localizedDescription)
        }
    }

    /// Cancel all running scripts
    func cancelAll() {
        logger.info("Cancelling all active scripts (\(self.activeProcesses.count) running)")
        for (id, process) in self.activeProcesses {
            if process.isRunning {
                process.terminate()
                logger.debug("Terminated script \(id.uuidString.prefix(8))")
            }
        }
        self.activeProcesses.removeAll()
    }

    /// Check if an app is scriptable and authorized
    /// - Parameter bundleId: The bundle identifier of the app
    /// - Returns: true if the app can be controlled
    func canControlApp(bundleId: String) async -> Bool {
        // Sanitize bundleId to prevent injection attacks
        let sanitizedBundleId = AppleScriptUtils.escapeForAppleScript(bundleId)
        let script = """
        tell application id "\(sanitizedBundleId)"
            return true
        end tell
        """

        do {
            _ = try await self.execute(script: script, config: AppleScriptConfig(timeout: 5, expectsJSON: false))
            return true
        } catch let error as AppleScriptError {
            switch error {
            case .permissionDenied:
                return false
            default:
                // Other errors might be transient
                return false
            }
        } catch {
            return false
        }
    }

    // MARK: - Private

    private func runWithTimeout(
        process: Process,
        stdoutPipe: Pipe,
        stderrPipe: Pipe,
        timeout: TimeInterval,
        processId: UUID
    ) async throws -> String {
        try await withThrowingTaskGroup(of: String.self) { group in
            // Task to run the process
            group.addTask {
                try await self.runProcess(
                    process: process,
                    stdoutPipe: stdoutPipe,
                    stderrPipe: stderrPipe
                )
            }

            // Task to enforce timeout
            group.addTask {
                try await Task.sleep(for: .seconds(timeout))
                throw AppleScriptError.timeout(seconds: timeout)
            }

            // Wait for first result
            do {
                let result = try await group.next()!
                group.cancelAll()
                return result
            } catch is CancellationError {
                // Clean up process on cancellation
                if process.isRunning {
                    process.terminate()
                }
                throw AppleScriptError.cancelled
            } catch let error as AppleScriptError where error.errorType == "timeout" {
                // Terminate on timeout
                if process.isRunning {
                    process.terminate()
                    self.logger.warning("Script \(processId.uuidString.prefix(8)) timed out after \(timeout)s")
                }
                throw error
            }
        }
    }

    private func runProcess(
        process: Process,
        stdoutPipe: Pipe,
        stderrPipe: Pipe
    ) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            // Use DispatchQueue for thread safety
            let queue = DispatchQueue(label: "com.ora.applescript.process")

            var stdoutData = Data()
            var stderrData = Data()
            var didResume = false

            // Collect stdout
            stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                queue.async {
                    stdoutData.append(data)
                }
            }

            // Collect stderr
            stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                queue.async {
                    stderrData.append(data)
                }
            }

            process.terminationHandler = { proc in
                // Clean up handlers
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil

                // Read any remaining data
                let finalStdout = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                let finalStderr = stderrPipe.fileHandleForReading.readDataToEndOfFile()

                queue.async {
                    guard !didResume else { return }
                    didResume = true

                    stdoutData.append(finalStdout)
                    stderrData.append(finalStderr)

                    let stdout = String(data: stdoutData, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    let stderr = String(data: stderrData, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

                    if proc.terminationStatus == 0 {
                        continuation.resume(returning: stdout)
                    } else {
                        let error = AppleScriptError.parse(
                            stderr: stderr.isEmpty ? stdout : stderr,
                            errorCode: proc.terminationStatus
                        )
                        continuation.resume(throwing: error)
                    }
                }
            }

            do {
                try process.run()
            } catch {
                queue.async {
                    guard !didResume else { return }
                    didResume = true
                    continuation.resume(throwing: AppleScriptError.processStartFailed(reason: error.localizedDescription))
                }
            }
        }
    }
}

extension AppleScriptRunner: AppleScriptRunning {}
