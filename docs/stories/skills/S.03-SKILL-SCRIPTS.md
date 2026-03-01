# S.03 - Skill Scripts

**Epic:** Skills
**Status:** Implemented
**Priority:** P1 (High)
**Estimated Effort:** 7 days
**Dependencies:** S.01 (Skills Runtime), S.06 (Dynamic Tool Discovery)
**Future alignment:** When BG.02 (Worker Abstraction) is implemented, `SkillScriptWorker` should be refactored to conform to the `BackgroundWorker` protocol to inherit XPC/Container isolation. That refactor is out of scope here.
**Target:** macOS 26 (Tahoe)
**Design Reference:** [Anthropic Skills Standard](https://docs.anthropic.com/en/docs/agents-and-tools/skills)

---

## 1. Objective

Enable skills to include executable scripts in their `scripts/` folder that the agent can run to perform custom actions beyond the built-in tools. This extends Ora's capabilities with user-defined automation while maintaining strong security guarantees through a tiered trust model, a shared runtime authorization framework (preflight + execution receipts), comprehensive sandboxing, and full audit logging.

## 2. User Story

As a power user, I want skills to include helper scripts (Python, shell, AppleScript, etc.) that Ora can execute on my behalf, so that I can extend Ora's capabilities with custom automation that integrates with my existing tools and workflows.

## 3. Scope

### In Scope

- `scripts/` folder structure and manifest format
- Script execution via `skills.run_script` tool
- Tiered trust model (bundled auto-approved, user requires consent)
- Script manifest declaring capabilities and arguments
- Sandboxed execution with timeout, output limits
- Environment isolation (controlled env vars, working directory)
- Structured output parsing (JSON support)
- Per-script and per-skill trust management
- Full audit logging with script content hash
- Compatibility with S.06 deferred-tool flow (`skills.run_script` remains discoverable via `tools.discover`)

### Out of Scope

- Installing dependencies for scripts (pip, npm, brew)
- Running scripts in containers/VMs
- Network capability grants (scripts inherit user's network access)
- Persistent state across script runs (scripts are stateless)
- Interactive scripts requiring stdin
- Binary executables (scripts must be text-based with shebang)
- Code signing of scripts (rely on skill-level trust instead)

## 4. Architecture Alignment

### 4.1 Security Model — Tiered Trust

Scripts are **high-risk** because they execute arbitrary code with user privileges. The security model uses tiered trust:

```
┌─────────────────────────────────────────────────────────────────────┐
│                        TRUST HIERARCHY                               │
├─────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  TIER 1: Bundled Skills (Ora.app/Contents/Resources/Skills/)        │
│  ├── Scripts auto-approved (reviewed by Ora team)                   │
│  ├── No per-execution confirmation needed                           │
│  └── Still logged to audit trail                                    │
│                                                                      │
│  TIER 2: Trusted User Skills (user marked as trusted)               │
│  ├── One-time approval when skill is first trusted                  │
│  ├── No per-execution confirmation after trust granted              │
│  ├── Trust can be revoked in Settings                               │
│  └── Script changes invalidate trust (hash mismatch)                │
│                                                                      │
│  TIER 3: Untrusted User Skills (default for new skills)             │
│  ├── Per-execution confirmation required                            │
│  ├── Confirmation shows: script path, arguments, skill source       │
│  └── User can promote to Tier 2 via Settings                        │
│                                                                      │
│  GLOBAL KILL SWITCH                                                  │
│  └── Settings toggle to disable ALL script execution                │
│                                                                      │
└─────────────────────────────────────────────────────────────────────┘
```

### 4.2 Script Manifest Format

Each script should have an accompanying manifest (optional but recommended):

```
skills/my-skill/
├── SKILL.md
├── scripts/
│   ├── manifest.json          # Script registry (optional)
│   ├── fetch_weather.py       # Script file
│   └── send_notification.sh   # Another script
└── references/
```

**manifest.json format:**

```json
{
  "scripts": {
    "fetch_weather.py": {
      "description": "Fetches current weather for a location",
      "arguments": [
        {"name": "location", "type": "string", "required": true, "description": "City name or coordinates"}
      ],
      "output": "json",
      "timeout": 10,
      "capabilities": ["network"]
    },
    "send_notification.sh": {
      "description": "Sends a macOS notification",
      "arguments": [
        {"name": "title", "type": "string", "required": true},
        {"name": "message", "type": "string", "required": true}
      ],
      "output": "text",
      "timeout": 5,
      "capabilities": []
    }
  }
}
```

If no manifest exists, scripts are still executable but with defaults (30s timeout, text output, no declared capabilities).

**Network capability warning:** Unlike BG.03's `URLValidator` which enforces SSRF-safe URL validation for in-process HTTP requests, scripts run as child processes and **bypass all URL validation entirely** — they have full, unrestricted network access. When a script declares `capabilities: ["network"]` in its manifest (or has no manifest), the confirmation dialog must prominently surface this with distinct language:

```
⚠️  This script will have unrestricted network access.
    It can reach any host, including local network services.
```

This warning is shown regardless of the skill's trust level (even trusted skills show it once per script version).

### 4.3 Execution Flow

```
┌─────────────────────────────────────────────────────────────────────┐
│                    SCRIPT EXECUTION FLOW                             │
├─────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  1. Agent calls skills.run_script(skill_id, script, args)          │
│                           │                                          │
│                           ▼                                          │
│  2. ┌─────────────────────────────────────────┐                     │
│     │ TOOLHOST PREFLIGHT (shared for all tools)│                   │
│     │ • Validate schema + args                │                     │
│     │ • Resolve tool auth requirement         │                     │
│     │ • Build single-use execution ticket     │                     │
│     └─────────────────────────────────────────┘                     │
│                           │                                          │
│                           ▼                                          │
│  3. ┌─────────────────────────────────────────┐                     │
│     │ AUTHORIZATION DECISION                  │                     │
│     │ • Auto-allow (bundled/trusted+valid)   │                     │
│     │ • Require user confirmation             │                     │
│     │ • Deny (feature off / invalid state)    │                     │
│     └─────────────────────────────────────────┘                     │
│                           │                                          │
│                           ▼                                          │
│  4. ┌─────────────────────────────────────────┐                     │
│     │ AUTH UI (if required)                   │                     │
│     │ • Show skill/script/args/risk warnings │                     │
│     │ • User selects: Run once / Run+Trust   │                     │
│     │ • Returns signed receipt for ticket    │                     │
│     └─────────────────────────────────────────┘                     │
│                           │                                          │
│                           ▼                                          │
│  5. ┌─────────────────────────────────────────┐                     │
│     │ EXECUTION (receipt required)            │                     │
│     │ • ToolHost verifies ticket + receipt    │                     │
│     │ • Spawn Process with timeout           │                     │
│     │ • Controlled environment variables     │                     │
│     │ • Working dir = skill's scripts/       │                     │
│     │ • Capture stdout/stderr separately     │                     │
│     └─────────────────────────────────────────┘                     │
│                           │                                          │
│                           ▼                                          │
│  6. ┌─────────────────────────────────────────┐                     │
│     │ OUTPUT PROCESSING                       │                     │
│     │ • Enforce output size limit (64KB)     │                     │
│     │ • Parse JSON if output type = json     │                     │
│     │ • Format for LLM consumption           │                     │
│     └─────────────────────────────────────────┘                     │
│                           │                                          │
│                           ▼                                          │
│  7. ┌─────────────────────────────────────────┐                     │
│     │ AUDIT LOG                               │                     │
│     │ • Record: skill, script, args, hash    │                     │
│     │ • Record: exit code, truncated output  │                     │
│     │ • Record: auth mode + user decision    │                     │
│     │ • Record: execution time               │                     │
│     └─────────────────────────────────────────┘                     │
│                                                                      │
└─────────────────────────────────────────────────────────────────────┘
```

### 4.4 Environment Isolation

Scripts run with a controlled environment:

```swift
struct ScriptEnvironment {
    // Inherited from user (read-only)
    let HOME: String
    let USER: String
    let PATH: String  // See allowlist below
    let LANG: String
    let TZ: String

    // Ora-provided context
    let ORA_SKILL_ID: String
    let ORA_SKILL_ROOT: String
    let ORA_SCRIPT_NAME: String
    let ORA_REQUEST_ID: String

    // Explicitly NOT inherited
    // - API keys, tokens, credentials (any var matching *TOKEN*, *KEY*, *SECRET*, *PASSWORD*)
    // - SSH_AUTH_SOCK, SSH_AGENT_PID
    // - AWS_*, GOOGLE_*, AZURE_*, GITHUB_*
    // - Everything else not listed above
}
```

**PATH allowlist** — built at runtime, including only paths that exist:

```
/usr/bin
/bin
/usr/sbin
/sbin
/usr/local/bin     (included if directory exists — standard Homebrew on Intel)
/opt/homebrew/bin  (included if directory exists — standard Homebrew on Apple Silicon)
```

This lets system interpreters (`python3`, `node`, `ruby`) and Homebrew-installed tools work without exposing user-specific paths like `~/.local/bin` or custom `PATH` modifications.

### 4.5 Supported Script Types & Shebang Validation

| Type | Shebang Example | Extension Fallback |
|:-----|:----------------|:-------------------|
| Bash | `#!/bin/bash` | `.sh` |
| Zsh | `#!/bin/zsh` | `.zsh` |
| Python 3 | `#!/usr/bin/env python3` | `.py` |
| AppleScript | `#!/usr/bin/osascript` | `.scpt`, `.applescript` |
| Ruby | `#!/usr/bin/env ruby` | `.rb` |
| Node.js | `#!/usr/bin/env node` | `.js`, `.mjs` |

**Shebang parsing rules** (implemented in `ScriptSandbox.parseShebang(at:)`):

1. Read first line of script file; strip `\r` (handle CRLF)
2. Line must start with `#!` — otherwise reject with `.invalidShebang`
3. Max shebang line length: 256 characters — reject longer lines
4. Extract interpreter: everything after `#!`, trimmed
5. Two forms are supported:
   - **Direct path**: `#!/bin/bash` — interpreter is `/bin/bash`. Must exist on disk.
   - **`env` indirection**: `#!/usr/bin/env python3` — resolve `python3` against the PATH allowlist. `/usr/bin/env` itself must exist; reject any other form of `env` path.
6. **Reject** `#!/usr/bin/env -S ...` (env with flags) — too complex, potential bypass vector
7. Resolved interpreter must exist on disk — if not, return `.interpreterNotFound` with the interpreter name so the error message can suggest installing it
8. Extension-only detection (no shebang): use the fallback table above to infer interpreter — but this path is only taken if the file has no first-line `#!` at all

### 4.6 Tool Schema

```
name:        skills.run_script
kind:        .read
loadPolicy:  .deferred
authz:       dynamic (resolved by ToolHost preflight + script trust policy)
description: Run a script from a skill's scripts/ folder. Call skills.load()
             first to see available scripts and their required arguments.

parameters:
  skill_id  String  required  The skill ID containing the script (e.g. "weather-helper")
  script    String  required  Script filename relative to scripts/ (e.g. "fetch_weather.py")
  args      [String] optional Positional arguments. Refer to the skill's SKILL.md for
                              required arguments. Default: []

returns:
  exit_code        Int     Process exit code (0 = success)
  stdout           String  Captured stdout (truncated at 64KB)
  stderr           String  Captured stderr (truncated at 64KB)
  execution_time_ms Int    Wall clock time in milliseconds
  truncated        Bool    True if stdout was truncated
```

### 4.7 Argument Passing

Arguments are passed as **positional command-line arguments** via `Process.arguments`:

```swift
process.executableURL = URL(fileURLWithPath: interpreter)
process.arguments = [resolvedScript.path] + arguments
// e.g. ["/path/to/scripts/fetch_weather.py", "San Francisco"]
```

`Process.arguments` is an array — no shell is involved, so there is no injection risk from argument values. Arguments are passed verbatim.

The LLM learns what arguments a script expects from the SKILL.md content (loaded via `skills.load`). Skill authors **must** document available scripts and their arguments in the SKILL.md. Bundled skills must follow this requirement.

### 4.8 Tool Authorization Framework (Proper Implementation)

This story introduces a **shared authorization layer** in runtime execution, not tool-specific UI logic:

- `ToolHost` adds a preflight API that returns either:
  - execution can proceed immediately, or
  - execution requires user authorization with a structured prompt payload, or
  - execution is denied.
- Preflight issues a single-use execution ticket. Actual execution must present a matching authorization receipt.
- `AgentLoop` must run preflight on **every** tool path (`tool_call` and confirmed proposals). It may no longer execute tools directly with a blanket `confirmed: true`.
- If the LLM emits `tool_call` for a mutate tool, runtime fails closed: convert to proposal/authorization request and require user confirmation.
- `SkillsRunScriptTool` supplies policy data (trust level, hash status, capability warnings) but does not own confirmation UI dispatch.

This makes script auth robust and also closes a broader guardrail gap for any misformatted model output.

### 4.9 Script Authorization Policy (Built on Shared Framework)

`skills.run_script` remains `kind = .read`, but preflight authorization is dynamic:

- **Bundled skill + valid script**: auto-allow
- **Trusted user skill + matching hashes**: auto-allow (show network warning once per script hash when applicable)
- **Untrusted user skill**: require user authorization dialog
- **Hash mismatch or trust record missing**: downgrade to untrusted and require authorization
- **Global scripts-disabled toggle**: deny preflight

Authorization dialog actions:
- `Run once` (grant receipt for this ticket only)
- `Run and trust this skill` (grant receipt + persist trust hashes)
- `Cancel`

### 4.10 Integration with Existing Patterns

**Standalone actor — no BG.02 dependency now:**
- `SkillScriptWorker` is a standalone `actor` using `Foundation.Process` directly
- Scripts are synchronous from the agent's perspective — `SkillsRunScriptTool` awaits inline
- Future: when BG.02 is built, align `SkillScriptWorker` with `BackgroundWorker` protocol to gain XPC/Container isolation without changing call sites

**Audit Logging:**
- Extend `AuditCategory` with `.scriptExecution`
- Log: skill, script filename, args (redacted if sensitive), SHA-256 hash of script file, trust level, authorization decision, exit code, execution time

**ToolRegistry:**
- Register `skills.run_script` alongside other skills tools
- Keep `skills.run_script` on default `loadPolicy = .deferred` (do not mark as core)

## 5. Implementation Plan (Draft)

### 5.1 Files to Create

| File | Purpose |
|:-----|:--------|
| `Ora/Tools/ToolAuthorization.swift` | Shared authorization models: preflight requirement, authorization prompt payload, execution ticket, authorization receipt |
| `Ora/Skills/ScriptManifest.swift` | Parse and validate `scripts/manifest.json`; defaults when manifest absent |
| `Ora/Skills/SkillScriptWorker.swift` | Standalone `actor`; `Foundation.Process` spawning, stdout/stderr capture, timeout + SIGTERM/SIGKILL, output truncation. Future: refactor to conform to `BackgroundWorker` (BG.02) for XPC/Container isolation. |
| `Ora/Skills/ScriptEnvironment.swift` | Build filtered env dict from allowlist; inject `ORA_*` context vars |
| `Ora/Skills/ScriptTrustManager.swift` | Trust levels (bundled/trusted/untrusted), SHA-256 hash tracking, revocation; persists via SwiftData `ScriptTrustRecordModel` |
| `Ora/Skills/ScriptSandbox.swift` | Path validation (no traversal, must be inside `scripts/`), shebang parsing per spec in §4.5, size limit enforcement |
| `Ora/Skills/ScriptAuthorizationPolicy.swift` | Maps trust state + script metadata to preflight authorization requirements for `skills.run_script` |
| `Ora/Tools/Skills/SkillsRunScriptTool.swift` | `kind = .read`; validates args, delegates authorization policy, calls `SkillScriptWorker.run()`, writes script audit fields |
| `Ora/Persistence/Models/ScriptTrustRecordModel.swift` | SwiftData model for per-skill trust state and script hash map |

### 5.2 Files to Modify

| File | Change |
|:-----|:-------|
| `Ora/Tools/ToolProtocol.swift` | Add optional async authorization-preflight hook with default behavior (mutate => requires confirmation, read => no confirmation) |
| `Ora/Tools/ToolHost.swift` | Add preflight + ticket/receipt execution flow; reject execution without valid authorization receipt when required |
| `Ora/Orchestration/AgentLoop.swift` | Run preflight in `tool_call` path; convert unauthorized calls into proposal flow; execute via authorized ticket instead of blanket `confirmed: true` |
| `Ora/Orchestration/SimplePipelineController+Agent.swift` | Handle authorization prompt payload and user decision mapping (`run once`, `run+trust`, `cancel`) |
| `Ora/Overlay/OverlayState.swift` | Extend proposal state to carry authorization prompt metadata |
| `Ora/Overlay/ToolStateView.swift` | Render optional script trust action in proposal UI when prompt payload requests it |
| `Ora/Tools/ToolRegistry.swift` | Register `skills.run_script` tool (deferred) |
| `Ora/Persistence/AuditLogEntry.swift` | Add `.scriptExecution` case to `AuditCategory` enum |
| `Ora/Persistence/AuditLogger.swift` | Add `recordScriptExecution()` method |
| `Ora/Persistence/PersistenceManager.swift` | Add CRUD helpers for `ScriptTrustRecordModel` fetch/upsert/delete |
| `Ora/Preferences/Tabs/SkillsPreferencesView.swift` | Add script settings section |
| `Ora/Skills/SkillStore.swift` | Expose script manifest info |
| `Ora/Skills/SkillMetadata.swift` | Add `hasScripts: Bool` field |
| `OraTests/Tools/ToolDiscoveryTests.swift` | Verify `tools.discover` surfaces `skills.run_script` when requested |

### 5.3 Tests to Add

| File | Coverage |
|:-----|:---------|
| `OraTests/Tools/ToolAuthorizationTests.swift` | Preflight classification, ticket/receipt validation, stale/replayed receipt rejection |
| `OraTests/Skills/ScriptManifestTests.swift` | Manifest parsing, validation, defaults |
| `OraTests/Skills/SkillScriptWorkerTests.swift` | Execution, timeout, output capture, signals; uses mock scripts in a temp directory |
| `OraTests/Skills/ScriptEnvironmentTests.swift` | Env filtering, Ora context injection |
| `OraTests/Skills/ScriptTrustManagerTests.swift` | Trust levels, hash validation, revocation |
| `OraTests/Skills/ScriptSandboxTests.swift` | Path validation, shebang parsing, size limits |
| `OraTests/Skills/SkillsRunScriptToolTests.swift` | Script tool policy + execution flow with mocks; no in-tool confirmation dispatch |

### 5.4 Dependencies/Config

- No new Swift package dependencies
- Uses Foundation `Process` API for execution
- Uses `CryptoKit` for SHA-256 hashing (already available)

## 6. Acceptance Criteria

### Script Discovery & Validation

- [ ] AC-1: Skills can include `scripts/` folder with executable text files
- [ ] AC-2: Scripts must have valid shebang or recognized extension
- [ ] AC-3: Optional `manifest.json` declares script metadata
- [ ] AC-4: Skills with scripts show indicator in Settings skill list
- [ ] AC-5: Path traversal outside `scripts/` is rejected

### Trust Model

- [ ] AC-6: Bundled skills' scripts auto-authorize and execute without user prompt
- [ ] AC-7: Untrusted user skills require explicit user authorization before execution
- [ ] AC-8: User can mark a skill as "trusted" in Settings and via the script authorization dialog
- [ ] AC-9: Trusted skill scripts execute without prompt when hashes match (subject to AC-10)
- [ ] AC-10: Script content changes (hash mismatch) revoke trust automatically and downgrade to untrusted
- [ ] AC-11: Global toggle disables all script execution at preflight stage

### Authorization Framework (Cross-Tool Guardrail)

- [ ] AC-12: Every tool execution path (`tool_call`, confirmed proposal) runs through `ToolHost` authorization preflight before execution
- [ ] AC-13: Runtime no longer relies on a blanket `confirmed: true` for direct `tool_call` execution
- [ ] AC-14: If the model emits `tool_call` for a mutate tool, runtime must fail closed: return proposal/authorization request and require user confirmation
- [ ] AC-15: Authorization-required executions use single-use ticket + receipt validation; stale/replayed receipts are rejected
- [ ] AC-16: `skills.run_script` uses the shared authorization framework (policy-only tool, no tool-owned confirmation UI dispatch)

### Execution

- [ ] AC-17: `skills.run_script` remains `kind = .read`, keeps `loadPolicy = .deferred`, and remains discoverable via `tools.discover`
- [ ] AC-18: `skills.run_script` executes scripts via `Foundation.Process` (no shell intermediary)
- [ ] AC-19: Arguments are passed as positional command-line args via `Process.arguments` — no shell interpolation, values passed verbatim
- [ ] AC-20: Scripts run with controlled environment variables (filtered per §4.4 allowlist)
- [ ] AC-21: Working directory is skill's `scripts/` folder
- [ ] AC-22: Default timeout is 30 seconds, configurable per-script in manifest
- [ ] AC-23: SIGTERM sent on timeout, SIGKILL after 5s grace period
- [ ] AC-24: Exit codes are captured and returned to agent
- [ ] AC-25: Scripts declaring `capabilities: ["network"]` in manifest (or with no manifest) display a network warning in the authorization dialog — even for trusted skills, once per script version (hash-keyed)

### Output Handling

- [ ] AC-26: stdout and stderr captured separately
- [ ] AC-27: Output truncated at 64KB with indicator
- [ ] AC-28: JSON output parsed and returned as structured data
- [ ] AC-29: Non-zero exit code returns error with stderr

### Audit & Logging

- [ ] AC-30: All script executions logged to audit trail
- [ ] AC-31: Audit includes: skill, script, args, SHA-256 hash of script file, trust level, authorization decision, exit code
- [ ] AC-32: Audit includes: execution time and whether authorization was interactive vs auto-allow

### Settings UI

- [ ] AC-33: Script execution toggle in Skills preferences
- [ ] AC-34: Per-skill trust management (trust/revoke)
- [ ] AC-35: View script trust status and stored hashes
- [ ] AC-36: Trust records persist in dedicated SwiftData `ScriptTrustRecordModel` rows (not `AppSettings` JSON blob)

## 7. Verification Plan

### Automated Tests

- [ ] Unit tests for shared authorization models (requirement mapping, ticket issuance, receipt validation, replay rejection)
- [ ] Unit tests for `AgentLoop` fail-closed behavior when mutate tools are emitted as `tool_call`
- [ ] Unit tests for manifest parsing (valid, invalid, missing)
- [ ] Unit tests for shebang validation — edge cases:
  - CRLF-terminated first line is stripped and parsed correctly
  - `#!/usr/bin/env -S python3` is rejected (env with flags)
  - Direct path to non-existent interpreter returns `.interpreterNotFound`
  - Shebang line exceeding 256 chars is rejected
  - File with no `#!` on first line uses extension fallback table
  - Non-`/usr/bin/env` env path (e.g., `/opt/homebrew/bin/env`) is rejected
- [ ] Unit tests for environment filtering
- [ ] Unit tests for trust manager (grant, revoke, hash check)
- [ ] Unit tests for trust-record persistence lifecycle (`ScriptTrustRecordModel` upsert/fetch/delete)
- [ ] Unit tests for path sandboxing
- [ ] Unit tests for script authorization policy (bundled/trusted/untrusted, hash mismatch, network warning rules)
- [ ] Unit tests for output truncation and JSON parsing
- [ ] Unit tests for timeout and signal handling
- [ ] Unit tests for `tools.discover` ranking/visibility of `skills.run_script`
- [ ] Integration test for full execution flow with mock script

### Manual Tests

- [ ] Execute a bundled skill script, verify no confirmation prompt
- [ ] Execute an untrusted user script, verify confirmation appears
- [ ] Trigger a script run and choose "Run and trust this skill"; verify current run executes and future runs auto-authorize
- [ ] Trust a skill, verify subsequent scripts run without confirmation
- [ ] Modify a trusted script, verify trust is revoked
- [ ] Force a mutate tool output as `tool_call` in a test harness, verify runtime requests authorization instead of executing directly
- [ ] Test timeout with a `sleep 60` script
- [ ] Test output truncation with a script that prints 100KB
- [ ] Test JSON output parsing with a Python script
- [ ] Disable scripts globally, verify tool returns error
- [ ] From a fresh session, request script execution and verify agent can discover `skills.run_script` via `tools.discover` before first use
- [ ] Verify audit log contains all expected fields

## 8. Performance / Reliability Considerations

### Targets

| Metric | Target |
|:-------|:-------|
| Script startup overhead | < 50ms |
| Default timeout | 30 seconds |
| Grace period after SIGTERM | 5 seconds |
| Max output size | 64 KB |
| Max concurrent scripts | 1 (sequential execution) |

### Failure Modes

| Failure | Handling |
|:--------|:---------|
| Script not found | Return error to agent |
| Invalid shebang | Return error with guidance |
| Timeout | SIGTERM, then SIGKILL, return timeout error |
| Non-zero exit | Return error with stderr content |
| Output too large | Truncate with `[truncated]` marker |
| Interpreter missing | Return error suggesting install |

### Resource Protection

- Scripts run as child processes (isolated from Ora)
- Timeout prevents runaway scripts
- Output limits prevent memory exhaustion
- Sequential execution prevents fork bombs

## 9. Risks & Mitigations

| Risk | Likelihood | Impact | Mitigation |
|:-----|:-----------|:-------|:-----------|
| Malicious user script | Medium | High | Tiered trust, confirmation, audit |
| Resource exhaustion | Low | Medium | Timeout, output limits, sequential |
| Path traversal | Low | High | Strict sandboxing, canonical paths |
| Credential theft via env | Medium | High | Filter sensitive env vars |
| Script tampering | Low | High | Hash-based trust invalidation |
| Guardrail bypass from malformed `tool_call` output | Medium | High | Shared ToolHost preflight + fail-closed mutate handling + ticket/receipt validation |
| Interpreter vulnerabilities | Low | Medium | Use system interpreters, user's responsibility |

## 10. Open Questions

- ~~Which scripting languages to support?~~ **Resolved:** Any with valid shebang
- ~~Should scripts declare required capabilities?~~ **Resolved:** Optional via manifest
- How to handle scripts that need dependencies (pip, brew)? **Defer to documentation**
- Should we support script-to-script calls within a skill? **Defer**
- Should we add a "dry run" mode that shows what would execute? **Consider for UX**

---

## Implementation Order

All three layers ship together as part of this story. Recommended build order within the sprint:

### Layer 1: Shared Authorization Foundation
Add `ToolAuthorization` models, `ToolProtocol` preflight hook, `ToolHost` ticket/receipt execution flow, and `AgentLoop` fail-closed behavior for mutate `tool_call` outputs. At this point, existing mutate tools still function but now through explicit authorization checks.

### Layer 2: Script Execution + Policy
Build `SkillScriptWorker`, `ScriptEnvironment`, `ScriptSandbox`, `ScriptManifest`, and `ScriptAuthorizationPolicy`. Implement `SkillsRunScriptTool` as policy + execution only (no in-tool confirmation UI). Add `ScriptTrustRecordModel`, `ScriptTrustManager`, and persistence helpers.

### Layer 3: UI + Settings + Audit Polish
Extend proposal UI for script-specific authorization actions (`run once`, `run+trust`), add script settings section to `SkillsPreferencesView`, and finish script-specific audit fields.

**All acceptance criteria (AC-1 through AC-36) must pass before the story is considered complete.**

---

## Implementation Details

### Tool Authorization Contracts

```swift
enum ToolAuthorizationRequirement: Sendable {
    case none
    case userConfirmation(prompt: ToolAuthorizationPrompt)
}

struct ToolAuthorizationPrompt: Sendable {
    let title: String
    let summary: String
    let details: String?
    let allowsTrustGrant: Bool
}

struct ToolExecutionTicket: Sendable {
    let id: UUID
    let toolName: String
    let args: [String: JSONValue]
}

enum ToolAuthorizationDecision: Sendable {
    case approveOnce
    case approveAndTrust
    case deny
}
```

`ToolHost` owns ticket issuance and receipt verification. `AgentLoop` and UI only pass decisions; they do not bypass authorization with raw booleans.

### SkillScriptWorker Actor

`SkillScriptWorker` is responsible only for **execution mechanics** — path resolution, shebang parsing, env building, spawning the process, capturing output, and enforcing the timeout. Authorization decisions are handled upstream by `ToolHost` preflight and `ScriptAuthorizationPolicy`.

```swift
/// Standalone actor for script execution. No authorization logic here.
/// Authorization decisions are made by ToolHost preflight + ScriptAuthorizationPolicy
/// before calling run().
/// Future: refactor to conform to BackgroundWorker (BG.02) for XPC/Container isolation.
public actor SkillScriptWorker {

    public struct ScriptResult: Sendable {
        public let exitCode: Int32
        public let stdout: String
        public let stderr: String
        public let executionTimeMs: Int
        public let truncated: Bool
    }

    public enum ScriptError: Error {
        case scriptNotFound(String)
        case invalidShebang(String)
        case interpreterNotFound(String)
        case timeout(TimeInterval)
        case executionFailed(Int32, String)
        case outputTooLarge
        case pathTraversal
        case scriptsDisabled
    }

    private let sandbox: ScriptSandbox
    private let maxOutputBytes = 64 * 1024
    private let defaultTimeout: TimeInterval = 30
    private let killGracePeriod: TimeInterval = 5

    public func run(
        skillID: String,
        skillRoot: URL,
        scriptPath: String,
        arguments: [String]
    ) async throws -> ScriptResult {
        // 1. Validate path (no traversal, must be inside scripts/)
        let resolvedScript = try sandbox.resolve(skillRoot: skillRoot, scriptPath: scriptPath)

        // 2. Parse shebang and validate interpreter exists on disk
        let interpreter = try sandbox.parseShebang(at: resolvedScript)

        // 3. Build filtered environment
        let env = ScriptEnvironment.build(
            skillID: skillID,
            skillRoot: skillRoot,
            scriptName: resolvedScript.lastPathComponent
        )

        // 4. Execute with timeout
        return try await executeWithTimeout(
            interpreter: interpreter,
            script: resolvedScript,
            arguments: arguments,
            workingDirectory: resolvedScript.deletingLastPathComponent(),
            environment: env.asDictionary()
        )
    }

    private func executeWithTimeout(
        interpreter: String,
        script: URL,
        arguments: [String],
        workingDirectory: URL,
        environment: [String: String]
    ) async throws -> ScriptResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: interpreter)
        process.arguments = [script.path] + arguments   // positional, no shell
        process.currentDirectoryURL = workingDirectory
        process.environment = environment
        // stdout/stderr pipe setup, async read with output size enforcement,
        // timeout watchdog with SIGTERM then SIGKILL after killGracePeriod...
    }
}
```

### ScriptTrustManager

```swift
public actor ScriptTrustManager {

    public enum TrustLevel: Sendable {
        case bundled      // Auto-approved
        case trusted      // User approved, hash matches
        case untrusted    // Requires per-execution confirmation
    }

    // Trust records persisted in SwiftData ScriptTrustRecordModel rows.
    private let persistenceManager: PersistenceManager

    public func trustLevel(for skillID: String) async -> TrustLevel {
        // Check if bundled
        // Check persisted trust row + hash validation
        // Default to untrusted
    }

    public func grantTrust(skillID: String, scripts: [URL]) async {
        // Compute hashes, store record, persist via PersistenceManager SwiftData helpers
    }

    public func revokeTrust(skillID: String) async {
        // Remove trusted record via PersistenceManager SwiftData helpers
    }

    public func validateHashes(skillID: String) async -> Bool {
        // Recompute hashes, compare with stored; revoke automatically on mismatch
    }
}
```

**Persistence note:** Trust records survive app restarts. They are stored as dedicated SwiftData `ScriptTrustRecordModel` rows (one row per trusted skill, including hash map metadata). `ScriptTrustManager` reads/writes via `PersistenceManager` helper methods on every `grantTrust` / `revokeTrust` / hash-validation update.

### Confirmation Dialog Content

When confirmation is required, show:

```
┌─────────────────────────────────────────────────────┐
│  Run Script?                                        │
├─────────────────────────────────────────────────────┤
│                                                     │
│  Skill:    weather-helper (User-installed)         │
│  Script:   fetch_weather.py                        │
│  Args:     ["San Francisco"]                       │
│                                                     │
│  This script will run with your user permissions.  │
│                                                     │
│  ┌─────────────────────────────────────────────┐   │
│  │ ☐ Trust all scripts from this skill         │   │
│  └─────────────────────────────────────────────┘   │
│                                                     │
│           [ Cancel ]         [ Run Script ]        │
│                                                     │
└─────────────────────────────────────────────────────┘
```

---

## Implementation Summary

**Date:** 2026-02-28
**Implemented by:** Codex

### Outcome

- Added shared `ToolHost` authorization preflight with single-use tickets and receipts.
- Added `skills.run_script` as a deferred tool with script sandboxing, manifest parsing, filtered environment setup, timeout handling, stdout/stderr capture, JSON output parsing, trust persistence, and audit logging.
- Extended the overlay confirmation UI and Skills preferences so script runs can be approved once, approved and trusted, or revoked later.
- Added SwiftData-backed `ScriptTrustRecordModel` storage and Skills docs updates for `scripts/` authoring.

### Verification

- `./build.sh` — passed
- Targeted tests passed via `xcodebuild test` for:
  - `AgentLoopTests`
  - `ToolAuthorizationTests`
  - `ScriptManifestTests`
  - `ScriptEnvironmentTests`
  - `ScriptSandboxTests`
  - `ScriptTrustManagerTests`
  - `SkillScriptWorkerTests`
  - `SkillsRunScriptToolTests`
  - `ToolDiscoveryTests`
- `./build.sh test` compiled and ran, but the full suite still has unrelated pre-existing audio playback failures (`AudioPlaybackServiceTests`) in this environment.

## Code Review Findings

**Reviewer:** Claude Sonnet 4.6
**Date:** 2026-03-01
**Commit reviewed:** 58ec6e2

### Summary
- Files reviewed: 47 changed files (9 new, 38 modified)
- Build status: Pass (pre-review)
- Tests run: targeted suite per implementation summary

---

### Issues Found

#### P0 — Critical (must fix before merge)

- [ ] **`SkillScriptWorker.swift:173-183` — Unbounded memory accumulation in `readAllBytes`**
  `readAllBytes` accumulates ALL bytes from the pipe into a `Data` before `truncate()` is called. A script printing gigabytes of output will grow the buffer without bound, crashing Ora with OOM before the 64KB limit is ever applied. The size check must happen *during* the read loop, not after. Example fix: break from `handle.bytes` once accumulated size exceeds `maxOutputBytes + 1` and set a truncation flag, then pass the already-capped buffer to the caller. (Also: iterating `handle.bytes` byte-by-byte is O(n) async steps — for 64KB that is 65,536 continuation suspensions; prefer `read(upToCount:)` in a loop.)

- [ ] **`SkillScriptWorker.swift:89-96` — stdout/stderr Tasks leak if `process.run()` throws**
  `stdoutTask` and `stderrTask` are started *before* `process.run()`. If `process.run()` throws (e.g., interpreter exists on disk but is not executable — see P1-3), no process ever writes to the pipes. The tasks block in `handle.bytes` indefinitely until the `Pipe` objects are garbage-collected. There is no cleanup path around the `try process.run()` call. A `do/catch` wrapping `process.run()` should close both pipe read ends and cancel/await both tasks on failure.

#### P1 — Major (should fix before merge)

- [ ] **`ScriptSandbox.swift:18-20` — Symlink traversal: `standardizedFileURL` does not resolve symlinks**
  Both `scriptsRoot` and `candidate` are computed with `.standardizedFileURL`, which removes `.` and `..` components but does NOT follow symlinks. A user-installed skill can place `scripts/evil.sh` as a symlink pointing to an arbitrary file outside the skill root (e.g., `/tmp/exploit.sh`). The path-containment guard passes (the symlink path is inside `scripts/`), but the executed interpreter target is the symlink destination. The authorization dialog shows the symlink path, not the real path. Fix: use `.resolvingSymlinksInPath()` on both `scriptsRoot` and `candidate`, and re-verify containment on the resolved paths.

- [ ] **`SkillsRunScriptTool.swift:75-77` vs `137-139` — TOCTOU: script can change between authorization and execution**
  The script SHA-256 is computed in `authorizationPlan()` during preflight and stored in `context["script_hash"]`. Actual execution happens seconds later in `execute()`, which recomputes the hash independently. There is no check that the hash computed at execution matches the hash that was authorized. A trusted skill's script modified in the gap between `authorizationPlan` and `execute` will run the new version — bypassing the hash-based trust check that should have required re-authorization. Fix: read `context["script_hash"]` in `execute()`, recompute the live hash, and refuse to execute if they differ (throw a clear error directing the user to re-run).

- [ ] **`SkillScriptWorker.swift:160-171` — TOCTOU race in `awaitTermination` → potential hang**
  `withCheckedContinuation` checks `process.isRunning`, then sets `process.terminationHandler`. These two operations are not atomic. If the process exits between the check and the handler assignment, the handler is never called and the continuation is never resumed — the `awaitTermination` call hangs forever, blocking the actor and the entire sequential-execution guarantee. Standard fix: set the `terminationHandler` *first*, then check `isRunning` and immediately resume the continuation if the process has already exited.

- [ ] **`ScriptSandbox.swift:129` — `isExecutableFile || fileExists` allows non-executable interpreters through preflight**
  For direct-path shebangs (`#!/bin/bash`, etc.) the guard is:
  ```swift
  guard FileManager.default.isExecutableFile(atPath: trimmed)
        || FileManager.default.fileExists(atPath: trimmed) else { … }
  ```
  The `|| fileExists` arm passes non-executable files (e.g., a file with `644` permissions). The sandbox returns a non-executable path as the interpreter. `process.run()` then fails at launch time — triggering P0-2. The correct check is `isExecutableFile` alone (which already implies existence on macOS). Remove the `|| fileExists` branch.

- [ ] **Missing `ScriptAuthorizationPolicyTests`**
  The verification plan explicitly requires "Unit tests for script authorization policy (bundled/trusted/untrusted, hash mismatch, network warning rules)." No `ScriptAuthorizationPolicyTests.swift` was delivered. `SkillsRunScriptToolTests` covers bundled auto-allow and untrusted prompt cases but does not cover: (a) trusted skill with matching hash auto-allows, (b) trusted skill with hash mismatch falls back to untrusted prompt, (c) network warning shown when manifest absent, (d) network warning suppressed after acknowledgment. These scenarios are testable with mock/stub `ScriptTrustManager` and `ScriptSandbox`.

---

#### P2 — Minor (can fix in follow-up)

- [ ] **`ScriptSandbox.swift:136-147` — `resolveCommand` does not reject command names containing `/`**
  If a shebang is `#!/usr/bin/env ../../opt/homebrew/bin/python3`, `parts[1]` = `../../opt/homebrew/bin/python3` is passed to `resolveCommand`. `URL.appendingPathComponent("../../opt/homebrew/bin/python3")` constructs a path that resolves outside the allowlisted directory. `fileExists` passes, the escaped path is returned as the interpreter. The kernel won't execute a non-executable file, so practical harm is low, but it violates the allowlist invariant. Fix: guard that `command` contains no `/`.

- [ ] **`ScriptManifest.swift:63` — No file-size limit on `manifest.json`**
  `Data(contentsOf: manifestURL)` loads the entire file. `ScriptSandbox.maxScriptFileBytes` (100 KB) guards script files but there is no analogous limit for the manifest. Add a size check (suggest same 100 KB cap) before calling `Data(contentsOf:)`.

- [ ] **`ScriptSandbox.swift:33-35` — `manifest.json` rejection throws misleading `.pathTraversal`**
  Attempting to execute `manifest.json` as a script throws `ScriptSandboxError.pathTraversal(scriptPath)`. Semantically this is wrong — `manifest.json` is not a traversal attempt, it's an invalid script target. Change to `ScriptSandboxError.scriptNotFound(scriptPath)` with a descriptive message like `"manifest.json is not executable"`.

- [ ] **`ToolAuthorization.swift:13,40` — `issuedAt` field on ticket and receipt is never read**
  Both `ToolExecutionTicket` and `ToolAuthorizationReceipt` store `issuedAt: Date` but no expiration check exists anywhere. Either add an expiry guard in `executeAuthorized` (e.g., reject tickets older than 5 minutes) or remove the field to eliminate dead code and avoid confusion.

- [ ] **`ToolHost.swift:93-121` — `executeWithAudit(confirmed:)` legacy path can auto-approve any mutate tool**
  If `confirmed: true` is passed to `executeWithAudit`, any tool that returns `.requiresUser` from preflight is silently auto-approved with `approveOnce`. This path is not used by `AgentLoop.runLoop()` (which now goes through `preflight + executeAuthorized` correctly), but the API remains callable. It is a footgun that contradicts AC-13. Consider either removing it or adding an assertion/precondition that `confirmed` is only valid for tools with `authorizationPlan == .none`.

- [ ] **`ScriptTrustManagerTests.swift:27,33` / `SkillsRunScriptToolTests.swift:51-56` — Tests mutate `PersistenceManager.shared` (production singleton)**
  `clearScriptTrustRecords()` and `updateSettings()` are called on the shared production manager. If tests run in a context where the production store is present (common in local dev), this silently modifies production data. The trust-manager and run-script-tool tests should use `PersistenceManager.createForTesting(inMemory: true)` and inject it through the `ScriptTrustManager`/`SkillsRunScriptTool` initializers. This requires making `ScriptTrustManager.init(sandbox:persistenceManager:)` accept a `PersistenceManager` parameter (currently the actor hard-codes `PersistenceManager.shared` via `MainActor.run`).

---

### Future Considerations (Out of Scope)

- `AuditLogger.recordSuccess` / `recordFailure` (pre-existing): O(n) scan over up to 1000 entries to find the entry by ID on every tool completion. Pre-existing; not introduced by S.03.
- No ticket expiry: confirmed-but-never-executed tickets accumulate in `pendingAuthorizations` indefinitely. Low risk (one ticket per tool call, short-lived sessions), but worth revisiting if session durations grow.

---

### Approval Status

- [x] All P0 issues resolved (commit e3b4dd3)
- [x] All P1 issues resolved (commit e3b4dd3)
- [x] Coverage gaps addressed (ScriptAuthorizationPolicyTests — 7 tests added)
- [x] Ready for merge

## Completion Status

- [x] Implementation complete
- [x] Build passes
- [x] Full suite green (1464/1464 tests pass — 2026-03-01)
- [x] Code review P0/P1 issues resolved (commit e3b4dd3)
- [ ] PR / merge metadata pending
