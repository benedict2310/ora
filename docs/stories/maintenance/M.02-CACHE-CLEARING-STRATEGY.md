# M.02 - Optimize GPU Cache Clearing Strategy

**Status:** Open
**Priority:** P1 - High
**Epic:** Performance Optimization
**Dependencies:** None
**Target:** Ora 1.1

---

## 1. Objective

Optimize when `GPU.clearCache()` is called to balance memory usage and inference latency. Current implementation clears after every generation, which may be overly aggressive and hurt performance.

---

## 2. User Story

As a user, I want Ora to respond as quickly as possible during a conversation, while still maintaining reasonable memory usage during long sessions.

---

## 3. Scope

### In Scope
- Remove `GPU.clearCache()` from per-generation calls
- Add cache clearing at session end instead
- Add cache clearing when app enters background
- Benchmark to verify no memory growth issues with new strategy

### Out of Scope
- Dynamic cache limit adjustment (covered in M.03)
- Memory pressure callbacks from OS (future)

---

## 4. Architecture Alignment

**From Research:**
> Avoid calling `GPU.clearCache()` on every generation unless necessary; instead rely on a reasonable cacheLimit and only clear periodically. Clearing the GPU cache frees all cached Metal buffers immediately, preventing buildup, but doing it too often forfeits the speed benefits of reuse.

> Most community examples do not clear on every inference when a cache limit is in place. An MLX iOS guide never calls clearCache during normal chat flow, instead trusting the 512 MB cap.

**Recommended Strategy:**
1. Set `GPU.set(cacheLimit: 512MB)` once at startup (already done)
2. Do NOT call `GPU.clearCache()` after each generation
3. Call `GPU.clearCache()` at:
   - End of conversation session
   - App entering background
   - Before loading a different model (if applicable)

---

## 5. Implementation Plan (Draft)

### 5.1 Files to Create
- None required

### 5.2 Files to Modify

**`Ora/LLM/LLMService.swift`** (line ~297):
- Remove `GPU.clearCache()` call at the end of `runGeneration()` method
- Keep the `GPU.clearCache()` in `clearCache()` method (line ~189) - this is called at session end
- Keep the `GPU.clearCache()` in `unload()` method (line ~175) - this is called when unloading model

**`Ora/TTS/KokoroEngine.swift`** (line ~161):
- Remove `GPU.clearCache()` call inside `runSynthesis()` method

**`Ora/Orchestration/AgentLoop.swift`**:
- No changes needed - `endSession()` already calls `LLMService.shared.clearCache()` which calls `GPU.clearCache()`

**`Ora/AppDelegate.swift`**:
- Add `applicationDidResignActive(_:)` method to clear GPU cache when app backgrounds
- Import MLX to access `GPU.clearCache()`

### 5.3 Tests to Add
- Manual benchmarking test comparing TTFT before/after changes

---

## 6. Acceptance Criteria

- [ ] `GPU.clearCache()` is NOT called after each LLM generation
- [ ] `GPU.clearCache()` is NOT called after each TTS synthesis
- [ ] `GPU.clearCache()` IS called when session ends
- [ ] `GPU.clearCache()` IS called when app goes to background
- [ ] Memory stays under 4GB after 10 back-to-back conversations (with 512MB cache limit)
- [ ] Latency benchmark shows improvement over per-call clearing (target: 10-20% faster TTFT on turn 2+)

---

## 7. Verification Plan

### Automated Tests
- Test: Memory footprint after 10 generations stays bounded
- Test: Verify cache is cleared on session end

### Manual Tests
- [ ] Have 5 back-and-forth conversations without clearing cache
- [ ] Monitor memory with `footprint -p $(pgrep -x Ora)` - should stay under 4GB
- [ ] Verify app background triggers cache clear (check logs)
- [ ] Compare response latency with old vs new clearing strategy

### Benchmarks
Benchmarks will be recorded during implementation verification.

| Metric | Before (per-call clear) | After (session-end clear) |
|--------|-------------------------|---------------------------|
| Turn 2 TTFT | (record during impl) | (target: 10-20% faster) |
| Turn 3 TTFT | (record during impl) | (record during impl) |
| Peak memory (5 turns) | (record during impl) | (should be similar) |

---

## 8. Research References

- MLX GitHub Issue #66: GPU cache limit discussion
- Community: "Periodic clearing can be done as a safety valve – e.g. every N generations or when switching to a very different task/model"
- Midgar Corp Blog: Uses 512MB cache without per-call clearing
