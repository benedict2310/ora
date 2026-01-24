# Maintenance Stories

Stories for quality improvements, optimizations, and technical debt in Ora.

## Story Index

| ID | Story | Priority | Status |
|----|-------|----------|--------|
| M.01 | [Test Coverage Improvements](M.01-TEST-COVERAGE-IMPROVEMENTS.md) | P0 - Critical | 🚧 In Progress |
| M.02 | [Unified Model Status Tracking](M.02-UNIFIED-MODEL-STATUS-TRACKING.md) | P1 - High | ✅ Complete |
| M.03 | [Response Triggering Improvements](M.03-STT-QUALITY-IMPROVEMENTS.md) | P1 - High | ✅ Complete |
| M.04 | [Voice Processing](M.04-VOICE-PROCESSING.md) | P2 - Medium | 🚧 To Do |
| M.06 | [Speech End Detection](M.06-SPEECH-END-DETECTION.md) | P1 - High | ✅ Complete |
| M.07 | [Streaming ASR Migration](M.07-STREAMING-ASR-MIGRATION.md) | P1 - High | 🚧 To Do |

---

## MLX Memory Optimization (Backlog)

Stories for optimizing MLX GPU memory management, based on community research and best practices.

| ID | Story | Priority | Impact | Effort |
|----|-------|----------|--------|--------|
| M.01b | [KV Cache Persistence](M.01-KV-CACHE-PERSISTENCE.md) | P0 - Critical | High (50%+ faster follow-up turns) | Medium |
| M.02b | [Cache Clearing Strategy](M.02-CACHE-CLEARING-STRATEGY.md) | P1 - High | Medium (10-20% faster) | Low |
| M.03b | [Dynamic Cache Limit](M.03-DYNAMIC-CACHE-LIMIT.md) | P1 - High | Medium (device-optimized) | Low |
| M.04b | [Idle Model Unloading](M.04-IDLE-MODEL-UNLOADING.md) | P2 - Medium | High (memory savings) | Medium |
| M.05 | [Memory Monitoring](M.05-MEMORY-MONITORING.md) | P3 - Low | Low (developer tooling) | Low |

## Background

These stories address findings from research into MLX GPU memory management:

1. **KV Cache Persistence (M.01)** - Biggest performance win. MLX supports reusing transformer key-value cache across conversation turns, avoiding reprocessing of history. Can reduce time-to-first-token by 50%+ on follow-up messages.

2. **Cache Clearing Strategy (M.02)** - Current implementation clears GPU cache after every generation, which is overly aggressive. Research shows clearing only at session end is better practice when a cache limit is set.

3. **Dynamic Cache Limit (M.03)** - Fixed 512MB limit works but isn't optimal for all devices. 8GB Macs should use less (256MB), 64GB Macs can use more (1GB).

4. **Idle Model Unloading (M.04)** - For users who leave Ora running but use it infrequently, unloading models after idle timeout (15 min) can free 2-3GB RAM. Reload takes 2-4 seconds.

5. **Memory Monitoring (M.05)** - Developer tooling to verify optimizations work. Exposes `GPU.snapshot()` data in preferences and logs.

## Research Sources

- Apple WWDC 2025: "Explore large language models on Apple silicon with MLX"
- MLX Swift GitHub Issues #66, #17 (memory management discussions)
- MLX Core GitHub Issue #755 (cache behavior clarification)
- Midgar Corp Blog: "Integrating Local LLMs with MLX"
- Community benchmarks and production deployment experiences

## Implementation Order

Recommended order for maximum impact with minimal risk:

1. **M.02** (Low effort, immediate improvement) - Remove per-call cache clearing
2. **M.03** (Low effort, broad benefit) - Dynamic cache limits
3. **M.01** (Medium effort, big win) - KV cache persistence
4. **M.04** (Medium effort, specific use case) - Idle unloading
5. **M.05** (Low effort, nice to have) - Monitoring
