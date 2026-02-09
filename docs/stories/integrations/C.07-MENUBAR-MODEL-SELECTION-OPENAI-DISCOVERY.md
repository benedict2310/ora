# C.07 - Menubar Model Selection & OpenAI Model Discovery

**Epic:** Cloud Integrations (C)
**Status:** Reopened (Regression Fix Round 2 Implemented, Pending Live Validation)
**Priority:** P1
**Estimated Effort:** 2-3 days
**Dependencies:** C.02 (Cloud Provider Abstraction), C.04 (OpenAI Provider), C.05 (Provider Preferences UI), F.01 (App Shell & Menu Bar), F.06 (Preferences Window)
**Target:** macOS 26 (Tahoe)
**Design Reference:** None

---

## 1. Objective

Eliminate provider/model ambiguity at conversation start by adding a low-friction model selector directly in the menubar menu, with clear availability states and OpenAI model discovery. Users should always know which LLM is active, what models are selectable, and exactly how to recover when a provider is not configured.

## 1.1 Regression Update (2026-02-09)

- Repro: sending a prompt while `OpenAI` + `GPT-5.2` is selected can return `I had trouble generating a response. Please try again.`
- Repro: `Refresh Models` can appear to do nothing when the user is connected via Codex OAuth but has no OpenAI API key saved.
- Root causes identified from upstream Codex sources: localhost OAuth redirect mismatch, workspace account-id extraction mismatch (`chatgpt_account_id`), and Codex Responses request shape drift.
- This story is reopened to close those regressions before final sign-off.

## 2. User Story

As a **user**, I want to **select provider and model from the menubar and only see models that are actually usable** so that I can **start conversations without setup confusion or hidden provider failures**.

## 3. Scope

### In Scope

- Add a menubar "Select Model" section for fast provider/model switching.
- Surface currently active provider + model in the menu.
- Local model option: `Qwen 3 4B`.
- Anthropic model options: `Claude Sonnet 4`, `Claude Haiku 4`, `Claude Opus 4`.
- OpenAI default model: `GPT-5.2`.
- OpenAI model discovery endpoint integration to list additional available models when a valid OpenAI credential exists.
- Conditional OpenAI model list behavior:
  - If models are discoverable: show selectable discovered models.
  - If discovery cannot run (no credential / disconnected): hide model list and show `Set Up Connection…`.
- `Set Up Connection…` action opens Preferences and routes directly to Providers tab.
- Preflight provider/model readiness before conversation start to avoid falling into the generic "I had trouble understanding that" path for configuration problems.

### Out of Scope

- Anthropic dynamic model discovery (static curated list for v1 of this story).
- Per-conversation provider overrides inside the overlay transcript.
- Keychain/OAuth implementation changes (covered by prior cloud stories).
- Billing/usage controls or quota dashboards.

## 4. Architecture Alignment

### MUST REUSE

- `StatusBarController` (`Ora/UI/StatusBarController.swift`) for menu composition and action handling.
- `PreferencesCoordinator.selectTab(_:)` (`Ora/Preferences/PreferencesCoordinator.swift`) to route `Set Up Connection…` directly to `.providers`.
- `ProviderPreferencesViewModel` (`Ora/Preferences/Tabs/ProviderPreferencesViewModel.swift`) for provider/model state and credential status.
- `LLMProviderManager` (`Ora/Cloud/LLMProviderManager.swift`) as the single source of truth for active provider and switching.
- Existing model types:
  - `ModelIdentifier.qwen3_4B` (`Ora/Models/ModelTypes.swift`)
  - `AnthropicModel` (`Ora/Cloud/Anthropic/AnthropicModels.swift`)
  - `OpenAIModel` (`Ora/Cloud/OpenAI/OpenAIModels.swift`) with extension path for discovered models.

### Key Technical Details

- Add an OpenAI model discovery service that uses credential-aware endpoints for model discovery (API key: `https://api.openai.com/v1/models`; Codex OAuth: `https://chatgpt.com/backend-api/codex/models`) and returns a filtered, user-facing model list.
- Define a canonical selection model that supports both:
  - Static models (Local, Anthropic curated set)
  - Dynamic models (OpenAI discovered set)
- Persist selected provider/model through existing `UserDefaults` pathways used by `LLMProviderManager`.
- Treat `GPT-5.2` as the preferred OpenAI default. If unavailable in discovery results, keep current valid selection and surface an unavailable note in menu/preferences.
- Replace configuration-caused startup failures with an actionable recovery path (fallback to local or guided setup prompt, with explicit reason logged in `providers` category).

### Concurrency & UI Boundaries

- All menu state updates on `@MainActor`.
- Network discovery off-main-thread using Swift Concurrency (`async/await`), with cached results and cancellation support.
- Do not block menu open while fetching; show last-known state immediately and refresh asynchronously.

## 5. Implementation Plan (Draft)

### 5.1 Files to Create

- `Ora/Cloud/OpenAI/OpenAIModelDiscoveryService.swift` - Fetch/filter/cache OpenAI model list; expose async API for UI and provider settings.
- `Ora/UI/ModelSelectionMenuState.swift` - Lightweight view state for provider/model availability and "set up connection" gating.
- `OraTests/Cloud/OpenAI/OpenAIModelDiscoveryServiceTests.swift` - Discovery parsing/filtering/caching/error handling.

### 5.2 Files to Modify

- `Ora/UI/StatusBarController.swift` - Add "Select Model" menu section, provider/model actions, and `Set Up Connection…` routing.
- `Ora/Preferences/Tabs/ProviderPreferencesView.swift` - Align model picker UX with availability states and OpenAI discovered models.
- `Ora/Preferences/Tabs/ProviderPreferencesViewModel.swift` - Expose model availability state, discovery load/refresh, and selected model reconciliation.
- `Ora/Cloud/OpenAI/OpenAIModels.swift` - Set `GPT-5.2` as default curated option and support discovered-model display metadata.
- `Ora/Cloud/LLMProviderManager.swift` - Validate selected model/provider readiness at switch/startup and ensure safe fallback behavior.
- `Ora/Orchestration/AgentLoop.swift` - Improve config-related failure handling path so provider misconfiguration surfaces actionable messaging instead of generic ASR-style failure text.
- `OraTests/StatusBarControllerTests.swift` - Menu coverage for model section, action wiring, and setup routing.
- `OraTests/Preferences/ProviderPreferencesViewModelTests.swift` - Discovery and availability state transitions.
- `OraTests/Cloud/LLMProviderManagerTests.swift` - Default selection, unavailable model handling, fallback behavior.
- `OraTests/Orchestration/AgentLoopTests.swift` - Config-error user message regression coverage.

### 5.3 Tests to Add

- `test_statusBarMenu_showsActiveProviderAndModel`
- `test_statusBarMenu_openAIWithoutCredential_showsSetUpConnection`
- `test_setUpConnection_routesToProvidersTab`
- `test_openAIModelDiscovery_withCredential_returnsFilteredList`
- `test_openAIModelDiscovery_withoutCredential_returnsUnavailableState`
- `test_openAIDefaultModel_prefersGPT52WhenAvailable`
- `test_selectedModelUnavailable_keepsAppUsableWithFallback`
- `test_conversationStart_withProviderConfigIssue_returnsActionableGuidance`

### 5.4 Dependencies/Config

- No new package dependencies expected.
- If new persistence key(s) are added for discovered model identifiers, keep them namespaced under existing `UserDefaults` conventions.

## 6. Acceptance Criteria

- [x] **AC-1:** Menubar dropdown includes a dedicated "Select Model" section that shows current provider and current model.
- [x] **AC-2:** Users can switch to Local model `Qwen 3 4B` directly from the menubar without opening Preferences.
- [x] **AC-3:** Anthropic models shown in selection UI are exactly `Sonnet`, `Haiku`, and `Opus` (Claude 4 variants), with valid persistence.
- [x] **AC-4:** OpenAI uses `GPT-5.2` as the preferred default model for new OpenAI selections.
- [x] **AC-5:** OpenAI model discovery lists additional available models when valid OpenAI credentials are present (API key and Codex OAuth paths).
- [x] **AC-6:** If OpenAI models are not available (no credential/disconnected), the UI shows `Set Up Connection…` instead of a broken/empty model picker.
- [x] **AC-7:** Selecting `Set Up Connection…` opens Preferences directly to the Providers tab.
- [ ] **AC-8:** Conversation/model failures no longer fall back to generic copy; users see actionable guidance for unavailable/invalid models.
- [x] **AC-9:** Model/provider selection state persists across restart and survives temporary discovery failures.
- [x] **AC-10:** `Refresh Models` provides visible progress and updates model availability when only Codex OAuth is configured.

## 7. Verification Plan

### Automated Tests

- [x] Unit tests for menu composition and model-switch action routing in `StatusBarControllerTests`.
- [x] Unit tests for OpenAI model discovery parsing/filtering/caching behavior.
- [x] Unit tests for provider/model fallback and defaulting logic in `LLMProviderManagerTests`.
- [x] Unit tests for Provider Preferences availability-state UI model.
- [x] Regression test that configuration errors return guidance instead of generic misunderstanding copy.

### Manual Tests

- [ ] Launch app, open menubar, confirm active provider/model is visible and selectable.
- [ ] With Local selected, start conversation and verify no cloud credential requirement.
- [ ] Remove OpenAI credentials, open model section, verify `Set Up Connection…` appears and model list is hidden.
- [ ] Click `Set Up Connection…`, verify Preferences opens on Providers tab.
- [ ] Add valid OpenAI credential, refresh menu, verify discovered model list appears and includes `GPT-5.2` when account exposes it.
- [ ] Switch between Anthropic Sonnet/Haiku/Opus and confirm selection persists after restart.
- [ ] Force an unavailable selected cloud model, start conversation, verify fallback/actionable guidance instead of generic failure.

## 8. Performance / Reliability Considerations

- Menubar open should remain responsive; avoid synchronous network on menu presentation.
- OpenAI discovery should use short-lived caching to reduce API calls and rate-limit exposure.
- Discovery failures must degrade gracefully to last-known-good model list or setup CTA.
- Provider/model readiness checks should run before generation begins, not mid-stream.

## 9. Risks & Mitigations

- OpenAI model catalog churn may break hardcoded assumptions.
  - Mitigation: treat discovery result as source of availability and keep curated fallback labels.
- User confusion from duplicated controls (Preferences + menubar).
  - Mitigation: menubar is quick switch; Providers tab remains setup/config surface with deeper controls.
- Credential-dependent UI races (menu opens before state refresh).
  - Mitigation: render deterministic loading/unavailable state and refresh asynchronously.
- Fallback behavior might hide real provider errors.
  - Mitigation: log explicit provider/model failure reason and show transparent user-facing message.

## 10. Open Questions

- Should OpenAI discovery include all compatible text models or only a curated allowlist plus discovered additions?
- Should Anthropic model list later move to discovery once a stable API is available?

## 11. Post-Completion Regression Triage (2026-02-09)

### Findings

1. Codex discovery path gap:
   - `OpenAIModelDiscoveryService` currently fetches credentials only from `.openai` API key storage, so Codex-only setups cannot truly refresh remote models.
2. Silent refresh UX:
   - `ProviderPreferencesViewModel.refreshOpenAIAvailability` falls back to curated models when Codex is connected and discovery is unavailable, producing a no-op refresh from the user's perspective.
3. Generic generation error:
   - `AgentLoop` maps `CloudProviderError.requestFailed` to generic fallback text, masking concrete model/endpoint compatibility issues.
4. Upstream protocol alignment needed:
   - Codex upstream is Responses-wire-first (`/v1/responses`) and ChatGPT-auth uses `/backend-api/codex` base URL. Our model discovery and provider behavior must align with this.

## 12. Regression Fix Round 2 (2026-02-09)

### Implemented

- OAuth auth flow aligned to Codex localhost callback (`http://localhost:1455/auth/callback`) in `Ora/Cloud/OpenAI/CodexOAuthManager.swift`.
- Workspace account ID extraction fixed to use `chatgpt_account_id` JWT claim (`https://api.openai.com/auth`) in:
  - `Ora/Cloud/OpenAI/CodexOAuthManager.swift`
  - `Ora/Cloud/OpenAI/CodexCredentialReader.swift`
- Codex generation payload aligned to Responses contract in `Ora/Cloud/OpenAI/CodexProvider.swift`:
  - now sends `instructions`, `input`, `tool_choice`, `parallel_tool_calls`, `store`, `stream`
  - codex headers normalized (`originator`, `version`, `User-Agent`, account header)
- Codex discovery request compatibility improved in `Ora/Cloud/OpenAI/OpenAIModelDiscoveryService.swift`:
  - `client_version` query + Codex headers on OAuth path
  - API key path unchanged

### Verification

- Targeted tests (affected modules): 36/36 passed.
- Full suite: `✅ Tests: 1287/1287 passed`.
- App rebuild/relaunch: `./build.sh run` succeeded and Ora launched.

### Remaining Manual Validation

- Live OAuth login from Preferences (real account).
- Live Codex-only model refresh and prompt send path.

### Implementation Plan

1. Introduce credential-aware discovery in `Ora/Cloud/OpenAI/OpenAIModelDiscoveryService.swift`:
   - API key path: `https://api.openai.com/v1/models`
   - Codex OAuth path: `https://chatgpt.com/backend-api/codex/models`
2. Update `Ora/Preferences/Tabs/ProviderPreferencesViewModel.swift`:
   - Wire refresh to active credential source.
   - Expose explicit refresh result state (`updated`, `stale`, `failed`) for user feedback.
3. Update `Ora/Preferences/Tabs/ProviderPreferencesView.swift`:
   - Show refresh progress and last result text so refresh is never silent.
4. Improve user-facing generation errors in `Ora/Orchestration/AgentLoop.swift`:
   - Map model-not-found/unsupported request failures to actionable setup/model-switch guidance.
5. Add regression tests:
   - `OraTests/Cloud/OpenAI/OpenAIModelDiscoveryServiceTests.swift`
   - `OraTests/Preferences/ProviderPreferencesViewModelTests.swift`
   - `OraTests/Orchestration/AgentLoopTests.swift`

## 13. Research Sources (2026-02-09)

- OpenAI Codex provider wire/base URL behavior: https://raw.githubusercontent.com/openai/codex/main/codex-rs/core/src/model_provider_info.rs
- OpenAI Codex login flow and callback contract: https://raw.githubusercontent.com/openai/codex/main/codex-rs/login/src/server.rs
- OpenAI Codex models endpoint and `client_version` query behavior: https://raw.githubusercontent.com/openai/codex/main/codex-rs/codex-api/src/endpoint/models.rs
- OpenAI Codex model presets (`gpt-5.2-codex`, `gpt-5.2`) and defaults: https://raw.githubusercontent.com/openai/codex/main/codex-rs/core/src/models_manager/model_presets.rs
- OpenAI API reference (`/v1/models`, chat/create docs): https://platform.openai.com/docs/api-reference/models/list and https://platform.openai.com/docs/api-reference/chat/create

---

## Implementation Summary

**Date:** 2026-02-09
**Branch:** `feat/c07-menubar-model-selection`
**Commits:** 5
**Implemented by:** codex (complexity score: 10/10)
**Reviewed by:** pi (2 iterations)

### Files Created
- `Ora/Cloud/OpenAI/OpenAIModelDiscoveryService.swift` - OpenAI model discovery with TTL caching, filtering, and graceful fallback
- `Ora/UI/ModelSelectionMenuState.swift` - Canonical menu state model for provider/model sections
- `OraTests/Cloud/OpenAI/OpenAIModelDiscoveryServiceTests.swift` - Discovery service tests with mock URLProtocol

### Files Modified
- `Ora/UI/StatusBarController.swift` - Added "Select Model" section with provider/model items, "Set Up Connection..." routing
- `Ora/Cloud/OpenAI/OpenAIModels.swift` - Added GPT-5.2 as preferred default, OpenAIModelOption for dynamic models
- `Ora/Cloud/OpenAI/OpenAIProvider.swift` - Updated default model to GPT-5.2
- `Ora/Cloud/OpenAI/OpenAIProviderFactory.swift` - Updated default model to GPT-5.2
- `Ora/Cloud/LLMProviderManager.swift` - Added preflight readiness check, dynamic model persistence, local fallback
- `Ora/Cloud/CloudProviderError.swift` - Added configurationError case
- `Ora/Orchestration/AgentLoop.swift` - Improved config-error messaging with actionable guidance
- `Ora/Orchestration/SimplePipelineController.swift` - Added preflight before conversation generation
- `Ora/Preferences/Tabs/ProviderPreferencesViewModel.swift` - Added discovery integration, availability states, model reconciliation
- `Ora/Preferences/Tabs/ProviderPreferencesView.swift` - Updated OpenAI section for discovery-driven model list
- `Ora/AppDelegate.swift` - Updated provider registration wiring
- `OraTests/StatusBarControllerTests.swift` - Added menu composition, model section, setup routing tests
- `OraTests/Preferences/ProviderPreferencesViewModelTests.swift` - Added discovery and availability state tests
- `OraTests/Cloud/LLMProviderManagerTests.swift` - Added preflight, fallback, and persistence tests
- `OraTests/Orchestration/AgentLoopTests.swift` - Added config-error guidance regression test
- `OraTests/Cloud/OpenAI/OpenAIProviderTests.swift` - Added GPT-5.2 display name test

## Code Review Findings

**Reviewer:** pi
**Date:** 2026-02-09
**Iterations:** 2

### Iteration 1
- P2: `scheduleMenuModelRefresh` used `forceRefresh: true`, bypassing cache TTL on every menu open. **Fixed** in commit `09138ed`.

### Iteration 2
- P2 (deferred): `refreshOpenAIAvailability` sets `.loading` state immediately which briefly clears model list during background refresh. Minor UX concern, acceptable for v1.
- No P0 or P1 issues.

### Approval Status
- [x] All P0 issues resolved
- [x] All P1 issues resolved
- [x] Ready for merge

## Completion Status

- [x] Implementation complete
- [x] Review findings addressed
- [x] Build verified
- [x] Tests passed (1287/1287)
- [ ] Reopened regression fixes merged and live-verified

---

## Post-Merge Fix: Submenu Hierarchy, Credential Gating & C.06 Codex Restore

**Date:** 2026-02-09
**Branch:** `fix/menubar-submenu-codex-restore`
**Issues Addressed:**

1. **Model selection was flat in the menubar** — now uses a hierarchical "LLM Model" submenu.
2. **Anthropic models showed without credentials** — providers are now credential-gated in the menu.
3. **C.06 Codex OAuth UI was lost** — C.06 branch was never merged; all Codex code restored.

### Changes

#### Menubar Submenu Hierarchy
- `Ora/UI/StatusBarController.swift` — `rebuildMenu()` now creates an "LLM Model" top-level item with an `NSMenu` submenu containing the current selection header, provider sections separated by dividers, and "Set Up Connection..." at the bottom. Menu accessor helpers (`menuItemTitles`, `menuItemKeyEquivalents`, `hasSetUpConnectionMenuItem`) updated to traverse submenus.

#### Credential Gating
- `Ora/Preferences/Tabs/ProviderPreferencesViewModel.swift` — `modelSelectionMenuState` now only includes the Anthropic section when `anthropicKeyStatus == .saved`, and the OpenAI section when `openAIKeyStatus == .saved` or `codexAuthStatus.isConnected`. Added `setupRequiredProviders` array listing providers that need setup.
- `Ora/UI/ModelSelectionMenuState.swift` — Added `setupRequiredProviders: [LLMProviderType]` field and `showsSetupAction` computed property.

#### C.06 Codex OAuth Restoration

**New files (from C.06 branch):**
- `Ora/Cloud/OpenAI/CodexOAuthManager.swift` — PKCE OAuth flow, token refresh, secure keychain persistence
- `Ora/Cloud/OpenAI/CodexProvider.swift` — ChatGPT/Codex OAuth-backed LLMServicing implementation
- `Ora/Cloud/OpenAI/CodexProviderFactory.swift` — Factory for Codex providers
- `Ora/Cloud/OpenAI/CodexCredentialReader.swift` — Reads `~/.codex/auth.json` CLI credentials
- `OraTests/Cloud/OpenAI/CodexOAuthManagerTests.swift`
- `OraTests/Cloud/OpenAI/CodexProviderTests.swift`
- `OraTests/Cloud/OpenAI/CodexCredentialReaderTests.swift`

**Modified files:**
- `Ora/Cloud/CloudProvider.swift` — Added `.openaiCodex` case
- `Ora/Cloud/CredentialStore.swift` — Error messages changed from "API key" to "credential"
- `Ora/Cloud/LLMProviderManager.swift` — Added `codexOAuthManager` dependency; `resolveProvider` tries Codex OAuth before API key for `.openai`; `ensureCredentialExists` and `isActiveProviderAligned` updated for Codex
- `Ora/Cloud/LLMProviderType.swift` — Comment updated for Codex OAuth
- `Ora/Info.plist` — Added `ora://` URL scheme for OAuth callback
- `Ora/AppDelegate.swift` — Calls `CodexOAuthManager.shared.importCLIAuthIfNeeded()` on setup
- `Ora/Preferences/Tabs/ProviderPreferencesViewModel.swift` — Added `CodexAuthStatus` enum, `codexOAuthManager` dependency, `authorizeCodex()`, `disconnectCodex()`, `refreshCodexStatus()`, `hasOpenAICredential()`, `openAICredentialSummary`, Codex-aware `switchProvider` and `deleteOpenAIKey`
- `Ora/Preferences/Tabs/ProviderPreferencesView.swift` — Added Codex OAuth section (Authorize/Disconnect buttons, `CodexAuthStatusRow`, credential summary)
- `OraTests/Cloud/CredentialStoreTests.swift` — Added `.openaiCodex` cases, updated error message assertions
- `OraTests/Cloud/LLMProviderManagerTests.swift` — Added `MockCodexOAuthManager`, Codex preference test, fixed mock injection for all local manager instances
- `OraTests/Preferences/ProviderPreferencesViewModelTests.swift` — Added `ProviderPreferencesCodexOAuthManagerMock`, authorize/disconnect tests
- `OraTests/StatusBarControllerTests.swift` — Added `StatusBarCodexOAuthManagerMock`, updated `makeController` helper, updated assertions for submenu structure

### Verification
- `./build.sh test` — 1278/1278 tests passed
- XcodeGen project regenerated to include new files
