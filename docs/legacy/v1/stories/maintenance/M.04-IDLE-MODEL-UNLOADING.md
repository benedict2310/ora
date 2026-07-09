# M.04 - Idle Model Unloading

**Status:** Open
**Priority:** P2 - Medium
**Epic:** Memory Optimization
**Dependencies:** None
**Target:** Ora 1.2

---

## 1. Objective

Implement automatic model unloading after extended periods of inactivity to free memory for other applications. This is especially valuable for users who leave Ora running but only use it occasionally.

---

## 2. User Story

As a user who activates Ora once or twice per hour, I want the app to free up memory when I'm not using it, so my other apps have more RAM available.

As a user, I accept a brief delay (~2-3 seconds) when reactivating Ora after it has been idle, in exchange for lower background memory usage.

---

## 3. Scope

### In Scope
- Track last user interaction timestamp
- Unload LLM and TTS models after configurable idle timeout (default: 15 minutes)
- Reload models on next activation
- Clear GPU cache when unloading
- User preference to disable idle unloading (for users who prefer instant response)

### Out of Scope
- Partial model unloading (e.g., keep tokenizer loaded)
- Predictive loading based on usage patterns
- iOS-style memory pressure callbacks (macOS handles this differently)

---

## 4. Architecture Alignment

**From Research:**
> To free memory when the assistant is idle, you can unload the MLX model by deallocating its container. In Swift, this simply means dropping references to the LLMModel or ModelContainer (setting your modelContainer variable to nil). MLX will then release the model's weights from unified memory.

> Loading a 4B-parameter quantized model on Apple Silicon is fairly fast – typically on the order of 1–3 seconds on an SSD. A 4B 4-bit model can initialize in ~2–4 seconds on an M1/M2, and potentially under 2 seconds on an M3.

**Unload Pattern:**
```swift
func unloadForIdle() async {
    modelContainer = nil
    GPU.clearCache()
    logger.info("Models unloaded after idle timeout")
}
```

**Reload Latency Expectations:**
| Device | Expected Reload Time |
|--------|---------------------|
| M1 | 2-4 seconds |
| M2 | 2-3 seconds |
| M3 | 1-2 seconds |

---

## 5. Implementation Plan (Draft)

### 5.1 Files to Create
- `Ora/Orchestration/IdleManager.swift` - Tracks idle state et manages unload/reload

### 5.2 Files to Modify
- `Ora/LLM/LLMService.swift` - Add `unload()` method if not present, ensure clean teardown
- `Ora/TTS/TTSService.swift` - Add `unload()` method for TTS engine
- `Ora/Orchestration/SimplePipelineController.swift` - Integrate with IdleManager
- `Ora/Preferences/GeneralPreferencesView.swift` - Add toggle for idle unloading
- `Ora/Persistence/Models/AppSettings.swift` - Add `idleUnloadEnabled` and `idleTimeoutMinutes` settings

### 5.3 Tests to Add
- `OraTests/Orchestration/IdleManagerTests.swift` - Test idle detection and unload triggering

---

## 6. Acceptance Criteria

- [ ] Idle timer starts when last user interaction completes
- [ ] After 15 minutes (default) of no interaction, models are unloaded
- [ ] Memory footprint drops significantly after unload (from ~3GB to <500MB)
- [ ] Next activation triggers model reload automatically
- [ ] User sees brief loading indicator during reload
- [ ] Reload completes within 4 seconds on M1, 2 seconds on M3
- [ ] Preference toggle allows disabling idle unloading
- [ ] Preference allows customizing idle timeout (5, 10, 15, 30 minutes)

---

## 7. Verification Plan

### Automated Tests
- Unit test: IdleManager triggers callback after timeout
- Unit test: IdleManager resets timer on user interaction
- Unit test: Verify models can be unloaded and reloaded successfully

### Manual Tests
- [ ] Leave Ora idle for 15 minutes, verify memory drops (use Activity Monitor)
- [ ] Activate Ora after unload, verify reload happens with loading indicator
- [ ] Time the reload on different devices (M1, M2, M3)
- [ ] Disable idle unloading in preferences, verify models stay loaded
- [ ] Change timeout to 5 minutes, verify earlier unload

### Benchmarks
| Metric | Target |
|--------|--------|
| Memory after unload | <500 MB |
| Reload time (M1) | <4 seconds |
| Reload time (M3) | <2 seconds |

---

## 8. Research References

- Community: "The MLX team's mlx_lm.server will unload the current model when switching to a new one to save memory"
- GitHub Issue #467: Feature request for idle unloading in mlx-lm
- LM Studio implements LRU model unloading for memory management
