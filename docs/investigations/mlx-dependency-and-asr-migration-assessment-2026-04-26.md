# MLX Dependency and ASR Migration Assessment

Date: 2026-04-26

## Executive Decision

Do the MLX dependency migration before attempting a production ASR backend swap.

`mlx-audio-swift` is a plausible native dependency, but it requires the `mlx-swift-lm` 3.x line and `mlx-swift` 0.31.3+. Ora currently resolves `mlx-swift-lm` from `main` to a 2.x-era checkout locally and still has code that depends on older loader APIs, especially in embeddings. ASR migration then adds a second risk layer: moving speech recognition from FluidAudio/CoreML/Neural Engine onto MLX/Metal, where it competes with LLM, embeddings, and TTS.

Recommended order:

1. Stabilize MLX dependencies on pinned versions.
2. Migrate Ora's LLM/VLM/embedding loaders to `mlx-swift-lm` 3.x.
3. Add `mlx-audio-swift` as a benchmark-only or hidden experimental dependency.
4. Prototype TTS first.
5. Prototype ASR as an optional backend, not a replacement.

## Current State

### Ora MLX Dependencies

`project.yml` currently declares:

- `mlx-swift` from `0.21.0`
- `mlx-swift-lm` on `branch: main`
- `swift-transformers` from `1.1.0`
- vendored `kokoro-ios`
- `FluidAudio` exact `0.10.0`

Local `Package.resolved` currently has:

- `mlx-swift` `0.31.2`
- `mlx-swift-lm` `main` revision `2a296f145c3129fea4290bb6e4a0a5fb458efa06`

Local checkout description:

```text
mlx-swift-lm: 2.30.6-31-g2a296f1
mlx-swift:    0.31.2
```

### Upstream Requirements

`mlx-audio-swift` `main` declares:

- Swift tools `6.2`
- `mlx-swift` `.upToNextMajor(from: "0.30.6")`
- `mlx-swift-lm` `.upToNextMajor(from: "3.31.3")`
- `swift-transformers` `.upToNextMajor(from: "1.1.6")`
- `swift-huggingface` `.upToNextMajor(from: "0.8.1")`

In isolated `/tmp/mlx-audio-swift` builds, SwiftPM resolved:

- `mlx-swift` `0.31.3`
- `mlx-swift-lm` `3.31.3`
- `swift-transformers` `1.1.9`
- `swift-huggingface` `0.8.1`

Both relevant upstream targets built:

```bash
swift build --target mlx-audio-swift-tts
swift build --target mlx-audio-swift-stt
```

Results:

- TTS target passed in 89.61s, with warnings.
- STT target passed in 5.09s after the cached build, with one unhandled README warning.

### Current Ora Build State

`./build.sh test` failed before reaching Ora source compile errors:

```text
Unable to find module dependency: 'CAsyncHTTPClient'
Unable to find module dependency: 'CNIOLLHTTP'
Unable to find module dependency: 'CNIOExtrasZlib'
Unable to find module dependency: 'CNIOPosix'
Unable to find module dependency: '_NumericsShims'
Testing cancelled because the build failed.
```

Artifacts:

- `.artifacts/xcodebuild.test.log`
- `.artifacts/TestResults.xcresult`

This looks like an Xcode/SPM build-product dependency scan issue around `EventSource`, `AsyncHTTPClient`, NIO, and Numerics. It blocks a clean red/green capture for the MLX migration until resolved or cleaned, but it is separate from the `mlx-swift-lm` 3.x API migration.

## MLX 3.x Migration Impact

### What Changes

`mlx-swift-lm` 3.x still exposes `ModelContainer`, `ModelContext`, `LLMModelFactory`, `VLMModelFactory`, `LMInput`, `TokenIterator`, and `MLXLMCommon.generate(input:context:iterator:)`.

Ora's generation path is mostly already on the newer generation style:

- `LLMService.runGeneration(...)` creates `LMInput`.
- It uses `TokenIterator`.
- It streams through `MLXLMCommon.generate(input:context:iterator:)`.
- It uses `container.perform { context in ... }`.

The main break is model loading and embeddings.

### LLM/VLM Loader Changes

Current Ora code:

```swift
let configuration = ModelConfiguration(directory: modelPath)
container = try await LLMModelFactory.shared.loadContainer(configuration: configuration)
container = try await VLMModelFactory.shared.loadContainer(configuration: configuration)
```

In 3.x, the factory load call requires an explicit model source and tokenizer loader. For local directories this becomes conceptually:

```swift
container = try await LLMModelFactory.shared.loadContainer(
    from: modelPath,
    using: tokenizerLoader
)

container = try await VLMModelFactory.shared.loadContainer(
    from: modelPath,
    using: tokenizerLoader
)
```

The cleanest tokenizer path is to add the `MLXHuggingFace` product and use its tokenizer loader macro:

```swift
import MLXHuggingFace

using: #huggingFaceTokenizerLoader()
```

Alternative: write an Ora-owned `TokenizerLoader` bridge around `Tokenizers.AutoTokenizer.from(modelFolder:)`. That avoids macros but duplicates the adapter work already supplied by `MLXHuggingFace`.

Recommendation: use `MLXHuggingFace` unless the macro creates XcodeGen or signing friction.

### Embedding Loader Changes

Current Ora code:

```swift
private var modelContainer: MLXEmbedders.ModelContainer?

let modelConfiguration = MLXEmbedders.ModelConfiguration(
    id: self.configuration.modelIdentifier
)

return try await MLXEmbedders.loadModelContainer(
    configuration: modelConfiguration
)
```

In 3.x, embedding APIs become:

- `MLXEmbedders.ModelContainer` -> `EmbedderModelContainer`
- `MLXEmbedders.loadModelContainer(...)` -> `EmbedderModelFactory.shared.loadContainer(...)`
- The loader requires explicit `Downloader` and `TokenizerLoader` for remote IDs, or a local directory.

Conceptually:

```swift
private var modelContainer: EmbedderModelContainer?

return try await EmbedderModelFactory.shared.loadContainer(
    from: downloader,
    using: tokenizerLoader,
    configuration: ModelConfiguration(id: self.configuration.modelIdentifier)
)
```

Embedding execution should move from the deprecated three-argument closure:

```swift
modelContainer.perform { model, tokenizer, pooling in ... }
```

to:

```swift
modelContainer.perform { context in
    let tokenizer = context.tokenizer
    let model = context.model
    let pooling = context.pooling
}
```

### Package Changes Needed

Likely `project.yml` changes:

- Pin `mlx-swift` to at least `0.31.3`, preferably exact for migration.
- Pin `mlx-swift-lm` to a tested 3.x version, probably exact `3.31.3` initially.
- Add `MLXHuggingFace` product from `mlx-swift-lm`.
- Add `MLXAudioCore` and `MLXAudioSTT` only after the 3.x migration is green.
- Add `MLXAudioTTS` separately if/when TTS prototype begins.
- Consider adding `swift-huggingface` only if `mlx-audio-swift` or app code uses it directly. `mlx-swift-lm`'s `MLXHuggingFace` macros do not themselves require app code to import the HuggingFace client unless the downloader macro is used.

Avoid:

- Depending on `mlx-audio-swift` `main` in production. It has tags, but the README installation currently recommends `branch: main`. For Ora, use a commit SHA or tag after validation.
- Letting both Ora and `mlx-audio-swift` pull incompatible `mlx-swift-lm` ranges.

### Source Files Likely Touched

Required for MLX 3.x:

- `project.yml`
- `Ora/LLM/LLMService.swift`
- `Ora/Memory/EmbeddingService.swift`
- `OraTests/LLM/LLMServiceTests.swift` if loader behavior is made injectable/testable
- `OraTests/EmbeddingServiceTests.swift`

Likely support files:

- `Ora/Utilities/MLXTokenizerLoader.swift` if not using `MLXHuggingFace`
- `Ora/Utilities/MLXDownloader.swift` if not using `#hubDownloader()`
- `Ora/LLM/LocalModelLoader.swift` if we extract loader selection for unit testing

## MLX Migration Risks

### High

- **Build graph churn:** `mlx-swift-lm` 3.x adds the `MLXHuggingFace` product and macro targets. Ora already has broad dependency pressure from containerization, NIO, EventSource, SwiftData, FluidAudio, MLX, Sparkle, and SwiftPM dependencies.
- **Embedding API break:** `EmbeddingService` is a definite source change, not just a dependency bump.
- **Runtime model compatibility:** VLM and text model registries change over time. Model metadata must be reverified against 3.31.3 exactly.
- **GPU cache policy conflict:** Ora intentionally avoids clearing GPU cache on every LLM/TTS generation. Upstream audio code calls `Memory.clearCache()` internally in several models.

### Medium

- **Tokenizer loader behavior:** Ora currently relies on local model directories downloaded by its own `HuggingFaceStrategy`. 3.x loaders require explicit tokenizer loading and may fail differently when `chat_template.jinja`, `tokenizer_config.json`, or tokenizer files are missing.
- **Macro adoption:** `MLXHuggingFace` macro use is concise but can complicate compiler diagnostics. A local adapter is more verbose but easier to debug.
- **Swift tools mismatch:** `mlx-audio-swift` requires Swift tools 6.2. Local `swift --version` is Swift 6.2, but `project.yml` still says `SWIFT_VERSION: "6.0"` and `xcodeVersion: "16.0"`. Verify CI and release machines before adopting it.

### Low

- **LLM generation loop:** Ora is already using `LMInput`, `TokenIterator`, persistent KV cache, and modern async generation.
- **TTS service boundary:** Existing `KokoroEngining` and `TTSServicing` boundaries are narrow.

## ASR Migration Assessment

### Current Ora ASR Contract

Ora's ASR stack currently has three layers:

1. `AudioService` emits 100 ms, 16 kHz mono `AudioFrame` values.
2. `ASRService` owns buffering, VAD, partial cadence, finalization, and fallback.
3. `ParakeetEngine` implements `ASREngine` using FluidAudio `AsrManager`.

Current behavior:

- Minimum partial attempt after 2,560 samples, about 160 ms.
- Partial window is the latest 160,000 samples, about 10 seconds.
- Full final buffer can grow to 9,600,000 samples, about 10 minutes.
- Neural VAD uses FluidAudio Silero VAD with CPU/Neural Engine.
- Energy VAD is fallback.
- Finalization transcribes the entire accumulated buffer.
- If final output is empty, Ora falls back to the last partial.

That architecture optimizes for perceived responsiveness and final accuracy, but it assumes repeated partial inference is acceptable.

### Why MLX ASR Is Riskier

FluidAudio Parakeet currently runs through CoreML/Neural Engine. MLX ASR would run through MLX/Metal. That changes the resource isolation story.

Today:

- ASR: CoreML/Neural Engine
- VAD: CoreML/Neural Engine or CPU fallback
- LLM: MLX/Metal through `MLXMetalGate`
- TTS: MLX/Metal through `MLXMetalGate`
- Embeddings: MLX/Metal through `MLXMetalGate`

With MLX ASR:

- ASR, LLM, TTS, and embeddings all contend for `MLXMetalGate`.
- If ASR partials run every 100-200 ms, LLM time-to-first-token and TTS start latency can regress badly.
- If ASR does not use the gate, prior Metal crash history says this risks GPU instability.

### Candidate ASR Models

Observed through Hugging Face API on 2026-04-26:

| Model | Runtime type | Approx listed file payload | Notes |
|:--|:--|--:|:--|
| `mlx-community/Qwen3-ASR-0.6B-4bit` | `qwen3_asr` | ~711 MB | Best first MLX ASR prototype candidate. Smaller than current MLX Parakeet and has Qwen3 streaming-session code. |
| `mlx-community/Qwen3-ASR-1.7B-4bit` | `qwen3_asr` | ~1.61 GB | Quality candidate after 0.6B. Higher memory/latency risk. |
| `mlx-community/GLM-ASR-Nano-2512-4bit` | `glmasr` | ~1.29 GB | Interesting batch candidate; needs quality testing. |
| `mlx-community/parakeet-tdt-0.6b-v3` | Parakeet MLX | ~2.51 GB | Same family as current ASR but larger MLX weights and GPU contention. Not an obvious default replacement. |
| `mlx-community/Voxtral-Mini-4B-Realtime-2602-4bit` | `voxtral_realtime` | ~3.15 GB | Potential multilingual/realtime quality option, but heavy for default Ora. |

Current Ora Parakeet model metadata estimates FluidAudio/CoreML assets around ~600 MB.

### Upstream Swift ASR API Shape

`mlx-audio-swift` has `STTGenerationModel`:

```swift
func generate(audio: MLXArray, generationParameters: STTGenerateParameters) -> STTOutput
func generateStream(audio: MLXArray, generationParameters: STTGenerateParameters) -> AsyncThrowingStream<STTGeneration, Error>
```

The CLI selects model classes by repo-name heuristics:

- `Qwen3ASRModel`
- `VoxtralRealtimeModel`
- `CohereTranscribeModel`
- `ParakeetModel`
- `FireRedASR2Model`
- `SenseVoiceModel`
- `GLMASRModel`

There is not yet a clean `STT.loadModel(modelRepo:)` factory equivalent to `TTS.loadModel(modelRepo:)`.

Important distinction:

- `generateStream(audio:)` streams generated tokens while processing a supplied audio array. It is not necessarily microphone-live streaming.
- `StreamingInferenceSession` is a live-ish incremental session, but it is typed specifically around `Qwen3ASRModel`.

### ASR Integration Options

#### Option A: Benchmark Harness Only

Use `mlx-audio-swift-stt` or a small `agent-tools` runner to compare models against curated audio samples.

Pros:

- Low product risk.
- Fast quality iteration.
- No app dependency yet.
- Lets us compare WER-ish accuracy, latency, memory, and language behavior.

Cons:

- Does not give users model choice yet.

Recommendation: do this first.

#### Option B: Batch MLX ASR Engine Behind `ASREngine`

Add `MLXAudioASREngine` implementing:

```swift
func process(_ buffer: AVAudioPCMBuffer, language: String?) async throws -> ASRPartial?
func finalize(_ buffer: AVAudioPCMBuffer, language: String?) async throws -> ASRFinalSegment?
```

Pros:

- Lowest disruption to Ora's existing ASRService.
- Can compare final transcript quality quickly.
- Works for Parakeet, GLM-ASR, Qwen3-ASR, Voxtral classes with a wrapper.

Cons:

- Partial calls must be throttled. Ora's current repeated 10-second-window inference is probably too expensive for MLX ASR.
- Word timings may not be available for all models.
- Model class dispatch is manual unless we add an Ora-owned STT factory.

Recommendation: useful as an experimental backend, but do not enable for live partials without throttling.

#### Option C: Live Qwen3 ASR Session

Build a Qwen3-only live backend around `StreamingInferenceSession`.

Pros:

- Closest match to voice-assistant partial behavior.
- It has configurable latency presets: realtime (~200 ms), agent (~480 ms), subtitle (~2400 ms).
- It emits provisional, confirmed, display update, stats, and ended events.

Cons:

- Qwen3-specific.
- Does not fit the current `ASREngine.process/finalize` shape cleanly.
- Needs a new `ASRServicing` implementation or a new lower-level streaming protocol.
- Must be integrated with cancellation, hotkey release, VAD, and UI partial stabilization.

Recommendation: best long-term ASR experiment, but only after MLX dependency migration and benchmark results.

#### Option D: Replace FluidAudio Entirely

Remove FluidAudio Parakeet and use MLX Audio ASR/VAD.

Pros:

- One MLX-family audio stack.
- More model options.
- Less FluidAudio-specific model path handling.

Cons:

- Highest regression risk.
- Loses current Neural Engine separation.
- Forces all speech, language, embedding, and TTS work into the same MLX/Metal scheduling domain.
- Would require replacement for FluidAudio VAD, model download strategy, setup wizard assumptions, and tests.

Recommendation: do not do this now.

## Recommended Implementation Plan

### Phase 0: Stabilize Build and Baselines

Red/green TDD requirements:

- Capture current failing `./build.sh test`.
- Fix or clean the current SwiftPM module dependency failure.
- Get tests green before dependency migration.
- Add a report note if the failure is environmental and not source-related.

Acceptance:

- `./build.sh test` reaches Ora source compilation.
- MLX dependency state is pinned and reproducible.

### Phase 1: MLX 3.x Migration

Red tests first:

- Add a test around local model loader selection if extracting a loader wrapper.
- Add/update embedding service tests to prove batch output count, vector fitting, and model-container abstraction.
- Add a compile-focused test target if needed for `MLXHuggingFace` loader integration.

Implementation:

- Pin `mlx-swift` and `mlx-swift-lm` to known versions.
- Add `MLXHuggingFace`.
- Update `LLMService.prepare()` loader calls.
- Update `EmbeddingService` to `EmbedderModelContainer` and `EmbedderModelFactory`.
- Verify `LLMService.warmup()`, `generate(...)`, `generateOneShot(...)`, and VLM image prep still compile.

Verification:

- `./build.sh test`
- Focused: `LLMServiceTests`, `EmbeddingServiceTests`, VLM-related tests if present.
- Manual smoke: load selected local text model, generate one response, clear cache, generate one-shot summary.

### Phase 2: ASR Benchmark Harness

Red tests first:

- Test model catalog metadata parsing.
- Test audio fixture runner output schema.
- Test benchmark result aggregation.

Implementation:

- Add `agent-tools/asr-bench` or a SwiftPM scratch runner under `agent-tools`.
- Use fixed audio fixtures with transcripts.
- Test at least:
  - current FluidAudio Parakeet
  - Qwen3-ASR 0.6B 4bit
  - GLM-ASR Nano 4bit
  - MLX Parakeet 0.6B v3
  - Voxtral 4B Realtime 4bit only on sufficiently large machines

Metrics:

- cold load time
- warm transcription latency
- first partial/token latency
- total time
- peak memory
- real-time factor
- rough WER/manual diff
- tool-critical noun/name accuracy
- punctuation/capitalization stability

### Phase 3: Hidden MLX Batch ASR Backend

Red tests first:

- `MLXAudioASREngine` maps `STTOutput.text` to `ASRFinalSegment`.
- Empty audio returns nil or controlled error.
- Unsupported model ID fails clearly.
- GPU work is wrapped by `MLXMetalGate`.
- Partial calls are throttled and do not run every frame.

Implementation:

- Add model enum and model selector.
- Add sample conversion from `AVAudioPCMBuffer` or `[Float]` to `MLXArray`.
- Add configurable partial cadence, initially disabled or >= 1.0s.
- Keep FluidAudio as default.

Verification:

- Unit tests with fake STT model.
- Bench fixtures.
- Manual hotkey session with hidden setting enabled.

### Phase 4: Live Qwen3 ASR Backend

Red tests first:

- Feed frames into a fake streaming session and verify `partial` and `final` event mapping.
- Verify cancellation stops session and releases gate.
- Verify hotkey release ends finalization exactly once.
- Verify VAD callbacks still drive `SilenceDetector`.

Implementation:

- Add a separate `StreamingASREngine` or `ASRServicing` implementation rather than forcing it through `ASREngine.process/finalize`.
- Use `StreamingInferenceSession` only for Qwen3 initially.
- Add backpressure and gate scheduling so ASR cannot starve LLM/TTS.

Acceptance:

- Partial updates are stable under normal dictation.
- End-of-speech finalization stays within target.
- LLM TTFT and TTS first-audio latency do not materially regress.

## Final Recommendation

The migration is worthwhile, but it should be staged.

The MLX 3.x dependency migration is a prerequisite for any serious `mlx-audio-swift` adoption. It is moderate risk and tractable because Ora's LLM generation loop is mostly already modern; the main work is explicit loaders and embeddings.

The ASR migration is higher risk. Use MLX Audio ASR for benchmarking first, then ship it only as an optional backend if it beats FluidAudio on quality without harming end-to-end assistant latency. Keep FluidAudio Parakeet as the default until the MLX backend proves itself across hotkey, conversation mode, VAD, finalization, memory pressure, and LLM/TTS contention tests.
