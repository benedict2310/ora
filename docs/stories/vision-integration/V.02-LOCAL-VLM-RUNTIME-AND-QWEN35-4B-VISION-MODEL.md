# V.02 - Local VLM Runtime & Qwen 3.5 4B Vision Model

**Epic:** Vision Integration
**Status:** Not Started
**Priority:** P1 (High)
**Estimated Effort:** 3-4 days
**Dependencies:** V.01, F.03, F.09
**Target:** macOS 26 (Tahoe)
**Design Reference:** [ARCHITECTURE.md - Section 4](../ARCHITECTURE.md#4-model-runtime-strategy)

---

## 1. Objective

Add a local multimodal model path to Ora so the selected local model can accept image-bearing turns through `MLXVLM` while preserving the current local text-model path and model-management architecture.

## 2. User Story

As a user with a capable Mac, I want Ora to load an optional local Qwen 3.5 4B vision model so that my screenshot and image questions can stay fully on-device.

## 3. Scope

### In Scope

- Add `MLXVLM` as an app dependency.
- Add an optional local multimodal model entry for `mlx-community/Qwen3.5-4B-MLX-4bit`.
- Extend model metadata and download verification to support multimodal-specific files such as `processor_config.json` and `preprocessor_config.json`.
- Extend the local runtime so `LLMService` can load either `MLXLLM` or `MLXVLM` depending on the selected local model capability.
- Keep Qwen 3 4B as the default local text model.
- Surface the multimodal model in Preferences > Models as an optional advanced local model.
- Add explicit memory gating and user guidance for unsupported hardware.

### Out of Scope

- Screenshot capture and attachment UI
- Agent loop orchestration for image-bearing turns
- Cloud vision support
- Replacing the current default local model

## 4. Architecture Alignment

- Reuse `LLMService` as the local provider actor. Do not introduce a second top-level local provider actor just for VLMs.
- Keep `ModelManager` as the single source of truth for selected local models.
- Keep model download logic in the existing model-management pipeline:
  - `ModelIdentifier`
  - `HuggingFaceStrategy`
  - `DefaultModelDownloader`
  - `ModelManager`
- Preserve MLX GPU safety rules already used by LLM/TTS:
  - set cache limits on load
  - clear cache after generation
- Relevant upstream references:
  - `MLXVLM` and `VLMModelFactory`
  - `MLXLMCommon.UserInput`

## 5. Implementation Plan (Draft)

### 5.1 Files to Create

- None required if `LLMService` remains the local provider actor.

### 5.2 Files to Modify

- `project.yml` - Add the `MLXVLM` package product to the Ora target.
- `Ora/Models/ModelTypes.swift` - Add the Qwen 3.5 4B vision model identifier and metadata, including multimodal file requirements and minimum RAM.
- `Ora/Models/Strategies/HuggingFaceStrategy.swift` - Download multimodal model assets including processor/preprocessor files.
- `Ora/Models/ModelDownloading.swift` - Verify multimodal model file sets and reject incomplete downloads.
- `Ora/Models/ModelManager.swift` - Keep the multimodal model optional and non-default while allowing it to be selected as the primary local model.
- `Ora/LLM/LLMService.swift` - Branch between `LLMModelFactory` and `VLMModelFactory` based on the selected local model capability.
- `Ora/Preferences/Tabs/ModelsPreferencesView.swift` - Surface the multimodal model with disk size and RAM guidance.
- `Ora/Setup/SetupCoordinator.swift` - Keep first-run setup on Qwen 3 4B; only honor the multimodal model in repair flows if it is already the persisted primary local model.
- `Ora/Setup/Steps/ModelExplanationStepView.swift` - Ensure model size text remains correct for repair flows.
- `Ora/Setup/Steps/DownloadStepView.swift` - Same as above.

### 5.3 Tests to Add

- `OraTests/HuggingFaceDownloaderTests.swift` - Multimodal required-file verification.
- `OraTests/ModelManagerTests.swift` - Optional advanced local model behavior and selection.
- `OraTests/LLM/LLMServiceTests.swift` - Local runtime path selection for text vs VLM models and memory gating.
- `OraTests/SetupCoordinatorTests.swift` - First-run default remains Qwen 3 4B; repair flow can honor persisted multimodal selection.

### 5.4 Dependencies/Config

- Add `MLXVLM` to the app target in `project.yml`.
- Keep the model experimental until one-device smoke tests confirm stable load/generation behavior.

## 6. Acceptance Criteria

- [ ] AC-1: Ora exposes `Qwen 3.5 4B Vision` as an optional advanced local model backed by `mlx-community/Qwen3.5-4B-MLX-4bit`.
- [ ] AC-2: The local runtime loads text-only local models through `MLXLLM` and the vision model through `MLXVLM` without changing the provider surface.
- [ ] AC-3: Downloader and verification logic handle multimodal-required files including `processor_config.json`, `preprocessor_config.json`, and `video_preprocessor_config.json`.
- [ ] AC-4: Qwen 3 4B remains the default local model for first-run setup.
- [ ] AC-5: The multimodal model is visible in Preferences > Models with clear RAM guidance and cannot be selected on unsupported hardware.
- [ ] AC-6: On a supported machine, the multimodal model loads locally and can answer a basic image question in a manual smoke test.

## 7. Verification Plan

### Automated Tests

- [ ] `./build.sh test`
- [ ] Add downloader tests for multimodal file manifests and verification failures.
- [ ] Add runtime tests for text-vs-VLM loader selection and insufficient-memory behavior.
- [ ] Add setup regression tests that preserve the current default onboarding path.

### Manual Tests

- [ ] On a machine with less than `16 GB` RAM, confirm the model is visible but not selectable as primary.
- [ ] On a machine with `16 GB+` RAM, download the multimodal model from Preferences > Models and confirm it loads without crashing.
- [ ] Run a local smoke test with a fixture image and confirm the model answers a simple question about the image.
- [ ] Reopen setup with the multimodal model selected and missing on disk; confirm repair UI shows the correct model and size.

## 8. Performance / Reliability Considerations

- Support floor for the multimodal 4B model is `16 GB` RAM. This is a support threshold, not a latency guarantee.
- GPU cache controls must remain in place for VLM generation just as they do for text-only LLM generation.
- Multimodal downloads include more config files than current text-only models; verification must be stricter, not looser.

## 9. Risks & Mitigations

- Repo-specific conversion instability
  - Mitigation: keep the model optional and validate with a real-device smoke test before release.

- Runtime branching adds complexity to `LLMService`
  - Mitigation: keep one local provider actor and isolate branching to the model-load and input-preparation path.

- Underestimating memory pressure
  - Mitigation: use a conservative 16 GB support floor and explicit user guidance rather than auto-fallback.

## 10. Open Questions

- If `mlx-community/Qwen3.5-4B-MLX-4bit` shows runtime-specific issues during smoke testing, should the implementation switch to `nightmedia/Qwen3.5-4B-mxfp4-mlx` before release? The architecture in this story should allow that repo substitution without redesign.

---

## Implementation Summary

(TBD after implementation.)

## Code Review Findings

(TBD by review agent.)

## Completion Status

(TBD after merge.)
