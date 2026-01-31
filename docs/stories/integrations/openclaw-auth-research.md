# OpenClaw Authentication Architecture - Research Report

> **Source:** [github.com/openclaw/openclaw](https://github.com/openclaw/openclaw)
> **Date:** 2026-01-31
> **Purpose:** Understand how OpenClaw handles Anthropic and OpenAI authentication, to inform Ora's own provider integration.

---

## 1. Project Overview

**OpenClaw** is a personal AI assistant written in **TypeScript** (Node.js) with 123K+ stars. It connects to multiple LLM providers (Anthropic, OpenAI, Google, AWS Bedrock, GitHub Copilot, and others) and delivers the assistant experience across messaging channels (WhatsApp, Telegram, Discord, Slack, iMessage, etc.).

---

## 2. Anthropic (Claude) Authentication

### 2.1 Credential Types

Anthropic supports three authentication modes, defined in `src/agents/auth-profiles/types.ts`:

```typescript
export type ApiKeyCredential = {
  type: "api_key";
  provider: string;
  key: string;
  email?: string;
};

export type TokenCredential = {
  type: "token";
  provider: string;
  token: string;
  expires?: number;
  email?: string;
};

export type OAuthCredential = OAuthCredentials & {
  type: "oauth";
  provider: string;
  clientId?: string;
  email?: string;
};
```

### 2.2 Environment Variable Resolution

In `src/agents/model-auth.ts`, Anthropic keys are resolved with a specific priority:

```typescript
if (normalized === "anthropic") {
  return pick("ANTHROPIC_OAUTH_TOKEN") ?? pick("ANTHROPIC_API_KEY");
}
```

**OAuth tokens take priority over API keys.** The system checks `ANTHROPIC_OAUTH_TOKEN` first, then falls back to `ANTHROPIC_API_KEY`.

### 2.3 Claude CLI Credential Sync

In `src/agents/cli-credentials.ts`, OpenClaw can read credentials directly from the **Claude Code CLI**:

- **macOS Keychain**: Reads from service `"Claude Code-credentials"` using `security find-generic-password`
- **File-based**: Reads from `~/.claude/.credentials.json`
- **Format**: Extracts `claudeAiOauth.accessToken`, `claudeAiOauth.refreshToken`, and `claudeAiOauth.expiresAt`

```typescript
function readClaudeCliKeychainCredentials(execSyncImpl): ClaudeCliCredential | null {
  const result = execSyncImpl(
    `security find-generic-password -s "${CLAUDE_CLI_KEYCHAIN_SERVICE}" -w`,
    { encoding: "utf8", timeout: 5000, stdio: ["pipe", "pipe", "pipe"] }
  );
  const data = JSON.parse(result.trim());
  const claudeOauth = data?.claudeAiOauth;
  // ... extracts accessToken, refreshToken, expiresAt
}
```

The constant `CLAUDE_CLI_PROFILE_ID = "anthropic:claude-cli"` is defined in `src/agents/auth-profiles/constants.ts`.

### 2.4 Multi-Key Support

In `src/agents/live-auth-keys.ts`, the system supports **multiple Anthropic API keys** simultaneously for load distribution:

```typescript
export function collectAnthropicApiKeys(): string[] {
  // Priority: single forced key > key list > env prefixed keys > primary
  const forcedSingle = process.env.OPENCLAW_LIVE_ANTHROPIC_KEY?.trim();
  const fromList = parseKeyList(process.env.OPENCLAW_LIVE_ANTHROPIC_KEYS);
  const fromEnv = collectEnvPrefixedKeys("ANTHROPIC_API_KEY");
  const primary = process.env.ANTHROPIC_API_KEY?.trim();
  // ...deduplicates and returns all
}
```

### 2.5 Auth Mode Auto-Detection

In `src/config/defaults.ts`, the system auto-detects whether to use API key or OAuth mode:

```typescript
function resolveAnthropicDefaultAuthMode(cfg: OpenClawConfig): "api_key" | "oauth" | null {
  // 1. Check explicit auth.order for anthropic profiles
  // 2. Check if profiles are api_key or oauth
  // 3. Fall back to ANTHROPIC_OAUTH_TOKEN or ANTHROPIC_API_KEY env vars
}
```

### 2.6 Billing/Rate Limit Error Detection

```typescript
export function isAnthropicRateLimitError(message: string): boolean {
  // Matches: "rate_limit", "rate limit", "429"
}

export function isAnthropicBillingError(message: string): boolean {
  // Matches: "credit balance", "insufficient credit(s)", "payment required",
  //          "billing" + "disabled", "402"
}
```

---

## 3. OpenAI Authentication

### 3.1 Environment Variable Resolution

In `src/agents/model-auth.ts`:

```typescript
const envMap: Record<string, string> = {
  openai: "OPENAI_API_KEY",
  // ... other providers
};
```

OpenAI uses a straightforward `OPENAI_API_KEY` environment variable.

### 3.2 Codex CLI Credential Sync

OpenAI also has **CLI credential sync** via the Codex CLI (`src/agents/cli-credentials.ts`):

- **macOS Keychain**: Service `"Codex Auth"`, account derived from SHA-256 hash of `CODEX_HOME`
- **File-based**: `~/.codex/auth.json` (or `$CODEX_HOME/auth.json`)
- **Format**: `tokens.access_token`, `tokens.refresh_token`, `tokens.account_id`

```typescript
function readCodexKeychainCredentials(): CodexCliCredential | null {
  const codexHome = resolveCodexHomePath();
  const account = computeCodexKeychainAccount(codexHome);
  const secret = execSync(
    `security find-generic-password -s "Codex Auth" -a "${account}" -w`,
    { encoding: "utf8", timeout: 5000 }
  );
  // ... parses tokens.access_token, tokens.refresh_token
}
```

The constant `CODEX_CLI_PROFILE_ID = "openai-codex:codex-cli"` is defined in `src/agents/auth-profiles/constants.ts`.

### 3.3 OpenAI-Specific Error Handling

When OpenAI auth fails and the user has Codex OAuth but no API key, the system provides a specific error message:

```typescript
if (provider === "openai") {
  const hasCodex = listProfilesForProvider(store, "openai-codex").length > 0;
  if (hasCodex) {
    throw new Error(
      'No API key found for provider "openai". You are authenticated with OpenAI Codex OAuth. ' +
      'Use openai-codex/gpt-5.2 (ChatGPT OAuth) or set OPENAI_API_KEY for openai/gpt-5.2.'
    );
  }
}
```

---

## 4. Overall Provider Authentication Architecture

### 4.1 Type System

The foundation is the `ModelProviderConfig` type (`src/config/types.models.ts`):

```typescript
export type ModelProviderAuthMode = "api-key" | "aws-sdk" | "oauth" | "token";

export type ModelProviderConfig = {
  baseUrl: string;
  apiKey?: string;
  auth?: ModelProviderAuthMode;
  api?: ModelApi;
  headers?: Record<string, string>;
  authHeader?: boolean;
  models: ModelDefinitionConfig[];
};
```

### 4.2 Auth Profile System

This is the **centerpiece** of the authentication architecture. It is a multi-file module in `src/agents/auth-profiles/`:

| File | Responsibility |
|------|---------------|
| `types.ts` | Core type definitions (`ApiKeyCredential`, `OAuthCredential`, `TokenCredential`, `AuthProfileStore`) |
| `store.ts` | Load/save the credential store (JSON file with file-locking via `proper-lockfile`) |
| `paths.ts` | Resolve file paths for `auth-profiles.json` and legacy `auth.json` |
| `profiles.ts` | CRUD operations: `upsertAuthProfile`, `listProfilesForProvider`, `markAuthProfileGood` |
| `order.ts` | Profile ordering: round-robin rotation, cooldown-aware ordering |
| `usage.ts` | Cooldown tracking, exponential backoff, billing disable |
| `oauth.ts` | OAuth token resolution with file-lock-protected refresh |
| `repair.ts` | Migration from legacy profile IDs to new format |
| `doctor.ts` | Diagnostic hints for auth troubleshooting |
| `display.ts` | Human-readable labels for auth profiles |
| `external-cli-sync.ts` | Sync from Claude CLI, Codex CLI, Qwen CLI |
| `session-override.ts` | Per-session auth profile pinning and rotation |
| `constants.ts` | Well-known profile IDs, filenames, lock options |

### 4.3 Resolution Waterfall

The `resolveApiKeyForProvider()` function in `src/agents/model-auth.ts` implements the full credential resolution waterfall:

```
1. Explicit profileId parameter (if provided)
   |
2. Auth override from models config (aws-sdk mode check)
   |
3. Auth profile order (from store/config) - tries each profile in order
   |
4. Environment variables (ANTHROPIC_API_KEY, OPENAI_API_KEY, etc.)
   |
5. Custom provider API key from models.json config
   |
6. AWS SDK default chain (for Bedrock)
   |
7. Error with diagnostic message
```

Return type carries the resolved key plus metadata about where it came from:

```typescript
export type ResolvedProviderAuth = {
  apiKey?: string;
  profileId?: string;
  source: string;          // e.g. "profile:anthropic:default", "env: OPENAI_API_KEY"
  mode: "api-key" | "oauth" | "token" | "aws-sdk";
};
```

---

## 5. Key Storage and Loading

### 5.1 File-Based Credential Store

Credentials are stored in `auth-profiles.json` inside the agent directory:

- **Path**: `~/.openclaw/<agentDir>/auth-profiles.json`
- **Legacy path**: `auth.json` (migrated automatically)
- **File permissions**: `0o600` (user-only read/write)
- **Directory permissions**: `0o700` (user-only access)

Store format:

```typescript
export type AuthProfileStore = {
  version: number;           // Currently 1
  profiles: Record<string, AuthProfileCredential>;
  order?: Record<string, string[]>;        // Per-provider profile ordering
  lastGood?: Record<string, string>;       // Last successfully used profile per provider
  usageStats?: Record<string, ProfileUsageStats>;  // Cooldown/rotation tracking
};
```

### 5.2 File Locking

All writes to the auth store use `proper-lockfile` to prevent corruption from concurrent access:

```typescript
export const AUTH_STORE_LOCK_OPTIONS = {
  retries: { retries: 10, factor: 2, minTimeout: 100, maxTimeout: 10_000, randomize: true },
  stale: 30_000,
};
```

### 5.3 Agent Inheritance

Sub-agents inherit credentials from the main agent:

```typescript
// If subagent has no auth-profiles, copy from main agent
if (agentDir) {
  const mainStore = loadAuthProfileStoreForAgent(undefined);
  if (mainStore && Object.keys(mainStore.profiles).length > 0) {
    saveJsonFile(authPath, mainStore);
    return mainStore;
  }
}
```

### 5.4 OAuth Credential Storage Paths

- **OAuth directory**: `~/.openclaw/credentials/` (or `$OPENCLAW_OAUTH_DIR`)
- **OAuth file**: `~/.openclaw/credentials/oauth.json`
- **Copilot token cache**: `~/.openclaw/credentials/github-copilot.token.json`

---

## 6. Middleware, Interceptors, and Wrappers

### 6.1 OAuth Token Refresh (File-Lock Protected)

In `src/agents/auth-profiles/oauth.ts`, token refresh is protected by file locking to prevent multiple concurrent refreshes:

```typescript
async function refreshOAuthTokenWithLock(params): Promise<result | null> {
  const release = await lockfile.lock(authPath, AUTH_STORE_LOCK_OPTIONS);
  try {
    const store = ensureAuthProfileStore(params.agentDir);
    const cred = store.profiles[params.profileId];

    // Check if another process already refreshed
    if (Date.now() < cred.expires) {
      return { apiKey: buildOAuthApiKey(cred.provider, cred), newCredentials: cred };
    }

    // Provider-specific refresh
    const result = await getOAuthApiKey(cred.provider, oauthCreds);

    // Persist refreshed tokens
    store.profiles[params.profileId] = { ...cred, ...result.newCredentials, type: "oauth" };
    saveAuthProfileStore(store, params.agentDir);
    return result;
  } finally {
    await release();
  }
}
```

### 6.2 GitHub Copilot Token Exchange

In `src/providers/github-copilot-token.ts`, GitHub PAT tokens are exchanged for Copilot API tokens:

```typescript
export async function resolveCopilotApiToken(params): Promise<result> {
  // 1. Check cache (token expires with 5-minute safety margin)
  const cached = loadJsonFile(cachePath);
  if (cached && isTokenUsable(cached)) {
    return { token: cached.token, baseUrl: derivedUrl };
  }

  // 2. Exchange via GitHub Copilot API
  const res = await fetch(COPILOT_TOKEN_URL, {
    headers: {
      Accept: "application/json",
      Authorization: `Bearer ${params.githubToken}`,
    },
  });

  // 3. Cache result and derive API base URL from token
  const payload = parseCopilotTokenResponse(await res.json());
  saveJsonFile(cachePath, payload);
  return { token: payload.token, baseUrl: deriveCopilotApiBaseUrlFromToken(payload.token) };
}
```

### 6.3 Session Auth Override

Each session can have its own pinned auth profile, with automatic rotation (`src/agents/auth-profiles/session-override.ts`):

- **Auto-mode**: Rotate profiles on new sessions or compaction events
- **User-mode**: Respect explicit user choice, ignore rotation
- **Cooldown-aware**: Skip profiles in cooldown
- **Persistence**: Store override in session entry for continuity

### 6.4 Anthropic Payload Logger

All Anthropic API calls can be logged for debugging (`src/agents/anthropic-payload-log.ts`):

- Enabled via `OPENCLAW_ANTHROPIC_PAYLOAD_LOG` env var
- Logs to: `~/.openclaw/logs/anthropic-payload.jsonl`
- Wraps the stream function to intercept request payloads
- Records usage stats after each call

---

## 7. Error Handling Around Authentication Failures

### 7.1 Failover Error Classification

In `src/agents/pi-embedded-helpers/errors.ts`, errors are classified into categories:

```typescript
const ERROR_PATTERNS = {
  auth: [
    /invalid[_ ]?api[_ ]?key/, "incorrect api key", "invalid token",
    "authentication", "re-authenticate", "oauth token refresh failed",
    "unauthorized", "forbidden", "access denied", "expired",
    "token has expired", /\b401\b/, /\b403\b/,
    "no credentials found", "no api key found",
  ],
  billing: [/\b402\b/, "payment required", "insufficient credits", "credit balance"],
  rateLimit: [/rate[_ ]limit|too many requests|429/, "quota exceeded", "resource_exhausted"],
};
```

### 7.2 FailoverError Class

```typescript
export class FailoverError extends Error {
  readonly reason: FailoverReason;    // "auth" | "billing" | "rate_limit" | "timeout" | "format"
  readonly provider?: string;
  readonly model?: string;
  readonly profileId?: string;
  readonly status?: number;           // HTTP status code
}
```

### 7.3 OAuth Refresh Failure Handling

When OAuth refresh fails:

1. Check if another process already refreshed (race condition mitigation)
2. Try fallback profile via `suggestOAuthProfileIdForLegacyDefault()`
3. For sub-agents, try inheriting from the main agent
4. If all fails, throw with diagnostic hint from `formatAuthDoctorHint()`

---

## 8. Rate Limiting and Retry Logic

### 8.1 Profile Cooldown System

Exponential backoff in `src/agents/auth-profiles/usage.ts`:

```typescript
// Exponential backoff: 1min -> 5min -> 25min -> max 1 hour
export function calculateAuthProfileCooldownMs(errorCount: number): number {
  const normalized = Math.max(1, errorCount);
  return Math.min(60 * 60 * 1000, 60 * 1000 * 5 ** Math.min(normalized - 1, 3));
}
```

**Cooldown progression**: 1 minute -> 5 minutes -> 25 minutes -> 1 hour (max).

### 8.2 Billing Backoff (Separate from Rate Limit)

Billing errors get **longer, configurable backoff**:

```typescript
// Default: 5 hours, doubling up to 24 hours max
// Configurable per-provider via auth.cooldowns.billingBackoffHoursByProvider
function calculateAuthProfileBillingDisableMsWithConfig(params) {
  const raw = baseMs * 2 ** exponent;
  return Math.min(maxMs, raw);
}
```

### 8.3 Failure Window

Error counts reset after a configurable window (default 24 hours):

```typescript
const windowExpired =
  typeof existing.lastFailureAt === "number" &&
  existing.lastFailureAt > 0 &&
  now - existing.lastFailureAt > windowMs;
const baseErrorCount = windowExpired ? 0 : (existing.errorCount ?? 0);
```

### 8.4 Model Fallback

In `src/agents/model-fallback.ts`, the `runWithModelFallback()` function:

1. Resolves fallback model candidates from config
2. For each candidate, checks if **any** auth profile is available (not all in cooldown)
3. Skips providers where all profiles are in cooldown without making an API call
4. Catches `FailoverError` and moves to the next candidate
5. Collects all attempts and reports a summary on total failure

### 8.5 Profile Rotation Order

In `src/agents/auth-profiles/order.ts`, profiles are ordered for rotation:

```
Priority: OAuth > Token > API Key (within each type, oldest-used first for round-robin)

1. Partition profiles into available vs. in-cooldown
2. Sort available: by type (oauth first), then by lastUsed (oldest first)
3. Append cooldown profiles sorted by soonest-to-expire cooldown
4. If user specified preferredProfile, put it first
```

### 8.6 Auth Config Types

```typescript
export type AuthConfig = {
  profiles?: Record<string, AuthProfileConfig>;
  order?: Record<string, string[]>;    // Per-provider profile ordering
  cooldowns?: {
    billingBackoffHours?: number;        // Default: 5
    billingBackoffHoursByProvider?: Record<string, number>;
    billingMaxHours?: number;            // Default: 24
    failureWindowHours?: number;         // Default: 24
  };
};
```

---

## 9. Environment Variables Summary

| Variable | Provider | Purpose |
|----------|----------|---------|
| `ANTHROPIC_API_KEY` | Anthropic | Primary API key |
| `ANTHROPIC_OAUTH_TOKEN` | Anthropic | OAuth token (higher priority than API key) |
| `OPENAI_API_KEY` | OpenAI | API key |
| `GEMINI_API_KEY` | Google | API key |
| `COPILOT_GITHUB_TOKEN` / `GH_TOKEN` / `GITHUB_TOKEN` | GitHub Copilot | GitHub PAT for token exchange |
| `AWS_BEARER_TOKEN_BEDROCK` / `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` / `AWS_PROFILE` | AWS Bedrock | AWS credentials |
| `GROQ_API_KEY` | Groq | API key |
| `XAI_API_KEY` | xAI | API key |
| `OPENROUTER_API_KEY` | OpenRouter | API key |
| `MISTRAL_API_KEY` | Mistral | API key |
| `OPENCLAW_LIVE_ANTHROPIC_KEY` | Anthropic | Force single key |
| `OPENCLAW_LIVE_ANTHROPIC_KEYS` | Anthropic | Comma-separated key list |
| `OPENCLAW_STATE_DIR` | System | Override state directory |
| `OPENCLAW_OAUTH_DIR` | System | Override OAuth directory |
| `OPENCLAW_ANTHROPIC_PAYLOAD_LOG` | Debug | Enable Anthropic payload logging |

---

## 10. Key Files Reference

| File Path | Purpose |
|-----------|---------|
| `src/config/types.models.ts` | ModelProviderConfig, ModelProviderAuthMode types |
| `src/config/types.auth.ts` | AuthConfig, AuthProfileConfig types |
| `src/config/defaults.ts` | Default model aliases, auth mode detection |
| `src/agents/model-auth.ts` | Core: resolveApiKeyForProvider, resolveEnvApiKey, requireApiKey |
| `src/agents/auth-profiles/types.ts` | ApiKeyCredential, TokenCredential, OAuthCredential, AuthProfileStore |
| `src/agents/auth-profiles/store.ts` | Load/save/merge auth profile store with file locking |
| `src/agents/auth-profiles/oauth.ts` | OAuth token resolution and lock-protected refresh |
| `src/agents/auth-profiles/order.ts` | Profile ordering with round-robin and cooldown awareness |
| `src/agents/auth-profiles/usage.ts` | Cooldown tracking, exponential backoff, billing disable |
| `src/agents/auth-profiles/profiles.ts` | CRUD: upsertAuthProfile, listProfilesForProvider |
| `src/agents/auth-profiles/paths.ts` | File path resolution for auth-profiles.json |
| `src/agents/auth-profiles/constants.ts` | Well-known profile IDs, filenames, lock options |
| `src/agents/auth-profiles/external-cli-sync.ts` | Sync from Qwen CLI |
| `src/agents/auth-profiles/session-override.ts` | Per-session profile pinning and rotation |
| `src/agents/auth-profiles/repair.ts` | Profile ID migration (legacy to new format) |
| `src/agents/auth-profiles/doctor.ts` | Auth diagnostic hints |
| `src/agents/cli-credentials.ts` | Claude CLI + Codex CLI + Qwen CLI credential reading |
| `src/agents/live-auth-keys.ts` | Multi-key collection for Anthropic |
| `src/agents/model-fallback.ts` | Model fallback with cooldown-aware provider skipping |
| `src/agents/failover-error.ts` | FailoverError class and error classification |
| `src/agents/pi-embedded-helpers/errors.ts` | Error pattern matching (auth, billing, rate limit) |
| `src/agents/anthropic-payload-log.ts` | Anthropic-specific request/response logging |
| `src/agents/models-config.ts` | Models.json generation with auth profile key injection |
| `src/agents/models-config.providers.ts` | Provider normalization and key backfill |
| `src/providers/github-copilot-token.ts` | Copilot PAT-to-API-token exchange with caching |
| `src/providers/github-copilot-auth.ts` | GitHub device flow OAuth for Copilot |

---

## 11. Key Takeaways for Ora Integration

### What's relevant for Ora (on-device macOS app):

1. **API Key via environment or config file** - Simplest path. Users set `ANTHROPIC_API_KEY` or `OPENAI_API_KEY`, or Ora reads from a local config.
2. **macOS Keychain storage** - OpenClaw reads from Keychain for CLI creds. Ora should store API keys in Keychain (native macOS security) rather than plaintext files.
3. **Credential type abstraction** - The three-type model (API key, token, OAuth) is a good pattern for future-proofing.
4. **Resolution waterfall** - Trying multiple sources (explicit config > keychain > env var > error) is robust.
5. **Error classification** - Distinguishing auth errors from billing from rate limits enables smart retry behavior.
6. **Cooldown with exponential backoff** - Prevents hammering a provider after failures.

### What's NOT relevant for Ora:

- Multi-agent file locking (Ora is a single-process app)
- Profile rotation / multi-key load balancing (Ora uses one key per provider)
- Session overrides (Ora doesn't have the concept of switchable sessions for auth)
- CLI credential sync from Claude Code / Codex (unless Ora wants to piggyback on existing CLI auth)

### Recommended Ora implementation approach:

1. **Store keys in macOS Keychain** using `Security.framework` (SecItemAdd/SecItemCopyMatching)
2. **Define a `ProviderCredential` protocol** with cases for API key and OAuth token
3. **Build a `ProviderAuthResolver`** that checks: explicit config -> Keychain -> environment variable -> prompt user
4. **Classify errors** into auth/billing/rate-limit categories for appropriate UI feedback
5. **Add exponential backoff** on rate limit errors before retrying
