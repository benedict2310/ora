# C.06 - OpenAI Codex OAuth Support

**Epic:** Cloud Integrations (C)
**Status:** Not Started
**Priority:** P2
**Estimated Effort:** 2-3 days
**Dependencies:** C.04 (OpenAI Provider), C.05 (Provider Preferences UI)
**Target:** macOS 26 (Tahoe)
**Design Reference:** [OpenAI Codex CLI (open source)](https://github.com/openai/codex)

---

## 1. Objective

Allow users with a ChatGPT Plus/Pro/Team subscription to authenticate via the same OAuth flow used by OpenAI's Codex CLI. This lets them use their existing subscription for Ora's cloud inference without needing a separate API key. The feature adds a "Have ChatGPT Pro?" prompt and "Authorize Codex" button to the OpenAI section of Provider Preferences.

## 2. User Story

As a **ChatGPT subscriber**, I want to **authorize Ora using my ChatGPT account via the Codex OAuth flow** so that I can **use cloud models through my existing subscription without creating a separate API key**.

## 3. Scope

### In Scope
- OAuth PKCE flow using OpenAI's public Codex client ID
- Browser-based authentication via `ASWebAuthenticationSession`
- Token storage (access token, refresh token, account ID) in macOS Keychain
- Automatic token refresh when access token expires
- Reading existing Codex CLI credentials from `~/.codex/auth.json` as a fallback
- Codex-specific provider variant that routes requests to `chatgpt.com/backend-api/`
- "Have ChatGPT Pro?" label and "Authorize Codex" button in the OpenAI preferences section
- Disconnect/sign-out button when authenticated
- Status display (signed in as account, or not connected)

### Out of Scope
- Implementing our own ChatGPT conversation API from scratch (we replicate the Codex CLI's wire format)
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
- Redirect URI: Custom scheme or `ASWebAuthenticationSession` callback
- Grant type: `authorization_code` with PKCE (S256)

**API Endpoint (Codex/ChatGPT OAuth):**
- Base URL: `https://chatgpt.com/backend-api/`
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
- OAuth flow runs on `@MainActor` (UI-driven browser session)
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

## 5. Implementation Plan (Draft)

### 5.1 Files to Create

| File | Purpose |
|:-----|:--------|
| `Ora/Cloud/OpenAI/CodexOAuthManager.swift` | PKCE OAuth flow, token storage, refresh logic |
| `Ora/Cloud/OpenAI/CodexProvider.swift` | LLMServicing implementation for chatgpt.com/backend-api/ |
| `Ora/Cloud/OpenAI/CodexProviderFactory.swift` | Factory that creates CodexProvider with OAuth token |
| `Ora/Cloud/OpenAI/CodexCredentialReader.swift` | Reads existing ~/.codex/auth.json (fallback) |
| `OraTests/Cloud/OpenAI/CodexOAuthManagerTests.swift` | OAuth flow and token refresh tests |
| `OraTests/Cloud/OpenAI/CodexProviderTests.swift` | Provider tests with mocked HTTP |
| `OraTests/Cloud/OpenAI/CodexCredentialReaderTests.swift` | File-based credential reading tests |

### 5.2 Files to Modify

| File | Change |
|:-----|:-------|
| `Ora/Cloud/CloudProvider.swift` | Add `case openaiCodex` to `CloudProvider` enum |
| `Ora/Cloud/LLMProviderType.swift` | Add Codex awareness (OpenAI provider type can use either API key or Codex OAuth) |
| `Ora/Preferences/Tabs/ProviderPreferencesView.swift` | Add "Have ChatGPT Pro?" section with Authorize/Disconnect buttons |
| `Ora/Preferences/Tabs/ProviderPreferencesViewModel.swift` | Add Codex auth state, authorize/disconnect actions |
| `Ora/AppDelegate.swift` | Register Codex provider factory when OAuth token is available |

### 5.3 Tests to Add

- `test_oauthPKCE_generatesCorrectChallenge` - Verify S256 code challenge generation
- `test_tokenExchange_parsesResponse` - Token endpoint response parsing
- `test_tokenRefresh_updatesKeychain` - Refresh flow stores new tokens
- `test_tokenRefresh_expiryCheck` - Refresh triggered before expiry
- `test_readCodexCredentials_parsesAuthJson` - Reading ~/.codex/auth.json
- `test_readCodexCredentials_missingFile_returnsNil` - Graceful handling of missing file
- `test_codexProvider_setsCorrectHeaders` - Bearer + chatgpt-account-id headers
- `test_codexProvider_streamsTokens` - SSE parsing from chatgpt.com endpoint
- `test_authorize_updatesStatus` - UI status updates after successful auth
- `test_disconnect_clearsTokens` - Keychain cleared on disconnect

### 5.4 Dependencies/Config

- No new package dependencies (uses `ASWebAuthenticationSession` from AuthenticationServices framework)
- `project.yml` - Add `AuthenticationServices` framework link if not already present

## 6. Acceptance Criteria

- [ ] **AC-1:** "Have ChatGPT Pro?" label and "Authorize Codex" button appear below the OpenAI API key section in Provider Preferences
- [ ] **AC-2:** Clicking "Authorize Codex" opens a browser-based OAuth flow via `ASWebAuthenticationSession`
- [ ] **AC-3:** After successful authentication, status shows "Signed in" with account identifier
- [ ] **AC-4:** OAuth tokens (access, refresh, account ID) are stored securely in macOS Keychain
- [ ] **AC-5:** "Disconnect" button clears stored tokens and resets status
- [ ] **AC-6:** When Codex OAuth is available, selecting the OpenAI provider uses the Codex endpoint (`chatgpt.com/backend-api/`)
- [ ] **AC-7:** Tokens are automatically refreshed before expiry
- [ ] **AC-8:** If Codex CLI is installed and authenticated, Ora can read its credentials from `~/.codex/auth.json` as a quick-start
- [ ] **AC-9:** LLM responses stream correctly through the Codex endpoint
- [ ] **AC-10:** Settings persist across app restarts

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
- `test_codexProvider_streamsTokens` - SSE response parsing
- `test_authorize_updatesStatus` - ViewModel state after auth
- `test_disconnect_clearsTokens` - Keychain cleared on disconnect

### Manual Tests

1. Open Preferences > Providers, verify "Have ChatGPT Pro?" section appears below OpenAI API key
2. Click "Authorize Codex", verify browser opens to OpenAI login
3. Complete authentication, verify status shows "Signed in"
4. Select OpenAI as active provider, ask a question, verify response streams
5. Close and reopen Preferences, verify Codex auth persists
6. Click "Disconnect", verify status resets and tokens are cleared
7. If Codex CLI is installed: verify Ora detects existing credentials on first load
8. Test with expired token: verify auto-refresh works transparently

---

## 8. Performance / Reliability Considerations

- **Token refresh latency:** Refresh should happen proactively (before expiry), not on-demand during inference. Target: <500ms refresh latency.
- **OAuth flow timeout:** `ASWebAuthenticationSession` should time out after 5 minutes if user abandons the flow.
- **Fallback:** If Codex OAuth fails (expired refresh token, revoked access), fall back to API key if available, or show clear error.
- **No credential leakage:** OAuth tokens must never appear in logs. Use `Logger` with default privacy (`.private`).

## 9. Risks & Mitigations

| Risk | Mitigation |
|:-----|:-----------|
| ChatGPT backend API format differs from standard Chat Completions | Reference the open-source Codex CLI (Rust) for exact request/response format. The `chatgpt_client.rs` module documents the wire protocol. |
| OpenAI changes the public client ID or OAuth endpoints | Pin the client ID as a constant; add a config override for future updates. Monitor Codex CLI releases for changes. |
| Token refresh fails silently | Implement retry with exponential backoff (max 3 attempts). On final failure, surface error in UI and fall back to API key. |
| `ASWebAuthenticationSession` requires entitlements | Verify app sandbox compatibility. The framework works in sandboxed apps but may need `com.apple.security.network.client` entitlement. |
| Rate limits on ChatGPT subscription differ from API | Surface rate-limit errors clearly in UI. Different from API rate limits (subscription-based usage windows vs. RPM/TPM). |

## 10. Open Questions

- What is the exact wire format for `chatgpt.com/backend-api/conversation`? Must be reverse-engineered from the Codex CLI Rust source (`codex-rs/core/src/chatgpt_client.rs`).
- Does `ASWebAuthenticationSession` support the localhost redirect URI (`http://localhost:1455/auth/callback`), or do we need a custom URL scheme?
- Should Codex OAuth take priority over API key when both are configured, or should the user choose?
- Can we use the same `OpenAIModel` enum for Codex, or does the ChatGPT backend support a different/extended model list?

---

## Implementation Summary

(TBD after implementation.)

## Code Review Findings

(TBD by review agent.)

## Completion Status

(TBD after merge.)
