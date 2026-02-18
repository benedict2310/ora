# M.12 - Architectural Improvements (Phase 2 & 3)

**Epic:** Maintenance
**Status:** 🔲 Not Started
**Priority:** P1 (High) for Phase 2, P2 (Medium) for Phase 3
**Estimated Effort:** Phase 2: 3-5 days, Phase 3: 1-2 weeks
**Dependencies:** None
**Target:** macOS 26 (Tahoe)
**Design Reference:** Architectural Review (Feb 2026)

---

## 1. Objective

Address reliability gaps and architectural debt identified in the comprehensive architectural review. This story covers two phases:

- **Phase 2 (Reliability):** Fix observer leaks, error swallowing, backpressure issues, and resource lifecycle bugs that affect stability in long-running sessions.
- **Phase 3 (Architecture):** Decompose god objects, introduce DI/protocol abstractions for testability, and clean up dead code in the persistence layer.

## 2. Context

### What Was Already Fixed (Phase 1)

The following critical issues were resolved immediately:

1. **GPU cache race condition** — `GPU.clearCache()` moved inside `MLXMetalGate` lock in `LLMService.clearCache()` and `unload()`
2. **PersistenceManager fatalError** — Replaced with recovery logic: delete+recreate store, then in-memory fallback
3. **Startup cleanup wired up** — `cleanupOldData()` now called in `AppDelegate.onSetupComplete()`
4. **Missing observer cleanup** — `hotkeyReleaseObserver` now removed in `applicationWillTerminate`
5. **Cloud LLM timeouts** — Already implemented in `CloudLLMBase` (30s request, 120s resource)

### Architectural Review Grades

| Area | Grade | Key Finding |
|------|-------|-------------|
| Concurrency Model | A- | Excellent actor isolation, proper MLXMetalGate FIFO |
| Real-Time Audio | A | Lock-free render path, proper StreamingRingBuffer |
| Task Cancellation | A- | Regular isCancelled checks, proper cleanup |
| TTS Fallback | A- | Kokoro → AVSpeechSynthesizer chain works |
| Tool System | A | Clean protocol, guardrails, audit logging |
| State Flow | A- | Unidirectional data flow, actor isolation |
| Error Handling | B- | Silent swallowing, missing timeouts, fatalError |
| Persistence | B | Dead migration/cleanup code, crash-safe gap |
| Modularity | B- | God objects, 29+ singletons, no DI container |

---

## 3. Phase 2 — Reliability Fixes

### 3.1 Fix Observer Cleanup (OverlayWindowController, MemoryFileWatcher)

**Files:**
- `Ora/Overlay/OverlayWindowController.swift:233-335`
- `Ora/Memory/MemoryFileWatcher.swift`

**Problem:** `OverlayWindowController` adds NSEvent monitors and NotificationCenter observers in `addDismissMonitors()`, but if `hide()` is never called (e.g., overlay created but never shown), monitors leak. `MemoryFileWatcher` has no `deinit` to stop watching on deallocation.

**Fix:**
- Add `deinit` to `OverlayWindowController` that calls `removeDismissMonitors()`
- Add `deinit` to `MemoryFileWatcher` that calls `stopWatching()`
- Track monitor active state independently from panel visibility

**Acceptance Criteria:**
- [ ] OverlayWindowController cleans up monitors in deinit
- [ ] MemoryFileWatcher stops DispatchSource in deinit
- [ ] No leaked NSEvent monitors after overlay lifecycle

---

### 3.2 Fix Error Swallowing (Model Download, AppleScript, SQL Rollback)

**Files:**
- `Ora/Preferences/Tabs/ModelsPreferencesView.swift:144-146`
- `Ora/Tools/Automation/AppleScriptUtils.swift:54-56, 89-91`
- `Ora/Memory/MemoryIndex.swift:346, 456`

**Problem:**
1. Model download errors silently discarded with empty `catch {}` — no user feedback
2. AppleScript JSON parse errors logged at debug level, returns nil silently
3. SQL rollback errors swallowed via `try?` — database can be left in corrupt state if rollback fails

**Fix:**
1. Log download errors at warning level, update UI state with error message
2. Raise AppleScript parse error logging to warning level with full context
3. Log SQL rollback failures at error level (critical diagnostic information)

**Acceptance Criteria:**
- [ ] Model download failures show error in UI
- [ ] AppleScript errors logged at warning level with context
- [ ] SQL rollback failures logged at error level
- [ ] No empty catch blocks remain

---

### 3.3 Add Audio Stream Backpressure

**File:** `Ora/Audio/AudioService.swift:170`

**Problem:** `AudioService` uses `.bufferingNewest(10)` which drops old audio frames when ASR can't keep up. At 100 frames/sec with ASR processing at 50 frames/sec, this causes gaps in transcription.

**Current:**
```swift
let stream = AsyncStream<AudioFrame>(bufferingPolicy: .bufferingNewest(10)) { ... }
```

**Analysis Needed:** Before changing to `.unbounded`, verify:
- ASR processing speed vs frame rate in practice
- Whether frame dropping is intentional for memory safety (long recordings)
- Whether suspension-based backpressure would cause audio capture stalls

**Potential Fix:** Change to `.bufferingNewest(50)` or `.unbounded` with a drain timeout. Or implement a dedicated ring buffer that signals the consumer.

**Acceptance Criteria:**
- [ ] Audio frames not dropped during normal ASR processing
- [ ] Memory bounded during extended recording sessions
- [ ] No regression in ASR latency or accuracy

---

### 3.4 Add FluidVAD Retry-After-Failure Logic

**File:** `Ora/ASR/ASRService.swift:162-199`

**Problem:** If FluidAudio VAD initialization fails once, `fluidVADInitialized` is set to `true` and all future sessions permanently fall back to EnergyVAD without ever retrying.

**Fix:**
- Cache failure with a timestamp
- Retry after 5 minutes (or next session start)
- Log when using fallback VAD so users/developers know

**Acceptance Criteria:**
- [ ] FluidVAD re-attempts initialization after cooldown period
- [ ] Fallback to EnergyVAD is logged at notice level
- [ ] Successful retry after transient failure verified in tests

---

### 3.5 Replace ASR Audio Buffer O(n) removeFirst

**File:** `Ora/ASR/ASRService.swift:242-245`

**Problem:** `allAudio.removeFirst(overflow)` on arrays up to 9.6M samples is O(n) and triggers a full array copy, causing periodic memory spikes during long sessions.

**Fix:** Replace with circular buffer (ring buffer) or `ArraySlice` windowing.

**Acceptance Criteria:**
- [ ] Audio buffer trimming is O(1) amortized
- [ ] No memory spikes during 10-minute sessions
- [ ] Existing ASR accuracy unaffected

---

### 3.6 Fix `try?` on Task.sleep Swallowing Cancellation

**Files:**
- `Ora/Orchestration/SimplePipelineController.swift:518, 756, 790`
- `Ora/Memory/MemoryFileWatcher.swift:65, 154`

**Problem:** `try? await Task.sleep()` swallows both successful completion and cancellation errors. After sleep is cancelled, code proceeds as if sleep succeeded, potentially causing incorrect state transitions.

**Fix:** Replace with:
```swift
do {
    try await Task.sleep(for: .seconds(delay))
} catch {
    return  // Cancelled — exit early
}
```

**Acceptance Criteria:**
- [ ] Task.sleep cancellation properly exits the enclosing scope
- [ ] No `try?` on Task.sleep in non-trivial contexts
- [ ] State transitions not triggered after cancellation

---

## 4. Phase 3 — Architectural Improvements

### 4.1 Decompose SimplePipelineController (907 lines)

**File:** `Ora/Orchestration/SimplePipelineController.swift`

**Problem:** God object managing 8-state state machine, ASR coordination, LLM orchestration, TTS execution, UI updates, tool proposals, confirmation handling, and streaming responses.

**Proposed Decomposition:**

```
SimplePipelineController (orchestrator, ~300 lines)
├── PipelineStateMachine       — State transitions with validation
├── ConfirmationHandler        — Tool proposal confirm/deny flow
└── StreamingResponseHandler   — Token handling, sentence chunking, TTS coordination
```

**Key Design Decisions:**
- State machine should validate transitions (`canTransition(from:to:)`)
- Replace notification-based proposal handling with direct protocol calls
- Remove dead `usesStreamingTTS = false` code paths (~50 lines)

**Acceptance Criteria:**
- [ ] SimplePipelineController < 400 lines
- [ ] State machine validates all transitions
- [ ] Dead streaming TTS code removed
- [ ] All existing tests pass
- [ ] No behavior changes

---

### 4.2 Introduce Protocol Abstractions for Testability

**Problem:** 29+ singletons accessed via `.shared` throughout codebase. Components can't be tested in isolation. Tests require global state cleanup and can't run in parallel.

**Missing Protocols:**
- `PersistenceServicing` — replace direct `PersistenceManager.shared` access
- `SessionManaging` — replace direct `ConversationManager.shared` access
- `AudioServicing` — already exists but not used consistently

**Approach:**
1. Define protocols for the 5 most-accessed singletons
2. Add protocol-typed properties to components that need them
3. Keep `.shared` defaults in constructors for production code
4. Inject test doubles in tests

**Priority Order:**
1. `PersistenceServicing` (accessed from 10+ files)
2. `AudioServicing` (accessed from orchestration + ASR)
3. `TTSServicing` (accessed from orchestration)
4. `OverlayPresenting` (accessed from orchestration)

**Acceptance Criteria:**
- [ ] Top 4 singletons have protocol abstractions
- [ ] At least 5 test files use injected mocks instead of .shared
- [ ] No behavior changes in production

---

### 4.3 Complete or Remove Persistence Migration Dead Code

**Files:**
- `Ora/Persistence/PersistenceManager.swift:394-418`
- `Ora/Persistence/Models/Session.swift:55`

**Problem:** `migrateSessionsToRelationshipStorage()` exists but is never called. New sessions set `isMigrated = true` but still use JSON blob storage. The `MessageModel` relationship storage is effectively dead code.

**Options (choose one):**
- **Option A (Complete Migration):** Wire up migration at startup, switch new sessions to relationship storage, deprecate blob path after N releases
- **Option B (Remove Dead Code):** Delete `MessageModel`, `migrateSessionsToRelationshipStorage()`, `isMigrated` flag, and simplify Session to blob-only

**Recommendation:** Option A if relationship storage is still desired (better query support, normalization). Option B if blob storage is sufficient (simpler, fewer moving parts).

**Acceptance Criteria:**
- [ ] Decision made and documented
- [ ] No dead migration code remains
- [ ] If migrated: old sessions converted, new sessions use relationships
- [ ] If removed: all MessageModel references cleaned up

---

### 4.4 Split Oversized Memory Module Files

**Files:**
- `Ora/Memory/MemoryIndex.swift` (1,272 lines)
- `Ora/Memory/MemoryDistiller.swift` (700 lines)
- `Ora/Memory/MemoryTriggerDetector.swift` (690 lines)

**Proposed Splits:**

**MemoryIndex → 3 files:**
- `MemoryIndexSchema.swift` — FTS5 database setup, schema creation
- `HybridSearcher.swift` — Search scoring, ranking, result formatting
- `TranscriptIndexer.swift` — Transcript chunk loading, indexing

**MemoryDistiller → 2 files:**
- `DistillerOrchestrator.swift` — LLM calls, retry logic, session selection
- `TranscriptRenderer.swift` — Message formatting, payload generation

**MemoryTriggerDetector → 2 files:**
- `SignalDetector.swift` — Linguistic signal detection, vocabulary matching
- `MemoryScorer.swift` — Entity overlap scoring, session filtering

**Acceptance Criteria:**
- [ ] No file exceeds 500 lines
- [ ] All existing tests pass
- [ ] Internal APIs unchanged (only file boundaries move)

---

### 4.5 Consolidate Configuration and Magic Strings

**Problem:**
- `"com.ora.app"` appears 87 times as Logger subsystem
- 17+ UserDefaults keys scattered as magic strings
- Timing constants (delays, timeouts) spread across files
- Error enums duplicated across 7 tool modules

**Fix:**
1. Create `Logger.ora(category:)` extension
2. Create `UserDefaults+Ora.swift` with typed properties
3. Create `Constants.swift` for timing/threshold constants
4. Create `ToolError` base protocol or generic enum

**Acceptance Criteria:**
- [ ] Logger subsystem string appears only in the extension
- [ ] UserDefaults keys defined in one location
- [ ] No hardcoded timing constants in business logic
- [ ] Tool error definitions share common structure

---

## 5. Testing Strategy

### Phase 2 Tests
- Unit test for FluidVAD retry logic
- Unit test for audio buffer circular buffer
- Integration test for observer cleanup lifecycle
- Verify no error swallowing in tool execution paths

### Phase 3 Tests
- State machine transition validation tests
- DI/mock injection tests for top 4 singletons
- Persistence migration correctness tests
- File split: all existing tests must pass unchanged

---

## 6. Risks and Mitigations

| Risk | Mitigation |
|------|-----------|
| Phase 3 decomposition breaks subtle behavior | Run full test suite after each file split; keep behavioral tests |
| DI introduction is too large a change | Do incrementally — one singleton per PR |
| Migration decision blocks progress | Default to Option B (remove dead code) if no clear need for relationship storage |
| Audio backpressure change affects latency | Benchmark before/after; keep old buffering policy as fallback |

---

## 7. Priority Order

1. **3.1** Fix observer cleanup (quick win, prevents leaks)
2. **3.2** Fix error swallowing (quick win, improves debuggability)
3. **3.6** Fix try? on Task.sleep (quick win, prevents state bugs)
4. **3.4** FluidVAD retry logic (moderate, improves VAD reliability)
5. **3.5** ASR buffer optimization (moderate, performance improvement)
6. **3.3** Audio backpressure (needs investigation, affects core pipeline)
7. **4.1** Decompose SimplePipelineController (large, highest architectural impact)
8. **4.5** Consolidate configuration (medium, improves maintainability)
9. **4.3** Persistence migration cleanup (medium, removes dead code)
10. **4.4** Split memory module files (large, improves readability)
11. **4.2** Protocol abstractions / DI (largest, highest testability impact)

---

## Code Review Findings

**Reviewer:** Codex Subagent
**Date:** 2026-02-18T20:58:04Z
**Commit reviewed:** e9ffd3a
**Iteration:** 3

### Summary
- Files reviewed: 120
- Build status: Pass

### Issues Found

#### P0 - Critical (Must fix)
- None.

#### P1 - Major (Should fix)
- None.

#### P2 - Minor (Can defer)
- None.

### Future Considerations (Out of Scope)
- `Ora/Persistence/PersistenceManager.swift:47` - Consider adding an explicit upgrade test from the pre-Option-B SwiftData schema to confirm no user data reset occurs on migration failures.

### Approval Status
- [x] All P0 issues resolved
- [x] All P1 issues resolved
- [x] Ready for merge

---

## Implementation Summary
**Date:** 2026-02-18
**Branch:** `feat/m12-phase2-reliability-fixes`
**Commits:** 4
**Implemented by:** codex (complexity score: 9/10)
**Reviewed by:** codex (3 iterations)

### Files Changed
- `Ora/ASR/ASRService.swift` — FluidVAD retry logic + O(1) circular audio buffer
- `Ora/Audio/AudioService.swift` — Increased buffer to `.bufferingNewest(50)`
- `Ora/Memory/MemoryFileWatcher.swift` — Added `deinit` to stop DispatchSource
- `Ora/Memory/MemoryIndex.swift` — Extracted into 3 files (MemoryIndexSchema, HybridSearcher, TranscriptIndexer)
- `Ora/Memory/MemoryDistiller.swift` — Extracted DistillerOrchestrator
- `Ora/Memory/MemoryTriggerDetector.swift` — Extracted MemoryScorer
- `Ora/Overlay/OverlayWindowController.swift` — Added `deinit` to clean up monitors
- `Ora/Orchestration/SimplePipelineController.swift` — Decomposed into 5 extension files
- `Ora/Orchestration/PipelineStateMachine.swift` — New: enforces state transition validity
- `Ora/Orchestration/ConfirmationHandler.swift` — New: extracted confirmation logic
- `Ora/Orchestration/StreamingResponseHandler.swift` — New: extracted streaming logic
- `Ora/Persistence/PersistenceManager.swift` — Removed dead migration code (Option B)
- `Ora/Persistence/Models/Session.swift` — Removed isMigrated, MessageModel references
- `Ora/Persistence/Models/MessageModel.swift` — Deleted (dead code removed)
- `Ora/Preferences/Tabs/ModelsPreferencesView.swift` — Error swallowing fixed
- `Ora/Tools/Automation/AppleScriptUtils.swift` — AppleScript errors at warning level
- `Ora/Utilities/Logger+Ora.swift` — New: centralized logger subsystem
- `Ora/Utilities/Constants.swift` — New: centralized timing/threshold constants
- `Ora/Utilities/UserDefaults+Ora.swift` — New: typed UserDefaults keys
- `Ora/Tools/ToolError.swift` — New: shared tool error protocol
- `OraTests/ASRServiceTests.swift` — New: FluidVAD retry + circular buffer tests
- `OraTests/Orchestration/PipelineStateMachineTests.swift` — New: state machine tests
