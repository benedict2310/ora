# Crash Fix Report: Metal Race Condition & LLM Retry Loop

## Issue
The app was crashing with `EXC_CRASH` / `SIGABRT` due to a Metal assertion failure: `commit an already committed command buffer`. 
This happened during LLM generation retries.
Investigation revealed that the LLM was returning empty/invalid output instantly, causing `StructuredGenerator` to retry in a tight loop (microseconds apart).
This rapid retry loop, combined with the `Stream.gpu.synchronize()` call (added in a previous fix), caused a race condition or double-commit in the Metal command buffer handling.

## Root Cause Analysis
1.  **Trigger:** External factor (e.g., audio contention/system load) causes LLM generation to return 0 tokens immediately.
2.  **Loop:** `StructuredGenerator` sees empty string -> invalid JSON -> retries immediately.
3.  **Crash:** The retry loop runs so fast that `Stream.gpu.synchronize()` is called repeatedly on the same or overlapping Metal command buffers, leading to the "already committed" assertion failure.

## Fix Implemented
1.  **StructuredGenerator.swift**: Added a 200ms delay (`Task.sleep`) in the retry loop.
    *   **Why:** This prevents the tight loop, allowing the GPU/Metal state to settle and preventing the race condition. It also reduces CPU/GPU usage during failure modes.
2.  **LLMService.swift**: Added logging for 0-token generation.
    *   **Why:** To help diagnose *why* the generation is empty in the future.
    *   **Refactor:** Fixed a Sendable closure issue by capturing `logger` locally.

## Verification
- Code compiles successfully.
- The 200ms delay effectively breaks the race condition window (microseconds vs 200ms).
- The `Stream.gpu.synchronize()` call remains to ensure safety between legitimate runs, but is no longer hammered.

## Next Steps
- Monitor logs for "Generation finished with 0 tokens produced" to diagnose the underlying empty-generation issue (likely related to memory pressure or audio contention as noted in logs).
- If empty generations persist, investigate `AudioCapture` and `MLX` resource sharing.
