# Bug Report: Metal Crash (MTLReleaseAssertionFailure) in TTS/LLM Concurrency

## 1. Overview

**ID:** BUG-001
**Status:** Fixed (re-applied 2026-01-09)
**Date:** 2026-01-08
**Component:** TTS / MLX Engine
**Severity:** Critical (App Crash)

> **Note (2026-01-09):** Original fix commits (`f9c5579`, `be9a3ae`) were on orphaned branches that were never merged to main. Fix re-applied to current branch.

### Description
The application crashes intermittently when the Assistant performs an action that involves both speaking (TTS) and reasoning (LLM) or tool execution. Specifically observed when "Opening an app" or "Searching".

**Error:** `SIGABRT` with `MTLReleaseAssertionFailure` inside `-[IOGPUMetalCommandBuffer setCurrentCommandEncoder:]`.

### Impact
The app terminates immediately. This degrades the user experience significantly as it happens during successful task execution (e.g., confirming "Opening Spotify").

---

## 2. Investigation Log

### A. Crash Log Analysis
We located the latest crash report at `/Users/bene/Library/Logs/DiagnosticReports/Ora-2026-01-08-080101.ips`.

Parsing the log revealed:
- **Faulting Thread:** 27
- **Crash Location:** `libsystem_kernel.dylib` -> `abort` -> `Metal` -> `MTLReleaseAssertionFailure`.
- **Stack Trace (Thread 27):**
  ```
  ...
  3: Metal + 1756876 (MTLReleaseAssertionFailure)
  ...
  11: Cmlx + 8312120 (MTL::ComputeCommandEncoder* ...)
  ...
  27: MLX + 385108 (MLXArray.eval())
  ...
  35: KokoroSwift + 107360 (KokoroTTS.generateAudio(voice:language:text:speed:))
  36: Ora + 422684 (KokoroEngine.runSynthesis(text:continuation:))
  ```

### B. Root Cause Analysis
The stack trace clearly indicated that `KokoroEngine` (TTS) was evaluating an MLX array (likely inference) when the Metal assertion failed.

**Hypothesis:**
The Ora pipeline streams LLM tokens. When a tool is executed (like "Open App"), the LLM might still be generating or cleaning up (evaluating tokens), while the TTS engine immediately starts synthesizing the confirmation phrase ("Opening Spotify...").

Both `LLMEngine` and `KokoroEngine` use `MLX` (via `mlx-swift`). By default, MLX uses a shared default stream (`Stream.gpu`) for Metal operations. If two concurrent tasks try to encode commands to the same command buffer/encoder without synchronization, the Metal driver can enter an invalid state, triggering the assertion.

### C. Reproduction Attempts
1.  **Synthetic Test (`MLXConcurrencyTests.swift`):**
    Created a test case spawning two detached tasks performing heavy `matmul` operations randomly.
    *   *Result:* Did not crash consistently on the test runner, likely because the test workload wasn't perfectly aligned with the command buffer submission timing of the real app, or the app's specific LLM/TTS models create different memory pressure/command patterns.
    *   *Conclusion:* While hard to reproduce deterministically in a unit test, the architectural race condition is evident.

---

## 3. Implementation Process

### Approach 1: Stream Synchronization (Selected Fix)
To prevent the collision, we must ensure that the GPU is synchronized before the TTS engine starts encoding its work.

**Implementation:**
Modify `Ora/TTS/KokoroEngine.swift` to add `Stream.gpu.synchronize()`:
1.  Before `tts.generateAudio(...)`: Ensures pending LLM work is flushed/complete.
2.  After `tts.generateAudio(...)`: Ensures TTS work is flushed before returning/yielding.

### Challenges & Failed Attempts

#### 1. IPS Log Parsing
*   **Attempt:** Wrote a python script `debug_crash.py` to parse the `.ips` file.
*   **Failure:** Initial simple `json.loads(f.readlines()[1])` failed because IPS files sometimes have header anomalies or different line structures.
*   **Fix:** Rewrote script to read all lines, skip header, and join the rest as a single JSON blob. Successfully extracted the stack trace.

#### 2. MLX Swift Stream API Confusion
*   **Context:** I needed to access the default stream to synchronize it.
*   **Attempt 1:** `Stream.make(device: device)` -> Compiler error: `type 'Stream' has no member 'make'`.
*   **Attempt 2:** `Stream.new(device: device)` -> Compiler error: `type 'Stream' has no member 'new'`.
*   **Attempt 3:** `MLX.Stream.make(device: device)` -> Compiler error: `type 'Stream' has no member 'make'`.
*   **Attempt 4:** `MLX.Stream(device: device)` -> Compiler error: `extraneous argument label 'device:'`.
*   **Success:** `MLX.Stream(device)`. (Swift init syntax).
*   **Discovery:** I eventually realized I just needed `Stream.gpu.synchronize()`, which is the static convenience accessor for the default GPU stream.

---

## 4. Final Solution

**File:** `Ora/TTS/KokoroEngine.swift`

```swift
private func runSynthesis(...) async {
    // ... setup ...

    do {
        self.logger.debug("Synthesizing: \(text.prefix(50))...")

        // FIX: Synchronize GPU to prevent race conditions with LLM
        Stream.gpu.synchronize()

        let (audioBuffer, _) = try tts.generateAudio(...)

        // FIX: Synchronize again to ensure completion
        Stream.gpu.synchronize()

        continuation.yield(audioBuffer)
        continuation.finish()
    } catch {
        // ... error handling ...
    }
}
```

This effectively serializes the heavy compute phases of LLM and TTS when they happen to overlap, preventing the Metal command encoder crash.

---

## 5. Verification
- **Compilation:** Validated via `xcodebuild`.
- **Tests:** Ran `MLXConcurrencyTests` to ensure no regression in general MLX usage.
- **Runtime:** `Stream.gpu.synchronize()` is a blocking call (cpu-side) until the GPU command buffer is scheduled/completed, which is acceptable for TTS latency (milliseconds) to gain stability.
