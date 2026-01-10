# BUG-002: MLX Metal Gate - GPU Serialization for TTS/LLM

**ID:** BUG-002
**Status:** Implemented (2026-01-09)
**Date:** 2026-01-09
**Related:** BUG-001 (Metal Crash TTS/LLM Race)
**Component:** LLM / TTS / Metal GPU

---

## 1. Summary

Implements `MLXMetalGate`, a singleton actor that serializes all MLX Metal GPU operations between LLM and TTS to prevent race condition crashes.

### Problem Solved

The app crashed with `EXC_BAD_ACCESS (SIGSEGV)` when LLM inference and TTS synthesis ran concurrently. Both use MLX with the shared default GPU stream (`Stream.gpu`), and concurrent Metal command buffer access caused GPU driver crashes.

### Why Simple Synchronize Failed

The initial fix (BUG-001) added `Stream.gpu.synchronize()` calls, but this was insufficient because:

1. **Streaming TTS**: Ora uses streaming TTS where sentences are spoken while the LLM continues generating
2. **Synchronize only waits**: It waits for pending GPU work but doesn't prevent new work from being submitted
3. **Race window**: LLM submits work → TTS synchronizes → LLM submits MORE work → TTS starts → crash

```
LLM: ──[gpu work]──[gpu work]──[gpu work]──►
TTS:        sync()──[gpu work]──► CRASH (LLM still submitting)
```

### Solution

Serialize ALL MLX GPU access with an async mutex (MLXMetalGate):

```
LLM: ──[acquire]──[gpu work]──[release]──────────────────►
TTS:        (waiting)         [acquire]──[gpu work]──[release]
```

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
    │  :170-171     │   │  :144-145     │   │  ASR/Embed    │
    └───────────────┘   └───────────────┘   └───────────────┘
```

---

## 3. Implementation Files

### 3.1 MLXMetalGate.swift

**Location:** `Ora/LLM/MLXMetalGate.swift`

```swift
public actor MLXMetalGate {
    public static let shared = MLXMetalGate()

    private var inUse = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// Acquire exclusive access. Suspends if gate is held.
    public func acquire() async {
        if !inUse {
            inUse = true
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    /// Release gate, resume next waiter (FIFO).
    public func release() {
        if let next = waiters.first {
            waiters.removeFirst()
            next.resume()
        } else {
            inUse = false
        }
    }
}
```

### 3.2 LLMService Integration

**Location:** `Ora/LLM/LLMService.swift:168-171`

```swift
private func runGeneration(...) async throws {
    // ... setup ...

    // Wrap in MLXMetalGate to serialize GPU access with TTS
    await MLXMetalGate.shared.acquire()
    defer { Task { await MLXMetalGate.shared.release() } }

    try await container.perform { context in
        // ... MLX generation code ...
        Stream.gpu.synchronize()
    }

    // ... finish ...
}
```

### 3.3 KokoroEngine Integration

**Location:** `Ora/TTS/KokoroEngine.swift:142-158`

```swift
private func runSynthesis(...) async {
    // ... guards ...

    do {
        // Acquire exclusive access to MLX Metal
        await MLXMetalGate.shared.acquire()
        defer { Task { await MLXMetalGate.shared.release() } }

        Stream.gpu.synchronize()
        let (audioBuffer, _) = try tts.generateAudio(...)
        Stream.gpu.synchronize()

        continuation.yield(audioBuffer)
        // ...
    }
}
```

---

## 4. Crash Signatures (For Future Reference)

If you see these crashes, the gate may not be working correctly:

### Pattern A: Command Encoder Race
```
EXC_BAD_ACCESS (SIGSEGV) at 0x1e0
Thread: Swift Concurrency worker
Stack:
  AGX::ResourceGroupUsage::setResource()
  AGX::ComputeContext::setPipelineCommon()
  mlx::core::steel_gemm_splitk_axpby()
  KokoroTTS.generateAudio() or BARTModel.generate()
```

### Pattern B: Command Buffer Double-Commit
```
SIGABRT - MTLReportFailure
"commit an already committed command buffer"
Stack:
  mlx::core::metal::Device::commit_command_buffer()
  mlx_synchronize()
```

### Pattern C: Null Encoder
```
EXC_BAD_ACCESS at 0x0
Stack:
  mlx::core::metal::Device::end_encoding()
  MLXLMCommon.generate() or KokoroTTS.generateAudio()
```

---

## 5. Debugging Tips

### Check Gate Contention

Add temporary logging to see if gate is being used:

```swift
// In MLXMetalGate.acquire():
self.logger.info("Gate acquire requested, inUse=\(self.inUse), waiters=\(self.waiters.count)")
```

Look for in Console.app:
- `Gate acquired (no contention)` - Normal, no waiting
- `Gate contention - waiting` - TTS waiting for LLM or vice versa (expected)
- No gate logs before crash - Gate not being called (bug in integration)

### Verify Gate Coverage

Ensure ALL MLX GPU operations go through the gate:

```bash
# Find all MLX usage that might need gating
grep -r "Stream.gpu\|MLXArray\|\.eval()\|generate(" Ora/ --include="*.swift"
```

Current gated operations:
- `LLMService.runGeneration()` - LLM token generation
- `KokoroEngine.runSynthesis()` - TTS audio synthesis (includes BART G2P)

### Test Concurrent Load

To reproduce the race condition (for testing fixes):

1. Issue a command that triggers tool use (e.g., "list my reminders")
2. The flow is: LLM → Tool → LLM follow-up → TTS
3. Streaming TTS starts while LLM may still be generating
4. Without the gate, this crashes within 1-10 attempts

---

## 6. Performance Impact

| Metric | Without Gate | With Gate |
|--------|--------------|-----------|
| Single LLM query | ~2s | ~2s (no change) |
| Single TTS | ~500ms | ~500ms (no change) |
| Streaming TTS | Parallel with LLM | Serialized (waits) |
| Perceived latency | Lower (parallel) | Slightly higher |
| Stability | Crashes | Stable |

The gate adds latency only when there's actual contention (TTS waiting for LLM or vice versa). For most interactions, there's no overlap.

---

## 7. Future Considerations

### If Crashes Return

1. Check crash log thread - is it LLM or TTS?
2. Verify gate acquire/release are paired (no missing release)
3. Check if new MLX-using code was added without gating
4. Look for gate bypass (direct MLX calls without acquire)

### Adding New MLX Components

If adding ASR, embeddings, or other MLX-based features:

```swift
// Always wrap MLX GPU operations:
await MLXMetalGate.shared.acquire()
defer { Task { await MLXMetalGate.shared.release() } }

// Your MLX code here
Stream.gpu.synchronize()
```

### Alternative: Separate Metal Streams

MLX may support separate GPU streams in the future. If so, LLM and TTS could use isolated streams without serialization. Check MLX documentation for `Stream` API updates.

---

## 8. Related Documentation

- `docs/stories/bugs/BUG-001-Metal-Crash-TTS-LLM-Race.md` - Original investigation
- `docs/reports/crash-fix-metal-retry.md` - LLM retry loop crash (separate issue)
- Crash logs: `~/Library/Logs/DiagnosticReports/Ora-*.ips`

---

## 9. Change History

| Date | Change |
|------|--------|
| 2026-01-09 | Initial implementation after simple sync approach failed |
| 2026-01-09 | Integrated into LLMService and KokoroEngine |
| 2026-01-09 | Verified fix - no crashes after repeated testing |
