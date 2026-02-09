# C.06 - OpenAI Codex OAuth Support

**Epic:** Cloud Integrations (C)
**Status:** Reopened (Regression Fix Round 2 Implemented, Pending Live Validation)
**Priority:** P2
**Estimated Effort:** 2-3 days
**Dependencies:** C.04 (OpenAI Provider), C.05 (Provider Preferences UI)
**Target:** macOS 26 (Tahoe)
**Design Reference:** [OpenAI Codex CLI (open source)](https://github.com/openai/codex)

---

## 1. Objective

Allow users with a ChatGPT Plus/Pro/Team subscription to authenticate via the same OAuth flow used by OpenAI's Codex CLI. This lets them use their existing subscription for Ora's cloud inference without needing a separate API key. The feature adds a "Have ChatGPT Pro?" prompt and "Authorize Codex" button to the OpenAI section of Provider Preferences, and must use the current Codex Responses API wire format end-to-end.

## 2. User Story

As a **ChatGPT subscriber**, I want to **authorize Ora using my ChatGPT account via the Codex OAuth flow** so that I can **use cloud models through my existing subscription without creating a separate API key**.

## 3. Scope

### In Scope
- OAuth PKCE flow using OpenAI's public Codex client ID
- Browser-based authentication via localhost loopback callback (Codex-compatible)
- Token storage (access token, refresh token, account ID) in macOS Keychain
- Automatic token refresh when access token expires
- Reading existing Codex CLI credentials from `~/.codex/auth.json` as a fallback
- Codex-specific provider variant that routes requests to the Codex Responses endpoint (`chatgpt.com/backend-api/codex/...`)
- "Have ChatGPT Pro?" label and "Authorize Codex" button in the OpenAI preferences section
- Disconnect/sign-out button when authenticated
- Status display (signed in as account, or not connected)

### Out of Scope
- Implementing our own ChatGPT protocol from scratch (we mirror Codex CLI's current wire format)
- Supporting other ChatGPT features (browsing, DALL-E, plugins)
- Sharing tokens back with the Codex CLI
- Anthropic Claude Code OAuth (blocked for third parties as of Jan 2026)

## 4. Architecture Alignment

### MUST REUSE
- **`ProviderPreferencesView`** (from C.05) - Add Codex auth UI below the OpenAI API key section
- **`ProviderPreferencesViewModel`** (from C.05) - Add Codex auth state and actions
- **`KeychainCredentialStore`** (from C.01) - Store OAuth tokens in Keychain
- **`CloudLLMBase`** (from C.02) - Base class for the Codex provider variant
- **`LLMProviderManager`** (from C.02) - Register Codex factory alongside OpenAI factory

### Key Technical Details

**OAuth Flow (PKCE):**
- Authorization endpoint: `https://auth.openai.com/oauth/authorize`
- Token endpoint: `https://auth.openai.com/oauth/token`
- Client ID: `app_EMoamEEZ73f0CkXaXp7hrann` (Codex's public client ID)
- Redirect URI: `http://localhost:1455/auth/callback` (Codex CLI-compatible)
- Grant type: `authorization_code` with PKCE (S256)

**API Endpoint (Codex/ChatGPT OAuth):**
- Base URL: `https://chatgpt.com/backend-api/codex`
- Generation path: `/responses` (Responses API wire format)
- Model discovery path: `/models`
- Auth header: `Authorization: Bearer <access_token>`
- Extra header: `chatgpt-account-id: <account_id>`
- Content-Type: `application/json`

**Existing Codex CLI Credential Locations (read-only fallback):**
- File: `~/.codex/auth.json` (or `$CODEX_HOME/auth.json`)
- Format: `{ "tokens": { "access_token": "...", "refresh_token": "...", "account_id": "..." }, "last_refresh": "..." }`

**Token Lifecycle:**
- Access tokens are JWTs with an `exp` claim
- Refresh via POST to `https://auth.openai.com/oauth/token` with `grant_type=refresh_token`
- Store refresh token securely in Keychain; rotate on each refresh

### Concurrency
- OAuth flow runs with a background loopback listener + browser launch on `@MainActor`
- Token refresh runs on background actor (auto-triggered before API calls)
- Provider instance is `@unchecked Sendable` (same pattern as `OpenAIProvider`)

### UI Placement

The Codex auth UI appears **below** the existing OpenAI API key section in `ProviderPreferencesView`:

```
─── OpenAI ──────────────────────────
API Key:  [sk-...              ] [Save] [Delete]
Model:    [GPT-4o               ▾]
Status:   ✓ Key saved

Have ChatGPT Pro?
[Authorize Codex]              ← opens browser OAuth
Status:   ✓ Signed in (account@email.com)  [Disconnect]
```

When Codex is authorized, the user can select OpenAI as active provider and it will prefer the Codex OAuth token over the API key. If both exist, the UI shows which credential is active.

---

## 5. Progress & Implementation Plan

### 5.0 Progress Snapshot (2026-02-09)

- [x] OAuth PKCE + token refresh implemented (`Ora/Cloud/OpenAI/CodexOAuthManager.swift`)
- [x] Codex credential import from CLI auth implemented (`Ora/Cloud/OpenAI/CodexCredentialReader.swift`)
- [x] Preferences UI authorize/disconnect flow implemented (`Ora/Preferences/Tabs/ProviderPreferencesView.swift`)
- [x] OpenAI provider resolution prefers Codex OAuth over API key (`Ora/Cloud/LLMProviderManager.swift`)
- [x] Codex provider now uses `/backend-api/codex/responses` with Codex-compatible Responses request shape (`Ora/Cloud/OpenAI/CodexProvider.swift`)
- [x] Discovery path supports Codex OAuth credentials and `client_version` query (`Ora/Cloud/OpenAI/OpenAIModelDiscoveryService.swift`)

### 5.1 Research Findings (2026-02-09)

1. OAuth redirect mismatch:
   - Upstream Codex login uses localhost callback (`http://localhost:<port>/auth/callback`), while Ora used a custom `ora://` redirect, which can fail at auth redirect.
2. Workspace/account ID mismatch:
   - `chatgpt-account-id` must map to ChatGPT workspace ID (`chatgpt_account_id` claim under `https://api.openai.com/auth`), not generic `sub` fallback.
3. Generation request mismatch:
   - Codex path expects Responses-style payload with `instructions`, `input`, `tool_choice`, `parallel_tool_calls`, `store`, `stream`; legacy/extra fields can fail.
4. Discovery request compatibility:
   - Codex model discovery requires `/backend-api/codex/models` with `client_version` and Codex headers (`originator`, `version`, account header when available).

### 5.2 Files to Create

| File | Purpose |
|:-----|:--------|
| `Ora/Cloud/OpenAI/CodexOAuthManager.swift` | PKCE OAuth flow, token storage, refresh logic |
| `Ora/Cloud/OpenAI/CodexResponsesParser.swift` | Parse Responses API streaming events for Codex OAuth path (new helper) |
| `Ora/Cloud/OpenAI/CodexProviderFactory.swift` | Factory that creates CodexProvider with OAuth token |
| `Ora/Cloud/OpenAI/CodexCredentialReader.swift` | Reads existing ~/.codex/auth.json (fallback) |
| `OraTests/Cloud/OpenAI/CodexOAuthManagerTests.swift` | OAuth flow and token refresh tests |
| `OraTests/Cloud/OpenAI/CodexProviderTests.swift` | Provider tests with mocked HTTP |
| `OraTests/Cloud/OpenAI/CodexCredentialReaderTests.swift` | File-based credential reading tests |

### 5.3 Files to Modify

| File | Change |
|:-----|:-------|
| `Ora/Cloud/CloudProvider.swift` | Add `case openaiCodex` to `CloudProvider` enum |
| `Ora/Cloud/LLMProviderType.swift` | Add Codex awareness (OpenAI provider type can use either API key or Codex OAuth) |
| `Ora/Cloud/OpenAI/CodexProvider.swift` | Replace legacy `/conversation` request path/body with Responses API (`/responses`) |
| `Ora/Cloud/OpenAI/OpenAIModelDiscoveryService.swift` | Add credential strategy for API key vs Codex OAuth, and Codex model discovery endpoint |
| `Ora/Preferences/Tabs/ProviderPreferencesView.swift` | Add "Have ChatGPT Pro?" section with Authorize/Disconnect buttons |
| `Ora/Preferences/Tabs/ProviderPreferencesViewModel.swift` | Drive discovery/refresh using active credential source; expose refresh state/error |
| `Ora/Orchestration/AgentLoop.swift` | Map model-not-found/invalid-model request failures to actionable user guidance |
| `Ora/AppDelegate.swift` | Register Codex provider factory when OAuth token is available |

### 5.4 Tests to Add / Update

- `test_oauthPKCE_generatesCorrectChallenge` - Verify S256 code challenge generation
- `test_tokenExchange_parsesResponse` - Token endpoint response parsing
- `test_tokenRefresh_updatesKeychain` - Refresh flow stores new tokens
- `test_tokenRefresh_expiryCheck` - Refresh triggered before expiry
- `test_readCodexCredentials_parsesAuthJson` - Reading ~/.codex/auth.json
- `test_readCodexCredentials_missingFile_returnsNil` - Graceful handling of missing file
- `test_codexProvider_setsCorrectHeaders` - Bearer + chatgpt-account-id headers
- `test_codexProvider_usesResponsesEndpoint` - Verify `/backend-api/codex/responses` path
- `test_codexProvider_streamsResponsesEvents` - Streaming parser for Responses API event shapes
- `test_authorize_updatesStatus` - UI status updates after successful auth
- `test_disconnect_clearsTokens` - Keychain cleared on disconnect
- `test_modelDiscovery_withCodexCredential_fetchesRemoteModels` - Refresh works with OAuth-only setup
- `test_refreshModelAvailability_codexOnly_updatesOpenAISelectableModels` - ViewModel refresh behavior regression test

### 5.5 Dependencies/Config

- No new package dependencies
- Loopback callback uses Apple `Network` framework (already available on target macOS)

### 5.6 Regression Fix Round 2 (2026-02-09)

- `Ora/Cloud/OpenAI/CodexOAuthManager.swift`
  - Switched to loopback localhost redirect flow (`http://localhost:1455/auth/callback`)
  - Added Codex-compatible authorize params and robust callback handling
  - Added JWT nested-claim parsing (`https://api.openai.com/auth` + `.../profile`) to resolve workspace account ID and email correctly
- `Ora/Cloud/OpenAI/CodexCredentialReader.swift`
  - Prefer `chatgpt_account_id` claim when `account_id` missing in CLI auth file
- `Ora/Cloud/OpenAI/CodexProvider.swift`
  - Updated request body to Codex-compatible Responses shape (`instructions`, `tool_choice`, `parallel_tool_calls`, `store`, `stream`)
  - Added Codex-style `User-Agent` and improved nested error extraction
- `Ora/Cloud/OpenAI/OpenAIModelDiscoveryService.swift`
  - Codex-aware headers/query handling (`client_version`, `originator`, `version`, `User-Agent`)
  - Kept API-key discovery path intact
- Test coverage updated:
  - `OraTests/Cloud/OpenAI/CodexOAuthManagerTests.swift`
  - `OraTests/Cloud/OpenAI/CodexCredentialReaderTests.swift`
  - `OraTests/Cloud/OpenAI/CodexProviderTests.swift`
  - `OraTests/Cloud/OpenAI/OpenAIModelDiscoveryServiceTests.swift`

## 6. Acceptance Criteria

- [x] **AC-1:** "Have ChatGPT Pro?" label and "Authorize Codex" button appear below the OpenAI API key section in Provider Preferences
- [x] **AC-2:** Clicking "Authorize Codex" opens a browser-based OAuth flow with localhost loopback callback
- [x] **AC-3:** After successful authentication, status shows "Signed in" with account identifier
- [x] **AC-4:** OAuth tokens (access, refresh, account ID) are stored securely in macOS Keychain
- [x] **AC-5:** "Disconnect" button clears stored tokens and resets status
- [x] **AC-6:** When Codex OAuth is available, selecting OpenAI uses Codex Responses endpoint (`/backend-api/codex/responses`)
- [x] **AC-7:** Tokens are automatically refreshed before expiry
- [x] **AC-8:** If Codex CLI is installed and authenticated, Ora can read its credentials from `~/.codex/auth.json` as a quick-start
- [x] **AC-9:** LLM responses stream correctly through the Codex Responses endpoint (unit coverage; live validation pending)
- [x] **AC-10:** Settings persist across app restarts
- [x] **AC-11:** "Refresh Models" fetches remote models when only Codex OAuth is configured (unit coverage; live validation pending)

---

## 7. Verification Plan

### Automated Tests

- `test_oauthPKCE_generatesCorrectChallenge` - PKCE S256 code verifier/challenge
- `test_tokenExchange_parsesResponse` - Token endpoint JSON parsing
- `test_tokenRefresh_updatesKeychain` - Refresh stores new tokens
- `test_tokenRefresh_expiryCheck` - Auto-refresh trigger before expiry
- `test_readCodexCredentials_parsesAuthJson` - Parse ~/.codex/auth.json
- `test_readCodexCredentials_missingFile_returnsNil` - Missing file handling
- `test_codexProvider_setsCorrectHeaders` - Verify Authorization + chatgpt-account-id headers
- `test_codexProvider_usesResponsesEndpoint` - Verify Codex path is `/backend-api/codex/responses`
- `test_codexProvider_streamsResponsesEvents` - Responses event parsing
- `test_authorize_updatesStatus` - ViewModel state after auth
- `test_disconnect_clearsTokens` - Keychain cleared on disconnect
- `test_modelDiscovery_withCodexCredential_fetchesRemoteModels` - Codex credential discovery refresh

### Manual Tests

1. Open Preferences > Providers, verify "Have ChatGPT Pro?" section appears below OpenAI API key
2. Click "Authorize Codex", verify browser opens to OpenAI login
3. Complete authentication, verify status shows "Signed in"
4. Select OpenAI as active provider, ask a question, verify response streams
5. Close and reopen Preferences, verify Codex auth persists
6. Click "Disconnect", verify status resets and tokens are cleared
7. If Codex CLI is installed: verify Ora detects existing credentials on first load
8. Click "Refresh Models" with Codex-only auth, verify network refresh updates OpenAI model list
9. Test with expired token: verify auto-refresh works transparently

---

## 8. Performance / Reliability Considerations

- **Token refresh latency:** Refresh should happen proactively (before expiry), not on-demand during inference. Target: <500ms refresh latency.
- **OAuth flow timeout:** Loopback listener should time out after 5 minutes if user abandons browser login.
- **Fallback:** If Codex OAuth fails (expired refresh token, revoked access), fall back to API key if available, or show clear error.
- **No credential leakage:** OAuth tokens must never appear in logs. Use `Logger` with default privacy (`.private`).

## 9. Risks & Mitigations

| Risk | Mitigation |
|:-----|:-----------|
| Protocol drift between Ora and Codex CLI | Reuse Codex's Responses wire assumptions (`/responses`, no legacy chat wire) and add endpoint/shape regression tests. |
| OpenAI changes the public client ID or OAuth endpoints | Pin the client ID as a constant; add a config override for future updates. Monitor Codex CLI releases for changes. |
| Token refresh fails silently | Implement retry with exponential backoff (max 3 attempts). On final failure, surface error in UI and fall back to API key. |
| Loopback listener port unavailable | Use clear error messaging and retry guidance; keep callback listener scope minimal and short-lived. |
| Rate limits on ChatGPT subscription differ from API | Surface rate-limit errors clearly in UI. Different from API rate limits (subscription-based usage windows vs. RPM/TPM). |

## 10. Open Questions

- Should Codex OAuth take priority over API key when both are configured, or should the user choose?
- Should Codex-auth model defaults be `gpt-5.2-codex` when available, while API-key defaults remain `gpt-5.2`?

## 11. Research Sources (2026-02-09)

- OpenAI Codex login flow (localhost callback, authorize params): https://raw.githubusercontent.com/openai/codex/main/codex-rs/login/src/server.rs
- OpenAI Codex provider wire definition (`wire_api = responses`, ChatGPT auth base URL): https://raw.githubusercontent.com/openai/codex/main/codex-rs/core/src/model_provider_info.rs
- OpenAI Codex models endpoint behavior (`client_version` query): https://raw.githubusercontent.com/openai/codex/main/codex-rs/codex-api/src/endpoint/models.rs
- OpenAI Codex model presets (`gpt-5.2-codex`, `gpt-5.2`, Codex-focused defaults): https://raw.githubusercontent.com/openai/codex/main/codex-rs/core/src/models_manager/model_presets.rs
- OpenAI platform docs (`chat.completions` parameter deprecations and migration toward Responses API): https://platform.openai.com/docs/api-reference/chat/create

---

## Implementation Summary

(TBD after implementation.)

## Code Review Findings

(TBD by review agent.)

## Completion Status

(TBD after merge.)

---

## Regression Investigation Round 3 (2026-02-09)

### Live Symptoms Reported

- Intermittent turn failure with generic user error: `I had trouble generating a response. Please try again.`
- Log pattern:
  - `STRUCTURED_ATTEMPT_1_COMPLETED_WITH_FRAGMENTS`
  - `STRUCTURED_ATTEMPT_1_VALIDATION_FAILED`
  - `STRUCTURED_ATTEMPT_2_STARTED`
  - immediate generation failure (no successful attempt completion)
- UI occasionally showed both a partial/working-looking response and an error response in the same turn.

### Findings

1. Structured retry path mixed two failure classes without clear diagnostics:
   - JSON validation failures (expected occasionally on first attempt)
   - transport/request failures on retry attempts (not clearly classified)
2. Retry context included a synthetic assistant message containing invalid JSON output, which increases request-shape fragility on cloud paths.
3. Provider/discovery logs were too opaque for triage (status/body details redacted into generic failure path).

### Implemented in this round

- `Ora/LLM/StructuredGenerator.swift`
  - Added per-attempt stream failure logging markers (`STRUCTURED_ATTEMPT_*_STREAM_FAILED` + cloud failure category markers).
  - Retry strategy updated:
    - On validation failure: append a single user retry instruction with a bounded snippet of invalid output.
    - On stream/request failure: reset retry context to base messages before next attempt.
  - Keeps streaming fragments gated to successful validated attempts only.
- `Ora/Cloud/OpenAI/CodexProvider.swift`
  - Added deterministic HTTP/status/body-category failure markers for stream failures.
- `Ora/Cloud/OpenAI/OpenAIProvider.swift`
  - Added deterministic HTTP/status/body-category failure markers for stream failures.
- `Ora/Cloud/OpenAI/OpenAIModelDiscoveryService.swift`
  - Added deterministic discovery failure markers (API key vs Codex path + status/body category).
- `Ora/Orchestration/AgentLoop.swift`
  - Expanded `CloudProviderError.requestFailed` guidance for 400/403/404 and request-shape/context-limit cases, reducing fallback to generic error copy.

### Verification

- Automated:
  - `✅ Tests: 1292/1292 passed`
  - Includes updated regressions in:
    - `OraTests/StructuredGeneratorTests.swift`
    - `OraTests/Orchestration/AgentLoopTests.swift`
- Manual live validation still required for:
  - repeated retries on `gpt-5.2` and `gpt-5.2-codex`
  - discovery refresh under Codex-only auth
