# Memory Profiling Guide for Ora

## Quick Observations (2026-01-13)

### Idle Memory Behavior
- **Startup**: ~105 MB RSS
- **After model load**: ~2.8 GB spike (expected - LLM/TTS models)
- **After idle period**: Drops to ~250-500 MB
- **VSZ**: ~400-450 GB (virtual, not actual RAM)

### Key Finding
The 30GB leak likely occurs during **active use** (conversations, multiple TTS/LLM generations), not idle. Need to profile during active conversations.

## Manual Profiling Steps

### Option 1: Instruments UI (Recommended)

1. Kill any running Ora: `killall Ora`
2. Open Instruments: `open -a Instruments`
3. Select "Allocations" template
4. Click target dropdown → Choose Target → Navigate to:
   ```
   /Users/bene/Dev-Source-NoBackup/ora/build/Build/Products/Release/Ora.app
   ```
5. Click Record (red button)
6. **Trigger activity**: Use the hotkey, have a conversation, let TTS speak
7. After a few minutes, click Stop
8. Analyze:
   - Sort by "Persistent Bytes" to find what's not being freed
   - Look for MLX, Metal, or MLXArray allocations
   - Check for growing categories over time

### Option 2: Memory Graph Debugger (Xcode)

1. Open Xcode
2. Debug → Attach to Process → Ora
3. Use the app (conversations, TTS)
4. Debug → Debug Memory Graph
5. Look for:
   - Large object clusters
   - Retain cycles
   - Growing collections

### Option 3: CLI Monitoring

```bash
# Quick snapshot
ORA_PID=$(pgrep -x Ora | head -1)
ps -p $ORA_PID -o pid,rss,vsz

# Watch memory during conversation
watch -n 5 "ps -p $(pgrep -x Ora) -o rss= | awk '{print \$1/1024 \" MB\"}'"
```

## Likely Leak Sources

Based on code analysis:

1. **MLX KV Cache** - Grows with context length, may not fully clear between generations
2. **Metal Command Buffers** - GPU resources not properly released
3. **MLXArray tensors** - Intermediate computation results held in memory
4. **Kokoro TTS buffers** - Audio generation artifacts

## What to Look For in Instruments

### Allocations View
- Filter by "MLX" or "Metal" 
- Look for categories with high "# Persistent" and "Persistent Bytes"
- Check "Created & Persistent" vs "Created & Destroyed" ratio

### Call Trees
- Sort by "Bytes Used"
- Look for frames in:
  - `LLMService.runGeneration`
  - `KokoroEngine.runSynthesis`
  - Any MLX or Metal framework calls

## Reproducing the Leak

To trigger the 30GB growth:
1. Start Ora
2. Have multiple conversations (5-10 back-and-forth exchanges)
3. Let TTS speak responses
4. Monitor RSS with: `watch -n 5 "ps -p $(pgrep -x Ora) -o rss="`
5. If RSS keeps growing and doesn't return to baseline, leak confirmed

## Files to Investigate

| File | Why |
|------|-----|
| `Ora/LLM/LLMService.swift` | MLX generation, KV cache |
| `Ora/TTS/KokoroEngine.swift` | TTS synthesis, audio buffers |
| `Ora/LLM/MLXMetalGate.swift` | GPU serialization |
| MLX Swift framework | External - may need upstream fix |
| KokoroSwift framework | External - may need upstream fix |
