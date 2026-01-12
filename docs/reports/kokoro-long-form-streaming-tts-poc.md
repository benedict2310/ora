# Kokoro Long-Form Streaming TTS PoC - Process Log

## Goal
Build a long-form, low-latency Kokoro TTS streaming pipeline in the
`agent-tools/KokoroTTSPreview` test app, then migrate the approach to Ora.

## Scope
- Token-aware chunking aligned with Kokoro's real tokenization
- Streamed synthesis per chunk
- Trim + crossfade stitching for seamless playback
- Cancellation ("barge-in")
- Instrumentation for TTFA and per-chunk timings

## Current Status
- Xcode-built preview binary runs and reproduces `tooManyTokens` for long text.
- SwiftPM build failed with missing metallib; Xcode build provides metallib.

## Decisions / Constraints
- Chunking must use Kokoro tokenization, not LLM tokens or characters.
- Target hard cap: 480 tokens (headroom under ~510 limit).
- Prefer Xcode build pipeline for metallib generation.
- Crossfade approach: hold the tail of each buffer and crossfade with the next
  buffer's head before scheduling the remainder.

## References
- `agent-tools/KokoroTTSPreview`
- `docs/stories/tts-integration/T.03-SENTENCE-CHUNKER.md`
- `kokoro_long_form_streaming_tts_po_c_swift_onnx.md` (user research)

## Log
- Established Xcode build path for KokoroTTSPreview; long text now fails with
  `tooManyTokens`, confirming expected failure mode.
- Added a local Kokoro preprocessor that uses MisakiSwift + model `config.json`
  vocab for token counts; this avoids patching KokoroSwift internals.
- Implemented `TokenAwareChunker` with streaming buffer and boundary heuristics
  (sentence/strong/comma/whitespace) plus a hard-cap fallback.
- Added `StreamSimulator` and wired it to the chunker for incremental text input.
- Added `KokoroSynthesizer`, `AudioPlaybackQueue`, trim + crossfade helpers,
  and a `TTSCoordinator` to synthesize and play chunks sequentially.
- Ran Xcode-built streaming PoC for long text (tokenCount 3559) and confirmed
  chunk/synthesis logs with TTFA ~1.33s; run was manually cut after ~30s.
- Added stitch logging (chunk->chunk timestamps) in the playback queue so
  crossfade boundaries are visible during runs.
- Added stitch text snippets (tail/head) to identify audible join locations.
- Adjusted chunker to prefer sentence/strong boundaries; whitespace-only cuts
  now wait until `targetMax` or hard-cap to reduce mid-sentence joins.
- Rebuilt via `xcodebuild` from `agent-tools/KokoroTTSPreview` (SwiftPM build
  crashed with duplicate MLX classes). New chunks land at sentence ends with
  ~177-token sizes; stitch logs confirm joins after `engine.` boundaries.
- Added CLI support for a text file argument and ran the preview with
  `agent-tools/KokoroTTSPreview/long-form-sample.txt` (tokenCount 7384).
- Added `--min-speak` and `--no-stream` CLI flags for short-input testing.
- Fixed a chunker edge case where an empty buffer on `flush()` could loop
  indefinitely (tokenCount 0 now returns nil).
- Ran the one-word sample with no-stream + min-speak override; final chunk
  committed and synthesized as expected (tokenCount 41).
- Added a short wait after flush so very short samples finish playback before
  the process exits.

## Next Steps
- A/B chunking thresholds (targetMin/Max, hardCap) against naturalness.
- Tune trim/crossfade parameters after chunking adjustments.
- Add a "sentence-first" mode for production with latency guardrails.
