# MLX-Audio Assessment

Date: 2026-04-26

## Summary

`Blaizzy/mlx-audio` is worth using for local ASR/TTS research and benchmarking, but it should not replace Ora's current integrations in one step.

The practical path is:

1. Use the Python `mlx-audio` CLI/server as a benchmark harness for new model candidates.
2. Prototype `mlx-audio-swift` behind Ora's existing `ASREngine` and `KokoroEngining`-style abstractions.
3. Treat TTS as the first integration candidate.
4. Treat ASR as a higher-risk optional backend because it moves ASR onto MLX/GPU and may compete with LLM/TTS execution.

## Sources Checked

- `https://github.com/Blaizzy/mlx-audio`
- `https://github.com/Blaizzy/mlx-audio-swift`
- Local Ora files:
  - `Ora/ASR/ASREngine.swift`
  - `Ora/ASR/ASRService.swift`
  - `Ora/ASR/ParakeetEngine.swift`
  - `Ora/ASR/ParakeetBootstrap.swift`
  - `Ora/TTS/TTSService.swift`
  - `Ora/TTS/KokoroEngine.swift`
  - `Ora/Models/ModelTypes.swift`
  - `Ora/Models/ModelPaths.swift`
  - `project.yml`

## Upstream Findings

`mlx-audio` currently provides a broad Python package for TTS, STT, STS, VAD/diarization, a CLI, and an OpenAI-compatible local REST API. The upstream README lists many TTS models, including Kokoro, Qwen3-TTS, CSM, Dia, Chatterbox, Soprano, Voxtral TTS, and others. It also lists STT models including Whisper, Distil-Whisper, Qwen3-ASR, Parakeet, Voxtral/Voxtral Realtime, VibeVoice-ASR, Canary, Moonshine, MMS, Granite Speech, and Qwen2-Audio.

For Ora's native app, `mlx-audio-swift` is the relevant project. It exposes modular Swift products:

- `MLXAudioCore`
- `MLXAudioTTS`
- `MLXAudioSTT`
- `MLXAudioVAD`
- `MLXAudioSTS`
- `MLXAudioCodecs`

It also has a type-erased-ish TTS factory:

- `TTS.loadModel(modelRepo:) -> SpeechGenerationModel`
- `SpeechGenerationModel.generate(...) -> MLXArray`
- `SpeechGenerationModel.generateStream(...) -> AsyncThrowingStream<AudioGeneration, Error>`

Its STT API is less centralized. The CLI manually selects model classes by repo name, then uses:

- `STTGenerationModel.generate(audio:) -> STTOutput`
- `STTGenerationModel.generateStream(audio:) -> AsyncThrowingStream<STTGeneration, Error>`

The Swift package built successfully in `/tmp/mlx-audio-swift` with:

```bash
swift build --target mlx-audio-swift-tts
```

Build result: passed in 89.61s, with warnings. The package resolved:

- `mlx-swift` 0.31.3
- `mlx-swift-lm` 3.31.3
- `swift-transformers` 1.1.9
- `swift-huggingface` 0.8.1

## Fit With Ora

### TTS

This is the better first target.

Ora already has `TTSService` routing through a small `KokoroEngining` protocol and emitting `AudioChunk` streams. `mlx-audio-swift` can be adapted to that shape by wrapping `SpeechGenerationModel.generateSamplesStream(...)` or `generateStream(...)`.

Benefits:

- More TTS models without writing each runtime from scratch.
- Better testing matrix for voices, languages, latency, and quality.
- A path away from the vendored `Vendor/kokoro-ios` dependency if the generic path proves stable.
- Native Swift async APIs, so no Python process is needed in production.

Risks:

- It requires the newer MLX stack and may force an Ora-wide `mlx-swift-lm` migration.
- Some upstream streaming APIs emit final or interval audio depending on the model; Ora still needs its own chunking, queueing, cancellation, and interruption semantics.
- Upstream code calls `Memory.clearCache()` internally in several places. Ora currently coordinates MLX access through `MLXMetalGate` and intentionally controls cache clearing, so the adapter must be measured for LLM/TTS interference.

### ASR

This is useful but riskier as a replacement.

Ora's current ASR path uses FluidAudio Parakeet through CoreML/Neural Engine. That keeps ASR relatively separate from the MLX GPU work used by LLM, embeddings, and Kokoro. Moving ASR to MLX would put ASR, LLM, embeddings, and TTS onto the same MLX/Metal resource pool.

Benefits:

- More STT models, including Qwen3-ASR, Voxtral Realtime, GLM-ASR, Parakeet, Cohere Transcribe, and others.
- Potentially better multilingual ASR and model comparison.
- A possible path to true streaming ASR through `StreamingInferenceSession` for Qwen3-ASR.

Risks:

- Native STT has no single public factory equivalent to `TTS.loadModel`; the current CLI does model dispatch manually.
- Ora would need an `MLXAudioASREngine` wrapper plus model-specific selection.
- Real-time voice assistant behavior depends on partials every 200-400ms and stable finalization. This must be tested model by model.
- GPU contention may regress response latency or TTS start time unless all calls go through `MLXMetalGate`.

## Dependency Risk

The largest adoption blocker is dependency alignment.

Ora's `project.yml` currently includes:

- `FluidAudio` exact `0.10.0`
- `mlx-swift` from `0.21.0`
- `mlx-swift-lm` on `main`
- vendored `kokoro-ios`

Current local resolution shows Ora's `mlx-swift` at `0.31.2` and `mlx-swift-lm` at a `main` revision described as `2.30.6-31-g2a296f1`. `mlx-audio-swift` requires `mlx-swift-lm` from `3.31.3`.

That means adding `mlx-audio-swift` directly to Ora may force the existing LLM, VLM, and embedding integrations through the `mlx-swift-lm` 3.x migration. That should be handled as an explicit dependency migration, not hidden inside an ASR/TTS story.

## Recommendation

Do not replace FluidAudio and Kokoro immediately.

Adopt `mlx-audio` in three phases:

1. Benchmark harness:
   - Add an `agent-tools` script or small runner that uses Python `mlx-audio` and/or `mlx-audio-swift` CLI to compare ASR/TTS models.
   - Track latency, real-time factor, memory peak, first audio chunk latency, WER-ish manual transcripts, and subjective TTS quality.
   - Keep this out of the shipping app.

2. TTS adapter prototype:
   - Add `MLXAudioTTSEngine` behind Ora's existing TTS service shape.
   - Start with Kokoro via `mlx-audio-swift`, then test Soprano and Qwen3-TTS.
   - Keep current `KokoroEngine` as default fallback until parity is proven.
   - Gate all generation through `MLXMetalGate` and measure cache behavior.

3. ASR optional backend:
   - Add a new `MLXAudioASREngine` behind `ASREngine`.
   - Start with offline/batch comparison against current FluidAudio Parakeet.
   - Only then test streaming models like Qwen3-ASR/Voxtral Realtime for live partials.
   - Keep FluidAudio Parakeet as default unless MLX ASR wins on quality without hurting end-to-end latency.

## Decision

Use `mlx-audio` to move faster on model evaluation. Use `mlx-audio-swift` as a candidate runtime dependency only after a scoped MLX dependency migration plan exists. The most likely production win is a pluggable TTS backend first, followed by optional MLX ASR for multilingual or high-quality modes.
