# V.01 - Multimodal Message Model & Provider Capabilities

**Epic:** Vision Integration
**Status:** Not Started
**Priority:** P1 (High)
**Estimated Effort:** 2-3 days
**Dependencies:** L.01, L.03, O.06, F.08
**Target:** macOS 26 (Tahoe)
**Design Reference:** [ARCHITECTURE.md - Section 7](../ARCHITECTURE.md#7-swift-6-implementation)

---

## 1. Objective

Replace Ora's string-only LLM request shape with a multimodal-capable message model so local and future cloud providers can accept text plus image references without introducing a local-only side channel.

## 2. User Story

As a user, I want Ora's model layer to understand image-bearing turns as a first-class input so that screenshot and vision features can be added without breaking the existing voice and tool pipeline.

## 3. Scope

### In Scope

- Evolve `LLMMessage` so a message can contain structured content parts instead of only a single text string.
- Add image attachment reference types that point to staged local files plus lightweight metadata.
- Add provider capability reporting so Ora can tell whether the active provider supports image input.
- Update the `LLMServicing` protocol and provider manager so multimodal-capable requests can flow through one interface.
- Preserve all current text-only behavior when messages contain only text parts.
- Add explicit unsupported-input errors/guidance for providers that receive image parts they cannot handle.

### Out of Scope

- Local VLM model loading (`MLXVLM`) and model download support
- Screenshot capture or attachment UI
- Agent loop follow-up behavior for image-bearing turns
- Persisting image bytes or rehydrating multimodal sessions across app restarts

## 4. Architecture Alignment

- Reuse the existing provider boundary in `LLMServicing`; do not add a second parallel "vision provider" abstraction.
- Preserve the ASR → LLM → Tools → TTS pipeline shape. This story changes request types, not the pipeline stages.
- Keep `LLMProviderManager` as the single provider entry point for local and cloud providers.
- Cloud providers must not silently drop image parts. They should reject unsupported multimodal requests with actionable guidance.
- Keep Swift Concurrency boundaries intact: provider actors remain actors; UI remains `@MainActor`.
- Relevant references:
  - `Ora/LLM/Types.swift`
  - `Ora/Cloud/LLMProviderManager.swift`
  - `Ora/LLM/StructuredGenerator.swift`
  - `Ora/LLM/ConversationManager.swift`
  - `Ora/Cloud/OpenAI/OpenAIProvider.swift`
  - `Ora/Cloud/Anthropic/AnthropicProvider.swift`

## 5. Implementation Plan (Draft)

### 5.1 Files to Create

- `Ora/LLM/ProviderCapabilities.swift` - Shared provider/model capability definitions for text vs multimodal input support.

### 5.2 Files to Modify

- `Ora/LLM/Types.swift` - Introduce multimodal content parts and image attachment references while preserving text-only convenience initializers.
- `Ora/Cloud/LLMProviderManager.swift` - Expose active provider capabilities and pass multimodal-capable messages through unchanged.
- `Ora/LLM/StructuredGenerator.swift` - Continue structured JSON generation using the new message model.
- `Ora/LLM/ConversationManager.swift` - Add generic message append support and keep current text helper methods working.
- `Ora/Cloud/CloudLLMBase.swift` - Add shared unsupported-input behavior for text-only cloud request builders.
- `Ora/Cloud/OpenAI/OpenAIProvider.swift` - Map text-only content parts and reject image parts with a clear unsupported-input error until cloud vision support is implemented.
- `Ora/Cloud/Anthropic/AnthropicProvider.swift` - Same text-only fallback/error behavior as OpenAI for now.
- `Ora/Cloud/OpenAI/OpenAIProviderFactory.swift` - Propagate capabilities if needed by existing factory flow.
- `Ora/Cloud/Anthropic/AnthropicProviderFactory.swift` - Propagate capabilities if needed by existing factory flow.

### 5.3 Tests to Add

- `OraTests/LLM/LLMTypesTests.swift` - Content-part encoding/decoding and text convenience behavior.
- `OraTests/Cloud/LLMProviderManagerTests.swift` - Capability reporting and active-provider pass-through.
- `OraTests/Preferences/ProviderPreferencesViewModelTests.swift` - Optional provider capability labels if surfaced in UI state.
- `OraTests/Cloud/OpenAI/OpenAIProviderTests.swift` - Reject image-bearing requests cleanly while preserving text-only requests.
- `OraTests/Cloud/Anthropic/AnthropicProviderTests.swift` - Same as OpenAI.

### 5.4 Dependencies/Config

- No package additions in this story.
- Keep API churn contained to Ora's internal provider interfaces; do not change setup/model download behavior here.

## 6. Acceptance Criteria

- [ ] AC-1: `LLMMessage` can represent both text-only content and image attachment references without breaking existing text-only callers.
- [ ] AC-2: Existing text-only turns continue to work through `StructuredGenerator`, `LLMProviderManager`, and local/cloud providers.
- [ ] AC-3: Ora can determine whether the active provider supports image input through a shared capability API.
- [ ] AC-4: Providers that do not support image input fail with explicit, user-actionable guidance rather than silently dropping attachments.
- [ ] AC-5: This story does not add screenshot UI, local VLM loading, or image persistence.

## 7. Verification Plan

### Automated Tests

- [ ] `./build.sh test`
- [ ] Add unit coverage for multimodal content-part serialization and text convenience initializers.
- [ ] Add provider tests that verify image-bearing requests fail with unsupported-input guidance for current cloud providers.
- [ ] Add provider manager tests that verify capability reporting is correct for the active provider.

### Manual Tests

- [ ] Run the app with existing text-only local and cloud providers and confirm standard chat still works.
- [ ] Inject a synthetic image-bearing request in a debug/test harness and confirm unsupported providers return actionable guidance.

## 8. Performance / Reliability Considerations

- Text-only latency should remain unchanged for existing flows.
- The new message model must avoid storing image bytes in memory-heavy blobs during normal conversation turns.
- Capability checks should happen before network calls when possible to avoid avoidable cloud failures.

## 9. Risks & Mitigations

- Broad protocol churn across local and cloud providers
  - Mitigation: keep convenience initializers and text flattening helpers so existing callers remain simple.

- Silent behavior regressions in text-only paths
  - Mitigation: add explicit regression tests for current text-only generation and structured output flows.

- Over-designing for video or document support too early
  - Mitigation: keep this story limited to text + image references; reserve video for future work.

## 10. Open Questions

- Should cloud providers expose their future image capability through the same API now, or should they remain text-only until cloud vision work is scheduled? The story assumes the shared capability API exists now, but current cloud providers remain text-only.

---

## Implementation Summary

(TBD after implementation.)

## Code Review Findings

(TBD by review agent.)

## Completion Status

(TBD after merge.)
