# MLX GPU Cache Fix for Memory Leak

## Root Cause Found

The 15 GB memory growth is caused by **MLX GPU buffer caching**:

```
From footprint tool:
  15 GB        0 B        23 MB       4998    IOAccelerator (graphics)
```

MLX caches Metal GPU buffers for reuse, but without a limit, this cache grows unbounded during inference.

## The Fix

MLX provides `GPU.clearCache()` and `GPU.set(cacheLimit:)` APIs.

### Changes Required

#### 1. LLMService.swift - Set cache limit on prepare

Add after model loads (around line 68):

```swift
// Limit GPU cache to 512MB to prevent unbounded growth
// This still allows buffer reuse but prevents 15GB+ accumulation
GPU.set(cacheLimit: 512 * 1024 * 1024)
logger.info("GPU cache limit set to 512MB")
```

#### 2. LLMService.swift - Clear cache after generation

Add at the end of `runGeneration()` after `Stream.gpu.synchronize()`:

```swift
// Clear GPU cache to release unused buffers
GPU.clearCache()
```

#### 3. KokoroEngine.swift - Clear cache after TTS synthesis

Add at the end of `runSynthesis()` after the audio is generated:

```swift
// Clear GPU cache to release TTS buffers
GPU.clearCache()
```

### Optional: Add memory monitoring

Add a public method to LLMService:

```swift
/// Get current GPU memory snapshot for debugging
func gpuMemorySnapshot() -> (active: Int, cache: Int, peak: Int) {
    let snapshot = GPU.snapshot()
    return (snapshot.activeMemory, snapshot.cacheMemory, snapshot.peakMemory)
}
```

## Verification

After applying the fix:
1. Run Ora and have several conversations
2. Check memory with: `footprint -p $(pgrep -x Ora) | head -20`
3. The "IOAccelerator (graphics)" line should stay under 1-2 GB instead of growing to 15 GB+

## Why This Works

From MLX documentation:
> "The optimal cache size varies by workload. Many developers find that relatively small cache sizes (e.g., 2MB) perform just as well as unconstrained cache sizes."

A 512MB cache limit is generous but prevents unbounded growth. The `clearCache()` calls ensure intermediate buffers don't accumulate across multiple inference runs.
