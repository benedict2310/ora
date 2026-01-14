# M.05 - GPU Memory Monitoring Dashboard

**Status:** Open
**Priority:** P3 - Low
**Epic:** Developer Experience
**Dependencies:** None
**Target:** Ora 1.2+

---

## 1. Objective

Add memory monitoring capabilities for debugging and optimization. This helps developers understand memory behavior and users diagnose issues.

---

## 2. User Story

As a developer, I want to see real-time GPU memory stats so I can verify memory optimizations are working and debug issues.

As a power user, I want to see memory usage in preferences so I can understand why the app is using resources.

---

## 3. Scope

### In Scope
- Expose `GPU.snapshot()` data through a monitoring API
- Add memory stats to About/Debug section in Preferences
- Log memory stats periodically for debugging
- Add memory snapshot before/after generation for performance analysis

### Out of Scope
- Real-time memory graph (overly complex for v1)
- Memory alerts/notifications
- Automatic memory optimization suggestions

---

## 4. Architecture Alignment

**From Research:**
> MLX provides a `GPU.snapshot()` API that returns memory usage statistics:
> - `activeMemory` – bytes currently in use by active MLX arrays
> - `cacheMemory` – bytes held in the GPU cache (allocated but not actively used)  
> - `peakMemory` – peak active memory observed

> "activeMemory + cacheMemory is the total memory allocated by MLX"

**Interpreting Stats:**
- `activeMemory`: Model weights + current computation tensors
- `cacheMemory`: Reusable buffers kept for future operations
- `peakMemory`: High-water mark during intensive operations

**Note:** MLX stats may be lower than system `footprint` due to overhead not tracked by MLX.

---

## 5. Implementation Plan (Draft)

### 5.1 Files to Create
- `Ora/Utilities/MemoryMonitor.swift` - Wrapper around GPU.snapshot() with formatting

### 5.2 Files to Modify
- `Ora/LLM/LLMService.swift` - Log memory before/after generation (debug builds)
- `Ora/TTS/KokoroEngine.swift` - Log memory before/after synthesis (debug builds)
- `Ora/Preferences/Tabs/AboutPreferencesView.swift` - Add memory stats section

### 5.3 Implementation

```swift
struct MemoryMonitor {
    static func snapshot() -> MemorySnapshot {
        let gpuSnapshot = GPU.snapshot()
        return MemorySnapshot(
            activeMemory: gpuSnapshot.activeMemory,
            cacheMemory: gpuSnapshot.cacheMemory,
            peakMemory: gpuSnapshot.peakMemory,
            cacheLimit: GPU.cacheLimit,
            timestamp: Date()
        )
    }
    
    static func formattedStats() -> String {
        let s = snapshot()
        return """
        GPU Memory:
          Active: \(formatBytes(s.activeMemory))
          Cache:  \(formatBytes(s.cacheMemory))
          Peak:   \(formatBytes(s.peakMemory))
          Limit:  \(formatBytes(s.cacheLimit))
        """
    }
}
```

### 5.4 Tests to Add
- `OraTests/Utilities/MemoryMonitorTests.swift` - Test formatting and snapshot capture

---

## 6. Acceptance Criteria

- [ ] `MemoryMonitor.snapshot()` returns current GPU memory stats
- [ ] Memory stats displayed in Preferences > About section
- [ ] Stats include: Active, Cache, Peak, and Cache Limit
- [ ] Stats are formatted human-readable (e.g., "512 MB" not "536870912")
- [ ] Debug builds log memory before/after each generation
- [ ] Logging can be toggled via environment variable or debug flag

---

## 7. Verification Plan

### Automated Tests
- Unit test: MemoryMonitor returns valid snapshot
- Unit test: Formatting works for various byte sizes (KB, MB, GB)

### Manual Tests
- [ ] Open Preferences > About, verify memory stats are displayed
- [ ] Have a conversation, verify stats update (peak should increase)
- [ ] Clear cache, verify cache memory drops to near zero
- [ ] Check console logs for memory debug output

---

## 8. Research References

- MLX documentation: `GPU.snapshot()` API
- Community: "Use MLX's stats as relative measurements, rely on system tools for absolute memory impact"
- MLX also exposes `GPU.cacheLimit` and `GPU.memoryLimit` properties for display
