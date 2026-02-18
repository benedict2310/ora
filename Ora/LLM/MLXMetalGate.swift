//
//  MLXMetalGate.swift
//  Ora
//
//  Serializes access to MLX Metal operations to prevent GPU race conditions.
//  See docs/stories/bugs/BUG-002-MLX-Metal-Gate-Alternative.md for details.
//

import Foundation
import os

/// Serializes access to MLX Metal operations.
///
/// Both LLM (`LLMService`) and TTS (`KokoroEngine`) use MLX with the shared
/// default GPU stream (`Stream.gpu`). Without serialization, concurrent Metal
/// commands can cause `EXC_BAD_ACCESS` crashes in the GPU driver.
///
/// Usage:
/// ```swift
/// await MLXMetalGate.shared.withExclusiveAccess {
///     // ... MLX Metal operations ...
/// }
/// ```
///
/// The gate uses fair FIFO ordering: waiters are resumed in the order they arrived.
public actor MLXMetalGate {

    // MARK: - Singleton

    public static let shared = MLXMetalGate()

    // MARK: - Properties

    private let logger = Logger.ora(category: "MLXMetalGate")

    /// Whether the gate is currently held by a caller.
    private var inUse = false

    /// FIFO queue of continuations waiting for the gate.
    private var waiters: [CheckedContinuation<Void, Never>] = []

    // MARK: - Initialization

    private init() {}

    // MARK: - Public API

    /// Acquire exclusive access to MLX Metal operations.
    ///
    /// If the gate is already held, the caller suspends until it becomes available.
    /// Waiters are resumed in FIFO order.
    public func acquire() async {
        if !self.inUse {
            self.inUse = true
            self.logger.debug("Gate acquired (no contention)")
            return
        }

        self.logger.debug("Gate contention - waiting (\(self.waiters.count) ahead)")

        await withCheckedContinuation { continuation in
            self.waiters.append(continuation)
        }

        self.logger.debug("Gate acquired (after wait)")
    }

    /// Release the gate, allowing the next waiter (if any) to proceed.
    ///
    /// Must be called exactly once after each `acquire()`.
    public func release() {
        if let next = self.waiters.first {
            self.waiters.removeFirst()
            self.logger.debug("Gate released - resuming next waiter (\(self.waiters.count) remaining)")
            next.resume()
        } else {
            self.inUse = false
            self.logger.debug("Gate released (no waiters)")
        }
    }

    /// Execute a closure with exclusive access to MLX Metal.
    ///
    /// This is a convenience wrapper that acquires and releases the gate automatically.
    /// The release is guaranteed to happen before this function returns.
    ///
    /// - Parameter body: The async throwing closure to execute.
    /// - Returns: The result of the closure.
    public func withExclusiveAccess<T: Sendable>(
        _ body: @Sendable () async throws -> T
    ) async rethrows -> T {
        await self.acquire()
        do {
            let result = try await body()
            self.release()  // Release before return (synchronous within actor)
            return result
        } catch {
            self.release()  // Release on error too
            throw error
        }
    }

    // MARK: - Testing Support

    /// Check if the gate is currently held (for testing only).
    public var isAcquired: Bool {
        self.inUse
    }

    /// Number of waiters in the queue (for testing only).
    public var waiterCount: Int {
        self.waiters.count
    }
}
