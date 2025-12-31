# L.05 - Additional LLM Models

**Epic:** LLM Integration
**Status:** Not Started
**Priority:** P1 (High)
**Estimated Effort:** 2-3 days
**Dependencies:** F.03, F.09, L.01, F.06
**Target:** macOS 26 (Tahoe)
**Design Reference:** None

---

## 1. Objective

Add two MLX-compatible LLMs (Qwen3 4B Instruct 4-bit and Orchestrator 8B 4-bit) so Ora can select a primary model and optionally track a planner model without changing tool schemas or agent loop logic.

## 2. User Story

As a power user, I want to pick between local LLM models so I can balance speed, memory use, and reasoning quality for my workflows.

## 3. Scope

### In Scope

- Add Qwen3 4B and Orchestrator 8B to `ModelIdentifier` with display names, storage paths, required files, and size estimates.
- Extend ModelManager to track a primary LLM and optional planner LLM selection, persisted across launches.
- Update HuggingFace download strategy to include the new model file lists, including sharded weights if applicable.
- Add per-model profile metadata for LLM runtime (chat template, context length, warmup prompt, defaults).
- Update the Models preferences tab to set primary and planner selections with badges.

### Out of Scope

- Agent loop routing heuristics or multi-model tool-call behavior.
- New tools, tool schema changes, or confirmation logic updates.
- Evaluation harness or benchmark tooling.

## 4. Architecture Alignment

- Reuse `ModelManager` and `ModelTypes` for model metadata and storage under `~/Library/Application Support/Ora/Models/llm/`.
- Keep runtime loading in the `LLMService` actor and follow L.01 patterns (MLX Swift, warmup, streaming).
- Preserve structured output validation via `JSONValidator` and prompt building via `SystemPromptBuilder` (L.02, L.04).
- Avoid multiple sources of truth for model selection; store primary and planner in one persistence layer.

## 5. Implementation Plan (Draft)

### 5.1 Files to Create

- `Ora/LLM/LLMModelProfile.swift` - Map ModelIdentifier to chat template, context size, warmup, and generation defaults.
- `Ora/Models/ModelPreferences.swift` (if needed) - Persist primary/planner selections without mixing with per-model metadata.

### 5.2 Files to Modify

- `Ora/Models/ModelTypes.swift` - Add new identifiers, repo names, storage paths, size estimates, required files.
- `Ora/Models/ModelManager.swift` - Add planner selection APIs, persistence, and default primary choice.
- `Ora/Models/ModelPaths.swift` - Add a preferences file path if new preferences are introduced.
- `Ora/Models/Strategies/HuggingFaceStrategy.swift` - Add known file lists (support sharded weights if required).
- `Ora/Preferences/Tabs/ModelsPreferencesView.swift` - Add planner selection UI and badges.
- `Ora/LLM/LLMService.swift` - Load and switch models by ModelIdentifier using LLMModelProfile.

### 5.3 Tests to Add

- `OraTests/ModelManagerTests.swift` - New model paths, required files, planner selection persistence.
- `OraTests/PreferencesTests.swift` - Primary and planner selection updates.

### 5.4 Dependencies/Config

- `project.yml` - Ensure new LLM files are included in the target if added.
- No new external dependencies.

## 6. Acceptance Criteria

- [ ] AC-1: Qwen3 4B and Orchestrator 8B are valid `ModelIdentifier` entries with correct storage paths and required files.
- [ ] AC-2: ModelManager persists both primary and optional planner LLM selections across launches.
- [ ] AC-3: HuggingFace downloads for the new models include all required files (including sharded weights if present) and pass verification.
- [ ] AC-4: LLMService can load and switch to either model using the per-model profile (template, context, warmup, defaults).
- [ ] AC-5: Preferences UI lets the user set a primary and optional planner model with clear badges.
- [ ] AC-6: If the planner model is not available, the app continues using the primary model without errors.

## 7. Verification Plan

### Automated Tests

- [ ] ModelManager tests for storage paths, required files, and planner selection persistence.
- [ ] Preferences tests for primary/planner selection updates.

### Manual Tests

- [ ] Download Qwen3 4B and Orchestrator 8B from Preferences and verify status changes to Ready.
- [ ] Set Qwen3 4B as primary and Orchestrator 8B as planner, relaunch, and confirm selections persist.
- [ ] Delete the planner model and verify the app falls back to primary without crashing.

## 8. Performance / Reliability Considerations

- Qwen3 4B and Orchestrator 8B increase disk and memory usage; keep TTFT <400ms after warmup.
- Load only one model by default; planner loads should be explicit and memory-safe.

## 9. Risks & Mitigations

- Repo file layouts may change or be sharded - support index files or configurable file lists.
- Orchestrator 8B may exceed memory on smaller Macs - gate availability and warn in UI.

## 10. Open Questions

- Confirm HuggingFace repo names and file lists for Qwen3 4B and Orchestrator 8B.
- Confirm chat template and context length requirements for Orchestrator 8B.
- Decide whether model selection persistence lives in ModelManager metadata or AppSettings.

---

## Implementation Summary

(TBD after implementation.)

## Code Review Findings

(TBD by review agent.)

## Completion Status

(TBD after merge.)
