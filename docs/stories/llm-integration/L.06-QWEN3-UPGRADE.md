# L.06 - Qwen 3 Upgrade

**Epic:** LLM Integration
**Status:** Not Started
**Priority:** P0 (Critical Path)
**Estimated Effort:** 2-3 days
**Dependencies:** L.01, F.03, F.09
**Target:** macOS 26 (Tahoe)
**Design Reference:** None

---

## 1. Objective

Replace Qwen 2.5 with Qwen 3 as the primary LLM, improving reasoning quality while maintaining fast local inference. Drop support for Qwen 2.5 models to simplify maintenance.

## 2. User Story

As a power user, I want Ora to use the latest Qwen 3 model so that I get better reasoning and more accurate tool use.

## 3. Scope

### In Scope

- Replace `qwen2.5-7b-instruct-4bit` and `qwen2.5-3b-instruct-4bit` with Qwen 3 equivalents
- Update `ModelIdentifier` enum with new Qwen 3 model identifiers
- Update HuggingFace download URLs and required file lists for Qwen 3
- Handle Qwen 3's chat template (may use `chat_template.jinja` file instead of embedded)
- Update system prompt if Qwen 3 has different formatting requirements
- Update model size estimates and download progress
- Remove Qwen 2.5 model identifiers from the codebase
- Migrate existing users: detect Qwen 2.5 on disk and prompt to re-download Qwen 3

### Out of Scope

- Multi-model support (planner + executor) - defer to L.05
- Model sanity checking infrastructure - defer to L.05
- New tools or orchestration changes
- Performance benchmarking infrastructure

## 4. Architecture Alignment

- Reuse existing `ModelManager`, `ModelTypes`, `HuggingFaceStrategy` patterns
- `LLMService` continues to use MLX Swift with `applyChatTemplate()`
- May need to handle `.jinja` template file loading if not embedded in tokenizer_config.json
- Keep L.01 patterns: actor isolation, streaming tokens, warmup sequence

### Qwen 3 Model Options

| Model | Size | Memory | Speed | Notes |
|-------|------|--------|-------|-------|
| Qwen3-4B-Instruct-4bit | ~2.5GB | ~6GB RAM | Fast | Good for most tasks |
| Qwen3-8B-Instruct-4bit | ~5GB | ~10GB RAM | Medium | Better reasoning |

**Recommendation:** Use Qwen3-4B as primary (faster, fits 8GB Macs), optionally Qwen3-8B for users with 16GB+.

## 5. Implementation Plan (Draft)

### 5.1 Files to Create

- `Ora/LLM/Qwen3TemplateLoader.swift` - Handle loading chat_template.jinja if needed (optional, may not be needed if embedded)

### 5.2 Files to Modify

- `Ora/Models/ModelTypes.swift` - Replace Qwen 2.5 identifiers with Qwen 3
- `Ora/Models/Strategies/HuggingFaceStrategy.swift` - Update file lists and repo URLs
- `Ora/LLM/LLMService.swift` - Handle Qwen 3 template differences if any
- `Ora/Setup/SetupCoordinator.swift` - Update default model selection
- `Ora/Preferences/Tabs/ModelsPreferencesView.swift` - Update display names and descriptions
- `Ora/Resources/system-prompt.txt` - Review and update if Qwen 3 needs different formatting

### 5.3 Tests to Add

- `OraTests/Models/ModelTypesTests.swift` - Verify Qwen 3 paths and required files
- `OraTests/LLM/LLMServiceTests.swift` - Test chat template application with Qwen 3

### 5.4 Dependencies/Config

- None - uses existing MLX Swift dependency

## 6. Acceptance Criteria

- [ ] AC-1: Qwen 2.5 model identifiers removed from `ModelIdentifier` enum
- [ ] AC-2: Qwen 3 model(s) added with correct HuggingFace repo URLs
- [ ] AC-3: Setup wizard downloads Qwen 3 instead of Qwen 2.5
- [ ] AC-4: Chat template correctly applied (no gibberish output)
- [ ] AC-5: Existing users with Qwen 2.5 see prompt to download new model
- [ ] AC-6: Model preferences show Qwen 3 with correct size/description
- [ ] AC-7: Basic conversation works end-to-end with Qwen 3

## 7. Verification Plan

### Automated Tests

- [ ] ModelTypes tests verify Qwen 3 file lists and sizes
- [ ] No references to Qwen 2.5 remain in codebase

### Manual Tests

- [ ] Fresh install: Setup downloads Qwen 3 successfully
- [ ] Say "Hello, how are you?" → coherent response (not gibberish)
- [ ] Say "What's 2 + 2?" → correct answer
- [ ] Existing user with Qwen 2.5: sees migration prompt
- [ ] Model download shows correct progress and size

## 8. Performance / Reliability Considerations

| Metric | Target |
|--------|--------|
| Model download | Show accurate progress with file sizes |
| TTFT (time to first token) | <500ms after warmup |
| Memory usage | <6GB for 4B model, <10GB for 8B |

## 9. Risks & Mitigations

| Risk | Mitigation |
|------|------------|
| Qwen 3 chat template format differs | Check for .jinja file, fall back to embedded template |
| MLX-community repo not yet available | Check mlx-community, fallback to convert ourselves |
| Model quality regression | Test common queries before merging |

## 10. Open Questions

- [ ] Which Qwen 3 variant to use as default? (4B recommended for broad device support)
- [ ] Is there a Qwen 3 MLX model already on mlx-community?
- [ ] Does Qwen 3 require different stop tokens?

---

## Implementation Summary

(TBD after implementation.)

## Code Review Findings

(TBD by review agent.)

## Completion Status

(TBD after merge.)
