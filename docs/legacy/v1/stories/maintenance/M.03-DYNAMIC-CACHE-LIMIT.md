# M.03 - Dynamic GPU Cache Limit Based on Device RAM

**Status:** Open
**Priority:** P1 - High
**Epic:** Performance Optimization
**Dependencies:** None
**Target:** Ora 1.1

---

## 1. Objective

Dynamically set GPU cache limit based on device RAM to optimize for both low-end (M1 8GB) and high-end (M3 Max 64GB+) devices. Currently using a fixed 512MB limit which may be suboptimal for all configurations.

---

## 2. User Story

As a user with a high-end Mac (32GB+ RAM), I want Ora to use more GPU cache for faster responses, since I have RAM to spare.

As a user with a base M1 (8GB RAM), I want Ora to use less GPU cache to leave room for other apps.

---

## 3. Scope

### In Scope
- Detect available system RAM at startup
- Set cache limit based on RAM tier
- Log the selected cache limit for debugging

### Out of Scope
- Runtime adjustment based on memory pressure (future)
- User-configurable cache limit in preferences (future)

---

## 4. Architecture Alignment

**From Research:**
> We recommend starting with ~0.5 GB cache limit for a 4B model on Mac and tuning from 256 MB up to ~1 GB based on available RAM and model size.

> A Swift MLX demo uses a 512 MB cache on device, while an iOS project dynamically drops to 256 MB if free memory is low.

**Recommended Tiers:**
| Device RAM | Cache Limit | Rationale |
|------------|-------------|-----------|
| ≤8 GB | 256 MB | Leave room for OS and other apps |
| 16 GB | 512 MB | Current default, good balance |
| 32 GB | 768 MB | More headroom for larger cache |
| ≥64 GB | 1 GB | Maximize reuse on high-end devices |

---

## 5. Implementation Plan (Draft)

### 5.1 Files to Create
- None required (logic goes in existing files)

### 5.2 Files to Modify
- `Ora/LLM/LLMService.swift` - Replace fixed cache limit with dynamic calculation

### 5.3 Implementation

```swift
private func calculateOptimalCacheLimit() -> Int {
    let totalRAM = ProcessInfo.processInfo.physicalMemory
    let ramGB = totalRAM / (1024 * 1024 * 1024)
    
    switch ramGB {
    case ..<12:
        return 256 * 1024 * 1024  // 256 MB for 8GB devices
    case 12..<24:
        return 512 * 1024 * 1024  // 512 MB for 16GB devices
    case 24..<48:
        return 768 * 1024 * 1024  // 768 MB for 32GB devices
    default:
        return 1024 * 1024 * 1024 // 1 GB for 64GB+ devices
    }
}
```

### 5.4 Tests to Add
- `OraTests/LLM/LLMServiceTests.swift` - Test cache limit calculation for different RAM values

---

## 6. Acceptance Criteria

- [ ] Cache limit is calculated based on system RAM
- [ ] 8GB devices use 256MB cache limit
- [ ] 16GB devices use 512MB cache limit
- [ ] 32GB devices use 768MB cache limit
- [ ] 64GB+ devices use 1GB cache limit
- [ ] Selected cache limit is logged at startup
- [ ] Unit tests cover all RAM tiers

---

## 7. Verification Plan

### Automated Tests
- Unit test: Mock different RAM values, verify correct cache limit selected
- Test edge cases: exactly 8GB, 16GB, 32GB, 64GB boundaries

### Manual Tests
- [ ] On M1 8GB: Verify 256MB limit is used (check logs)
- [ ] On M2 16GB: Verify 512MB limit is used
- [ ] On M3 Max 64GB: Verify 1GB limit is used
- [ ] Memory stays bounded on all tested devices

---

## 8. Research References

- Community: "Smaller limits (e.g. 20 MB) are used on memory-constrained devices, but this can degrade performance"
- GitHub Issue: Lower cache sizes slow down inference due to constant reallocation
- iOS MLX projects dynamically adjust cache based on available memory
