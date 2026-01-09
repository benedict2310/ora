# BUG-002: MLX Metal Gate Alternative Approach (Archived)

**ID:** BUG-002
**Status:** Archived (alternative approach preserved for reference)
**Date:** 2026-01-09
**Related:** BUG-001 (Metal Crash TTS/LLM Race)
**Branch:** `fix/BUG.03-mlx-metal-race-condition` (commit `be9a3ae`)

---

## 1. Overview

This documents an alternative, more comprehensive solution to the Metal race condition between LLM and TTS that was developed but not merged. The simpler `Stream.gpu.synchronize()` approach (BUG-001) was chosen instead, but this implementation is preserved in case the simpler approach proves insufficient.

### When to Consider This Approach

Use this if:
- The simple `synchronize()` approach still causes intermittent crashes
- Additional MLX-using components are added (e.g., ASR, embeddings)
- More complex multi-step inference pipelines are needed

---

## 2. Architecture

```
                    ┌─────────────────────────┐
                    │     MLXMetalGate        │
                    │     (singleton actor)   │
                    │                         │
                    │  - FIFO waiter queue    │
                    │  - acquire() / release()│
                    └───────────┬─────────────┘
                                │
            ┌───────────────────┼───────────────────┐
            │                   │                   │
            ▼                   ▼                   ▼
    ┌───────────────┐   ┌───────────────┐   ┌───────────────┐
    │  LLMService   │   │ KokoroEngine  │   │  (future)     │
    │               │   │               │   │  ASR/Embed    │
    └───────────────┘   └───────────────┘   └───────────────┘
```

---

## 3. Implementation

### 3.1 MLXMetalGate.swift

```swift
//
//  MLXMetalGate.swift
//  Ora
//
//  Serializes access to MLX Metal operations to prevent GPU race conditions.
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
/// await MLXMetalGate.shared.acquire()
/// defer { Task { await MLXMetalGate.shared.release() } }
/// // ... MLX Metal operations ...
/// ```
///
/// The gate uses fair FIFO ordering: waiters are resumed in the order they arrived.
public actor MLXMetalGate {

    // MARK: - Singleton

    public static let shared = MLXMetalGate()

    // MARK: - Properties

    private let logger = Logger(subsystem: "com.ora.app", category: "MLXMetalGate")

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
    ///
    /// - Parameter body: The async throwing closure to execute.
    /// - Returns: The result of the closure.
    public func withExclusiveAccess<T: Sendable>(
        _ body: @Sendable () async throws -> T
    ) async rethrows -> T {
        await self.acquire()
        defer {
            Task { await self.release() }
        }
        return try await body()
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
```

### 3.2 Usage in LLMService

```swift
// In runGeneration():
await MLXMetalGate.shared.acquire()
defer { Task { await MLXMetalGate.shared.release() } }

try await container.perform { context in
    // ... MLX generation code ...
    Stream.gpu.synchronize()
}
```

### 3.3 Usage in KokoroEngine

```swift
// In runSynthesis():
await MLXMetalGate.shared.acquire()
defer { Task { await MLXMetalGate.shared.release() } }

Stream.gpu.synchronize()
let (audioBuffer, _) = try tts.generateAudio(...)
Stream.gpu.synchronize()
```

---

## 4. Test Suite

```swift
//
//  MLXMetalGateTests.swift
//  OraTests
//

import XCTest
@testable import Ora

final class MLXMetalGateTests: XCTestCase {

    func test_acquire_setsIsAcquiredTrue() async {
        let gate = MLXMetalGate.shared
        // Reset state
        while await gate.isAcquired { await gate.release() }

        await gate.acquire()
        let isAcquired = await gate.isAcquired
        XCTAssertTrue(isAcquired)
        await gate.release()
    }

    func test_waiters_areResumedInFIFOOrder() async {
        // ... FIFO ordering test ...
    }

    func test_withExclusiveAccess_acquiresAndReleases() async throws {
        // ... convenience wrapper test ...
    }

    func test_withExclusiveAccess_propagatesErrors() async {
        // ... error propagation test ...
    }

    func test_multipleAcquires_serializes() async {
        // ... contention test verifying max concurrent = 1 ...
    }
}
```

---

## 5. Trade-offs vs Simple Synchronize Approach

| Aspect | Simple Sync (BUG-001) | MLXMetalGate (This) |
|--------|----------------------|---------------------|
| **Complexity** | 2 lines per call site | ~100 lines + tests |
| **Latency** | None (sync is fast) | Minimal (async wait) |
| **Fairness** | None (race to sync) | FIFO guaranteed |
| **Scalability** | 2 components OK | N components OK |
| **Debugging** | Harder (race timing) | Easier (queue visible) |

---

## 6. Recovery Instructions

To apply this approach if needed:

```bash
# Cherry-pick the commit
git cherry-pick be9a3ae

# Or extract files manually from the branch
git show be9a3ae:Ora/LLM/MLXMetalGate.swift > Ora/LLM/MLXMetalGate.swift
git show be9a3ae:OraTests/LLM/MLXMetalGateTests.swift > OraTests/LLM/MLXMetalGateTests.swift
```

Then integrate the gate calls into `LLMService.swift` and `KokoroEngine.swift`.

---

## 7. Source Branch

- **Branch:** `fix/BUG.03-mlx-metal-race-condition`
- **Commit:** `be9a3ae80834ef0b37aff563f2e801e37b601c59`
- **Author:** Benedict Bleimschein
- **Date:** 2026-01-09

This branch can be deleted after this documentation is merged, as the full implementation is preserved here.
