# L.07 - Qwen 3.5 27B Text Local Model

**Epic:** LLM Integration  
**Status:** Draft  
**Priority:** P1 (High)  
**Estimated Effort:** 3-4 days  
**Dependencies:** L.06, BUG.01, BUG.04, M.02  
**Target:** macOS 26 (Tahoe)  
**Architectural Review Verdict:** Implementation ready

Add support for `nightmedia/Qwen3.5-27B-Text-mxfp4-mlx` as an optional advanced local LLM in Ora. Keep the existing `MLXLLM` runtime path, keep Qwen 3 4B as the first-run default, and extend Ora's model metadata, download verification, RAM gating, and local-model UI so a sharded 27B text-only MLX model can be downloaded, selected, and loaded predictably.

## Product Decision Summary

- `Qwen 3 4B` remains Ora's standard local LLM and the default model for first-run setup.
- `Qwen 3.5 27B Text` is an optional advanced local model for capable Macs, not part of the mandatory onboarding download.
- Users discover and download `Qwen 3.5 27B Text` in Preferences > Models.
- If setup is reopened later because required models are missing, and the persisted primary LLM is `Qwen 3.5 27B Text`, the repair flow should honor that choice and show the correct larger size.
- `ModelManager.primaryLLM` remains the single source of truth for the selected local model across setup, preferences, provider display, and runtime loading.

## 1. Architecture Context and Reuse Guidance

- Reuse the existing local LLM runtime in `Ora/LLM/LLMService.swift`. Do not add `MLXVLM`, a second local runtime actor, or a separate "Qwen 3.5 service". Upstream `mlx-swift-lm` already supports `qwen3_5` in `MLXLLM`.
- Use the chosen text-only repo, not the official multimodal `mlx-community/Qwen3.5-27B-4bit` repo. The selected repo is:
  - `nightmedia/Qwen3.5-27B-Text-mxfp4-mlx`
  - `pipeline_tag: text-generation`
  - `vision_config: null`
  - weight shards total roughly `14.29 GB`
- Keep `ModelManager` metadata as the source of truth for the selected local model. Do not introduce a second persisted selector in `AppSettings`.
- Reuse the current model download pipeline:
  - `ModelIdentifier` owns model metadata
  - `HuggingFaceStrategy` downloads files
  - `DefaultModelDownloader.verify/exists` validates the on-disk model
  - `ModelManager` owns `primaryLLM`
- Keep first-run setup on Qwen 3 4B. Qwen 3.5 27B Text is an opt-in advanced model exposed in Preferences, not a required setup model.
- Reuse existing test suites instead of adding a new test harness:
  - `OraTests/HuggingFaceDownloaderTests.swift`
  - `OraTests/ModelManagerTests.swift`
  - `OraTests/SetupCoordinatorTests.swift`
  - `OraTests/Preferences/ProviderPreferencesViewModelTests.swift`

## 2. Proposed Changes and Architecture Improvements

### 2.1 Add a New Optional Local LLM

Add a new `ModelIdentifier` case for Qwen 3.5 27B Text. Suggested metadata:

- Raw identifier: `qwen3.5-27b-text-mxfp4`
- Display name: `Qwen 3.5 27B Text`
- Repo: `nightmedia/Qwen3.5-27B-Text-mxfp4-mlx`
- Storage path: `llm/qwen3.5-27b-text-mxfp4`
- Estimated size: `14_300_000_000`
- Required RAM gate: `32 GB+`

This model must remain:

- `category == .llm`
- active (not legacy)
- non-required for setup
- non-recommended as the default local model

### 2.2 Make the Existing Download/Verification Path Shard-Aware

Ora currently assumes one `model.safetensors` file in several places. Support the selected repo without introducing a new downloader stack.

For this story, add a small manifest-style extension to the existing metadata model so a local model can declare:

- exact `downloadFiles`
- exact `requiredFiles`
- estimated total bytes
- minimum supported RAM

For `nightmedia/Qwen3.5-27B-Text-mxfp4-mlx`, the manifest should download and verify these files:

- `config.json`
- `generation_config.json`
- `chat_template.jinja`
- `model.safetensors.index.json`
- `model-00001-of-00003.safetensors`
- `model-00002-of-00003.safetensors`
- `model-00003-of-00003.safetensors`
- `tokenizer.json`
- `tokenizer_config.json`

Architecture improvement:

- Move the file list out of `HuggingFaceStrategy.knownFiles(for:)` and into model metadata so adding future sharded models does not require another downloader switch statement.
- Keep `fetchFileSizesFromAPI()` and API-based verification. Do not hard-code shard byte sizes unless a fallback is absolutely necessary for an offline verification path.

### 2.3 Add Explicit RAM Gating for Large Local Models

`LLMService.checkMemoryAvailable(for:)` currently only knows about Qwen 3 4B and legacy Qwen 2.5. Extend it so Qwen 3.5 27B Text is blocked on machines below the supported threshold.

Requirements:

- below `32 GB`: do not allow the model to be set as primary or loaded
- `prepare()` must fail fast with actionable logging
- UI must communicate the constraint before download/load

Do not silently fall back from 27B to 4B in the runtime. Selection should be explicit and predictable.

### 2.4 Fix Local Provider UI to Respect the Actual Selected Local Model

The provider UI still hard-codes Qwen 3 4B for local display. Update the local-provider menu state so it reflects `ModelManager.shared.state.primaryLLM`.

This affects:

- `LLMProviderManager.getSelectedModelIdentifier(for: .local)`
- `LLMProviderManager.getSelectedModelDisplayName(for: .local)`
- `ProviderPreferencesViewModel.modelSelectionMenuState`

The story should explicitly prevent an implementation that adds a second local-model preference source.

### 2.5 Keep Setup Predictable

Setup must remain device-friendly:

- first-run onboarding still defaults to Qwen 3 4B
- setup total-size messaging for first run remains based on the default 4B path
- if the user previously selected Qwen 3.5 27B Text and setup is reopened because models are missing, the repair flow should honor the persisted `primaryLLM` and show the correct larger size

That requires making size labels in setup views data-driven rather than hard-coded for only `qwen3_4B`, `qwen7B`, and `qwen3B`.

### 2.6 Discovery and Download UX

The intended user flow for this story is:

- first run: Ora downloads Parakeet, Qwen 3 4B, and Kokoro
- advanced upgrade path: user opens Preferences > Models, downloads Qwen 3.5 27B Text, and sets it as primary if hardware supports it
- repair path: if the selected local model is missing on disk, setup uses the persisted primary model and presents the corresponding download size

Explicit non-goals for this story:

- do not add Qwen 3.5 27B Text to the mandatory first-run setup path
- do not add a separate "advanced setup" branch in onboarding
- do not create a second local-model selector outside existing model/preferences flows

## 3. File Touch List

- `Ora/Models/ModelTypes.swift`
  - Add the new model identifier and move the per-model download manifest into metadata instead of `HuggingFaceStrategy`.
- `Ora/Models/ModelDownloading.swift`
  - Update `verify()` and `exists()` so sharded models validate against `requiredFiles` that include multiple safetensor shards and `.index.json`.
- `Ora/Models/Strategies/HuggingFaceStrategy.swift`
  - Replace the hard-coded LLM file switch with metadata-driven `downloadFiles`.
- `Ora/Models/ModelManager.swift`
  - Keep `recommendedLLM()` on Qwen 3 4B; ensure the new model can still be selected as `primaryLLM`.
- `Ora/LLM/LLMService.swift`
  - Add Qwen 3.5 27B memory gating; keep the existing `MLXLLM` loading path.
- `Ora/Cloud/LLMProviderManager.swift`
  - Return the actual selected local model instead of always returning Qwen 3 4B.
- `Ora/Preferences/Tabs/ProviderPreferencesViewModel.swift`
  - Make the local-provider section dynamic so the active local model name is accurate.
- `Ora/Preferences/Tabs/ModelsPreferencesView.swift`
  - Surface the new model in Preferences > Models, show its size and RAM requirement, and prevent unsafe selection on unsupported hardware.
- `Ora/Setup/SetupCoordinator.swift`
  - Keep first-run default on Qwen 3 4B while honoring a previously selected 27B model for repair flows.
- `Ora/Setup/SetupState.swift`
  - Remove hard-coded display assumptions that only fit the current 4B path.
- `Ora/Setup/Steps/ModelExplanationStepView.swift`
  - Make LLM size text data-driven.
- `Ora/Setup/Steps/DownloadStepView.swift`
  - Make LLM size text data-driven.
- `OraTests/HuggingFaceDownloaderTests.swift`
  - Add coverage for sharded manifests and verification behavior.
- `OraTests/ModelManagerTests.swift`
  - Add coverage for the new model metadata and active model behavior.
- `OraTests/SetupCoordinatorTests.swift`
  - Verify first-run setup remains 4B by default and repair flows can show the selected advanced model.
- `OraTests/Preferences/ProviderPreferencesViewModelTests.swift`
  - Verify local provider display uses the actual selected local model.
- `docs/stories/llm-integration/README.md`
  - Index the new story and refresh the epic summary.

## 4. Implementation Steps

1. Extend local model metadata in `ModelTypes.swift`.
   - Add `qwen3_5_27BText`.
   - Introduce a small manifest representation owned by `ModelIdentifier` for `downloadFiles`, `requiredFiles`, size, and RAM guidance.
   - Keep `qwen3_4B` as the default/recommended local model.

2. Refactor the downloader to use model metadata instead of a hard-coded file switch.
   - `HuggingFaceStrategy` must iterate `model.downloadFiles`.
   - Preserve current progress reporting and API file-size lookups.
   - Do not add repo-tree discovery for this story; the chosen repo has a stable exact file list.

3. Update on-disk validation for sharded models.
   - `DefaultModelDownloader.verify()` must validate all required shards and `model.safetensors.index.json`.
   - `DefaultModelDownloader.exists()` must reject missing shards and obviously truncated shard files.
   - Reuse the current minimum-size sanity checks for `.safetensors`, `.json`, and `.jinja`.

4. Add 27B-specific RAM gating in `LLMService`.
   - Add a `32 GB+` threshold for Qwen 3.5 27B Text.
   - Log a clear error when the threshold is not met.
   - Keep `LLMServiceError.insufficientMemory` unless there is already a pattern for more specific errors.

5. Fix local model selection/display paths outside the model preferences tab.
   - `LLMProviderManager` must return the actual current local model identifier/display name.
   - `ProviderPreferencesViewModel` must build its local menu state from the selected primary local model, not a hard-coded Qwen 3 4B option.

6. Update the preferences UX for the advanced model.
   - Add Qwen 3.5 27B Text to the language-model list.
   - Show its disk size and a succinct RAM warning.
   - Prevent setting it as primary on unsupported machines.
   - Do not hide the model entirely; the user should understand why it is unavailable.
   - This is the primary discovery and download surface for the new model.

7. Make setup labels data-driven while preserving onboarding behavior.
   - First run: still default to Qwen 3 4B.
   - Repair/re-download: use the persisted `primaryLLM`.
   - Update `ModelExplanationStepView`, `DownloadStepView`, and any setup-size helpers that assume only current model cases.

8. Add and update tests before handoff.
   - Cover manifest-driven downloads, shard validation, RAM gating, setup defaults, and provider UI display.

## 5. Tests and Validation

### Automated

- `./build.sh test`
- Add unit coverage for:
  - new `ModelIdentifier` metadata
  - metadata-driven sharded file downloads
  - `exists()` / `verify()` failure when one shard is missing
  - `LLMService` RAM gating for the new model
  - dynamic local-model display in provider preferences
  - setup default staying on Qwen 3 4B

### Manual

- On a machine with less than `32 GB` RAM:
  - open Preferences > Models
  - confirm Qwen 3.5 27B Text is visible with a RAM warning
  - confirm it cannot be set as primary

- On a machine with `32 GB+` RAM:
  - download Qwen 3.5 27B Text
  - set it as primary
  - run `./build.sh run`
  - confirm a basic prompt returns coherent text
  - confirm tool-calling still works for a simple tool path

- Setup regression:
  - clear onboarding state
  - confirm first-run setup still presents the 4B path
  - if the persisted primary model is 27B and the model is missing, confirm setup shows the 27B size in repair flow

## 6. Acceptance Criteria

- AC-1: Ora exposes `Qwen 3.5 27B Text` as an optional local LLM backed by `nightmedia/Qwen3.5-27B-Text-mxfp4-mlx`.
- AC-2: The selected repo is treated as a text-only MLX model; this story does not add `MLXVLM` or any second local runtime path.
- AC-3: The local model manifest includes all required shard files, `model.safetensors.index.json`, and `chat_template.jinja`, and downloader/verification code uses that manifest.
- AC-4: `exists()` and `verify()` fail when any required shard is missing or undersized.
- AC-5: `LLMService.prepare()` rejects the 27B model on machines below `32 GB` RAM.
- AC-6: Preferences show the new model with correct size guidance and prevent unsafe selection on unsupported hardware.
- AC-6a: Preferences > Models is the primary place where users discover and download Qwen 3.5 27B Text.
- AC-7: Provider UI and local-model labels reflect the actual selected local model instead of always showing Qwen 3 4B.
- AC-8: First-run setup still defaults to Qwen 3 4B; this story does not make 27B part of the required onboarding download.
- AC-9: On a `32 GB+` machine with complete weights, the 27B model loads through the existing `MLXLLM` path and returns normal text responses.

## 7. Risks and Open Questions

- Third-party repo risk:
  - `nightmedia/Qwen3.5-27B-Text-mxfp4-mlx` is a third-party MLX conversion, not an official `mlx-community` repo.
  - Mitigation: keep support optional, isolate it to metadata-driven manifests, and re-verify the repo before release if implementation happens later than this story draft date.

- Large manual test footprint:
  - CI should not download a 14 GB model.
  - Mitigation: keep automated tests at the metadata/downloader/UI layer and require one manual smoke test on a capable machine.

- Setup wording drift:
  - current setup helpers hard-code the 4B/legacy model sizes.
  - Mitigation: make size labels data-driven in this story instead of adding one more special case.

- Runtime behavior on borderline hardware:
  - `32 GB` is the support floor for this story, not a performance guarantee.
  - Mitigation: document the threshold clearly and do not promise acceptable latency on low-end-capable machines.

- Architectural review result:
  - The story is implementation ready because the chosen repo matches Ora's existing `MLXLLM` text path and the remaining work is confined to model metadata, sharded download verification, RAM gating, and UI consistency.
