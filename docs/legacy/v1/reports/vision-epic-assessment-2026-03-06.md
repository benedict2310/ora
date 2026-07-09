# Vision Epic Assessment
**Date:** 2026-03-06
**Branch reviewed:** `fix/model-download-progress-race` (PR #177, open)
**Scope:** Stories V.01 – V.04 + current blocker

---

## 1. What Is Implemented End-to-End vs. Stubbed/Broken

| Story | Status | End-to-End Reality |
|-------|--------|-------------------|
| V.01 – Multimodal message model | Complete / merged | **Solid.** `LLMMessage` supports `contentParts`, image attachment references, capability reporting, and unsupported-provider rejection. Cloud providers (OpenAI, Anthropic) reject image turns with actionable guidance. Text-only paths are unchanged. All 1533 tests passed at merge. |
| V.02 – Local VLM runtime | "Complete" / merged | **Broken at AC-6.** Infrastructure is correct (`LocalRuntimeBackend`, VLM branching in `LLMService`, RAM gating, download manifest) but the chosen HF repo (`mlx-community/Qwen3.5-4B-MLX-4bit`) is a **text-only Mamba-Transformer hybrid** model with `model_type: "qwen3_5"`. This type is not registered in `VLMTypeRegistry`, so `VLMModelFactory` cannot load it. The `isRuntimeSupported = false` guard added in PR #177 surfaces a clear error but is a band-aid, not a fix. |
| V.03 – Image attachment & screenshot UX | Complete / merged | **Solid.** `AttachmentStore`, `AttachmentTrayView`, `ScreenshotCaptureService`, and lifecycle management in `SimplePipelineController` are all in place. Attachments are staged, previewed, and cleared correctly. `AgentLoop.process(userText:imageAttachments:)` accepts the staged references. |
| V.04 – Multimodal agent loop | "Not Started" | **Largely implemented as a side-effect of V.03.** `AgentLoop.process()` already accepts `imageAttachments: [LLMImageAttachmentReference]` and passes them into `ConversationManager.addMessage()` as multimodal content parts. `SimplePipelineController+Agent.swift` already calls `agentLoop.process(userText:imageAttachments: turnAttachments.map(\.llmReference))`. What remains is automated tests and a working model to test against. |

---

## 2. Can `mlx-community/Qwen3.5-4B-MLX-4bit` Ever Work with the Current mlx-swift-lm?

**No.** This model is not a VLM.

**Root cause:** Qwen 3.5 (a.k.a. `Qwen3_5`) is a text-only hybrid Mamba-Transformer LLM with `model_type: "qwen3_5"`. It is architecturally unrelated to the Qwen-VL family of vision models. It has:
- Mixed `linear_attention` / `full_attention` layers (selective state-space)
- No vision encoder or visual token embedding
- A fundamentally different weight structure from Qwen2-VL / Qwen2.5-VL / Qwen3-VL

The `mlx-swift-lm` VLM registry only supports:
- `"qwen2_vl"` → `Qwen2VL`
- `"qwen2_5_vl"` → `Qwen25VL`
- `"qwen3_vl"` → `Qwen3VL`

Adding `"qwen3_5"` to the VLM registry would require implementing a full Mamba-hybrid language model backbone, which is a multi-week research engineering effort with no guaranteed stability outcome, and would yield a text-only model that cannot process images regardless.

**Conclusion: The chosen repo was a naming mistake.** `Qwen3.5` is not `Qwen3-VL`.

---

## 3. Alternative Model Options

| Option | HF Repo | Model Type | Support in current mlx-swift-lm | Notes |
|--------|---------|-----------|----------------------------------|-------|
| **Qwen3-VL 4B (4-bit) ← Recommended** | `lmstudio-community/Qwen3-VL-4B-Instruct-MLX-4bit` | `qwen3_vl` | ✅ Registered | Already listed in `VLMModelFactory.swift` known configs. 4-bit, so ~2–3 GB on disk. |
| Qwen3-VL 4B (8-bit) | `mlx-community/Qwen3-VL-4B-Instruct-8bit` | `qwen3_vl` | ✅ Registered | Higher quality, ~5 GB. Exceeds V.02's target size. |
| Qwen2.5-VL 3B (4-bit) | `mlx-community/Qwen2.5-VL-3B-Instruct-4bit` | `qwen2_5_vl` | ✅ Registered | Smaller, older series. Lower RAM floor. |
| nightmedia/Qwen3.5-4B-mxfp4-mlx | (not vision capable) | `qwen3_5` | ❌ Same issue | Text-only, same architecture problem. |

**Recommended: swap to `lmstudio-community/Qwen3-VL-4B-Instruct-MLX-4bit`** — it is the spiritual successor V.02 intended, has an identical parameter count, and is already compiled into mlx-swift-lm's known-model list.

---

## 4. Gaps Between V.02 Acceptance Criteria and Current Reality

| Criterion | Status | Gap |
|-----------|--------|-----|
| AC-1: Exposes Qwen 3.5 4B Vision as optional advanced local model | ✅ Partial | Model is exposed in UI but users cannot select a wrong model name; display name should change to "Qwen3 VL 4B" after swap. |
| AC-2: Local runtime loads text-only through MLXLLM, vision through MLXVLM | ✅ Code correct | Branch logic in `LLMService` is correct. Just needs the right model. |
| AC-3: Downloader handles multimodal-required files | ✅ Partial | Manifest was written for Qwen3.5-4B-MLX-4bit. Must be re-verified against Qwen3-VL actual file tree. |
| AC-4: Qwen 3 4B remains default for first-run setup | ✅ Verified | Unaffected. |
| AC-5: Vision model visible in Preferences with RAM guidance; blocked on unsupported hardware | ✅ Implemented | Works as designed. |
| AC-6: On a supported machine, model loads and answers basic image question | ❌ Fails | Blocked entirely by wrong HF repo. |

---

## 5. Recommended Path Forward

### Step 1: Merge PR #177 as-is (immediate)
PR #177 is correct and complete for its scope (download progress race + menu model list + thumbnail rendering). The `isRuntimeSupported = false` guard is a safe holding state. Merge it to stop drift from `main`.

### Step 2: Fix V.02 — swap the HF repo (new branch, ~1 day)

Create branch `fix/vlm-correct-model-repo`. Changes needed:

**`Ora/Models/ModelTypes.swift`:**
- `qwen35_4B_Vision.huggingFaceRepo` → `"lmstudio-community/Qwen3-VL-4B-Instruct-MLX-4bit"`
- `qwen35_4B_Vision.displayName` → `"Qwen3 VL 4B"` (or keep "Qwen 3.5 4B Vision" if branding matters)
- `qwen35_4B_Vision.storagePath` → `"llm/qwen3-vl-4b-instruct-4bit"`
- `qwen35_4B_Vision.isRuntimeSupported` → `true`
- `qwen35_4B_Vision.requiredFiles` → verify against actual Qwen3-VL repo (processor_config.json, preprocessor_config.json are confirmed; must check chat_template.jinja, video_preprocessor_config.json for this repo)

**`Ora/Models/Strategies/HuggingFaceStrategy.swift`:**
- Update the download manifest for the vision model to match Qwen3-VL file list (not Qwen3.5 file list)

**Verification before merging:**
```bash
# Confirm all required files return HTTP 200 from the new repo
for file in config.json tokenizer.json model.safetensors processor_config.json preprocessor_config.json chat_template.jinja; do
  code=$(curl -sL -o /dev/null -w "%{http_code}" \
    "https://huggingface.co/lmstudio-community/Qwen3-VL-4B-Instruct-MLX-4bit/resolve/main/$file")
  echo "$code  $file"
done
```

**Manual smoke test:**
1. Download model from Preferences > Models
2. Select it as primary LLM
3. Attach a test image
4. Ask "What is in this image?" and confirm a streamed response

### Step 3: Implement V.04 tests (new branch, ~0.5–1 day)

V.04's code is already in place. What is missing is the automated test coverage specified in the story. Key tests:
- `AgentLoopTests`: multimodal turn flow with tool-calling preserved
- `SimplePipelineControllerTests`: attachment lifecycle through submit/cancel/reset
- `StructuredGeneratorTests`: JSON validation retry with multimodal context
- `PersistenceTests`: attachment markers stored without raw image bytes

These tests can be written against mock providers and do not need the real Qwen3-VL model to load.

### Step 4: Update V.02 and V.04 story docs

After merging the model swap and tests, update:
- `V.02`: flip AC-6 to `[x]`, update Implementation Summary with new repo and branch
- `V.04`: add Implementation Summary, mark Complete

---

## 6. Summary

The vision epic infrastructure is **architecturally sound**. V.01 and V.03 are genuinely complete. V.04 is mostly implemented. The single blocker is that V.02 was shipped with the wrong HuggingFace repository — `mlx-community/Qwen3.5-4B-MLX-4bit` is a text-only model, not a VLM. Swapping to `lmstudio-community/Qwen3-VL-4B-Instruct-MLX-4bit` (which uses `model_type: "qwen3_vl"`, already registered in mlx-swift-lm) should unblock AC-6 with minimal code changes and no architectural rework.
