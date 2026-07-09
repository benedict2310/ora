# Vision Integration Epic

Integrate local multimodal inference into Ora so users can attach screenshots or images to a turn and ask about them with the same privacy-first on-device workflow.

## Overview

This epic adds the minimum architecture Ora needs for vision support without breaking the current voice-first assistant:

- multimodal message types instead of string-only prompts
- local VLM loading through `MLXVLM`
- image attachment intake from screenshot, clipboard, and file import
- multimodal orchestration that preserves tool-calling and TTS
- privacy-safe attachment staging and session history behavior

## Why This Is a Separate Epic

This work does not fit cleanly inside the existing LLM epic. Ora is currently text-only at the protocol boundary:

- `LLMServicing` accepts `[LLMMessage]` where each message contains only a `String`
- `ConversationManager` stores only text messages
- `StructuredGenerator` validates text-only model output
- local loading uses `MLXLLM` only
- cloud providers build text-only request bodies

Supporting vision properly therefore requires a new end-to-end slice rather than a model-list addition.

## Research Summary

### Upstream Runtime Support

- Apple's `mlx-swift-lm` provides first-class VLM support through `MLXVLM`, separate from `MLXLLM`.
- `MLXLMCommon.UserInput` already supports text, images, and videos and can back a shared model-agnostic request shape.
- `ChatSession` in `MLXLMCommon` supports image-bearing turns and follow-up questions against the same image context.

Primary sources:

- <https://github.com/ml-explore/mlx-swift-lm>
- <https://github.com/ml-explore/mlx-swift-lm/blob/main/Libraries/MLXVLM/README.md>
- <https://github.com/ml-explore/mlx-swift-lm/blob/main/Libraries/MLXLMCommon/UserInput.swift>
- <https://github.com/ml-explore/mlx-swift-lm/blob/main/Libraries/MLXVLM/VLMModelFactory.swift>

### Current Ora Gaps

- `Ora/LLM/Types.swift` is string-only.
- `Ora/LLM/LLMService.swift` loads only `MLXLLM`.
- `Ora/Orchestration/AgentLoop.swift` and `Ora/LLM/StructuredGenerator.swift` assume text-only turns.
- `Ora/Overlay/*` has no attachment controls or image previews.
- `Ora/Persistence/Models/Session.swift` stores only text message content in the session blob.

### Recommended Initial Local Vision Model

Initial target:

- `mlx-community/Qwen3.5-4B-MLX-4bit`

Reasons:

- true multimodal Qwen 3.5 4B conversion
- MLX file layout includes `processor_config.json` / `preprocessor_config.json`
- uses `Qwen3VLProcessor`, which aligns with current upstream `MLXVLM` processor support
- size class is reasonable for an optional advanced local model

Fallback evaluation candidate if smoke tests show repo-specific issues:

- `nightmedia/Qwen3.5-4B-mxfp4-mlx`

Model references:

- <https://huggingface.co/mlx-community/Qwen3.5-4B-MLX-4bit>
- <https://huggingface.co/nightmedia/Qwen3.5-4B-mxfp4-mlx>
- <https://huggingface.co/Qwen/Qwen3.5-4B>

### Product Recommendation

- Keep `Qwen 3 4B` as Ora's default local text model.
- Add the multimodal `Qwen 3.5 4B Vision` path as an optional advanced local model.
- Support image attachment from:
  - screenshot capture
  - paste image from clipboard
  - choose image file
- Do not silently auto-switch providers or models when an image is attached.
- If the active provider cannot handle image input, Ora should show actionable guidance.

### Permission / UX Implications

- Screenshot capture should use modern ScreenCaptureKit screenshot APIs, not a live recording pipeline.
- Screenshot capture needs screen recording permission handling and user guidance.
- Pasteboard and file import should remain available even if screenshot permission is denied.

Apple references:

- <https://developer.apple.com/documentation/screencapturekit>
- <https://developer.apple.com/videos/play/wwdc2023/10136/>

## Prerequisites

- **LLM Integration:** L.01, L.02, L.03, L.04, L.06
- **Foundations:** F.03, F.06, F.07, F.08, F.09
- **Orchestration:** O.06
- **Maintenance/Bugs:** BUG.01, M.02

## Story Index

| Story | Title | Description | Dependencies |
|-------|-------|-------------|--------------|
| **V.01** | [Multimodal Message Model & Provider Capabilities](V.01-MULTIMODAL-MESSAGE-MODEL-AND-PROVIDER-CAPABILITIES.md) | Replace string-only request types with multimodal-capable message parts and capability checks | L.01, L.03, O.06, F.08 |
| **V.02** | [Local VLM Runtime & Qwen 3.5 4B Vision Model](V.02-LOCAL-VLM-RUNTIME-AND-QWEN35-4B-VISION-MODEL.md) | Add `MLXVLM`, local multimodal model support, download metadata, and memory gating | V.01, F.03, F.09 |
| **V.03** | [Image Attachments & Screenshot Capture UX](V.03-IMAGE-ATTACHMENTS-AND-SCREENSHOT-CAPTURE-UX.md) | Let users attach screenshots or images from the overlay with staging, previews, and permission guidance | V.01, F.06, F.07 |
| **V.04** | [Multimodal Agent Loop & Session Integration](V.04-MULTIMODAL-AGENT-LOOP-AND-SESSION-INTEGRATION.md) | Send image-bearing turns through the agent loop, preserve follow-up behavior, and persist metadata safely | V.01, V.02, V.03, O.06, F.08 |
| **V.05** | [Vision Model Size Variants and Qwen3 4B Retirement](V.05-VISION-MODEL-SIZE-VARIANTS-AND-QWEN3-RETIREMENT.md) | Add 9B and 27B vision model variants; retire text-only Qwen 3 4B with auto-migration UX | V.02 |

## Dependency Graph

```text
L.01/L.03/O.06/F.08
        │
        └──► V.01 (Multimodal Message Model & Provider Capabilities)
                 │
                 ├──► V.02 (Local VLM Runtime & Qwen 3.5 4B Vision Model)
                 │        │
                 │        └──► V.05 (Vision Model Size Variants & Qwen3 4B Retirement)
                 ├──► V.03 (Image Attachments & Screenshot Capture UX)
                 └──► V.04 (Multimodal Agent Loop & Session Integration)
                               ▲
                               └──────── depends on V.02 and V.03
```

## Architecture Alignment

The recommended architecture for Ora vision support is:

- keep `LLMProviderManager` as the provider entry point
- keep `LLMService` as the local provider actor, but allow it to load either `MLXLLM` or `MLXVLM` internally
- evolve `LLMMessage` into a multimodal-capable message model rather than creating a one-off local-only vision API
- keep TTS text-only; vision changes the input path, not the spoken output path
- keep raw image bytes out of SwiftData session blobs
- treat screenshots as optional, per-turn attachments with explicit user action

## Success Criteria

- [ ] Users can attach an image and ask Ora about it without leaving the app.
- [ ] Local multimodal inference works with an optional Qwen 3.5 4B vision model on supported Macs.
- [ ] Text-only flows remain unchanged when no image is attached.
- [ ] Ora gives clear guidance when the selected provider or model cannot handle vision input.
- [ ] Tool-calling and spoken responses continue to work after image-bearing turns.
