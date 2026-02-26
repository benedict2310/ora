# S.03 - Skill Scripts

**Epic:** Skills
**Status:** Not Started
**Priority:** P1 (High)
**Estimated Effort:** 6 days
**Dependencies:** S.01 (Skills Runtime), S.06 (Dynamic Tool Discovery)
**Future alignment:** When BG.02 (Worker Abstraction) is implemented, `SkillScriptWorker` should be refactored to conform to the `BackgroundWorker` protocol to inherit XPC/Container isolation. That refactor is out of scope here.
**Target:** macOS 26 (Tahoe)
**Design Reference:** [Anthropic Skills Standard](https://docs.anthropic.com/en/docs/agents-and-tools/skills)

---

## 1. Objective

Enable skills to include executable scripts in their `scripts/` folder that the agent can run to perform custom actions beyond the built-in tools. This extends Ora's capabilities with user-defined automation while maintaining strong security guarantees through a tiered trust model, explicit consent, comprehensive sandboxing, and full audit logging.

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
│     │ VALIDATION                              │                     │
│     │ • Script exists in skill's scripts/    │                     │
│     │ • Path has no traversal (..)           │                     │
│     │ • File is text with valid shebang      │                     │
│     │ • Arguments match manifest (if exists) │                     │
│     └─────────────────────────────────────────┘                     │
│                           │                                          │
│                           ▼                                          │
│  3. ┌─────────────────────────────────────────┐                     │
│     │ TRUST CHECK                             │                     │
│     │ • Bundled skill? → Auto-approved        │                     │
│     │ • Trusted user skill? → Check hash      │                     │
│     │ • Untrusted? → Require confirmation     │                     │
│     └─────────────────────────────────────────┘                     │
│                           │                                          │
│                           ▼                                          │
│  4. ┌─────────────────────────────────────────┐                     │
│     │ CONFIRMATION (if needed)                │                     │
│     │ • Show script name, skill, arguments   │                     │
│     │ • User approves or denies              │                     │
│     │ • Option: "Trust this skill's scripts" │                     │
│     └─────────────────────────────────────────┘                     │
│                           │                                          │
│                           ▼                                          │
│  5. ┌─────────────────────────────────────────┐                     │
│     │ EXECUTION                               │                     │
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
│     │ • Record: execution time, user consent │                     │
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
kind:        .read  (confirmation managed by tool, not ToolHost — see below)
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

### 4.8 Confirmation Ownership

`skills.run_script` has `kind = .read` so `ToolHost` does **not** show a generic confirmation dialog. The tool manages confirmation internally based on trust level:

```
execute(args:)
  │
  ├── global kill switch off? → throw .scriptsDisabled
  │
  ├── trustLevel == .bundled  → run directly (no dialog)
  │
  ├── trustLevel == .trusted  → network warning dialog if network-capable
  │                              AND hash changed since warning last shown
  │                              → then run
  │
  └── trustLevel == .untrusted → show trust-aware confirmation dialog
                                   ├── cancel → throw .confirmationDenied
                                   ├── confirm → run
                                   └── confirm + "trust this skill"
                                         → grantTrust(), then run
```

The trust-aware dialog is shown via `@MainActor` dispatch, consistent with other confirmation UI in Ora.

### 4.9 Integration with Existing Patterns

**Standalone actor — no BG.02 dependency now:**
- `SkillScriptWorker` is a standalone `actor` using `Foundation.Process` directly
- Scripts are synchronous from the agent's perspective — `SkillsRunScriptTool` awaits inline
- Future: when BG.02 is built, align `SkillScriptWorker` with `BackgroundWorker` protocol to gain XPC/Container isolation without changing call sites

**Audit Logging:**
- Extend `AuditCategory` with `.scriptExecution`
- Log: skill, script filename, args (redacted if sensitive), SHA-256 hash of script file, exit code, execution time, whether confirmation was shown

**ToolRegistry:**
- Register `skills.run_script` alongside other skills tools
- Keep `skills.run_script` on default `loadPolicy = .deferred` (do not mark as core)

## 5. Implementation Plan (Draft)

### 5.1 Files to Create

| File | Purpose |
|:-----|:--------|
| `Ora/Skills/ScriptManifest.swift` | Parse and validate `scripts/manifest.json`; defaults when manifest absent |
| `Ora/Skills/SkillScriptWorker.swift` | Standalone `actor`; `Foundation.Process` spawning, stdout/stderr capture, timeout + SIGTERM/SIGKILL, output truncation. Future: refactor to conform to `BackgroundWorker` (BG.02) for XPC/Container isolation. |
| `Ora/Skills/ScriptEnvironment.swift` | Build filtered env dict from allowlist; inject `ORA_*` context vars |
| `Ora/Skills/ScriptTrustManager.swift` | Trust levels (bundled/trusted/untrusted), SHA-256 hash tracking, revocation; persists to `AppSettings.scriptTrustRecordsJSON` in SwiftData |
| `Ora/Skills/ScriptSandbox.swift` | Path validation (no traversal, must be inside `scripts/`), shebang parsing per spec in §4.5, size limit enforcement |
| `Ora/Tools/Skills/SkillsRunScriptTool.swift` | `kind = .read`; trust check + conditional confirmation dialog + `SkillScriptWorker.run()` + audit log |

### 5.2 Files to Modify

| File | Change |
|:-----|:-------|
| `Ora/Tools/ToolRegistry.swift` | Register `skills.run_script` tool (deferred) |
| `Ora/Persistence/AuditLogEntry.swift` | Add `.scriptExecution` case to `AuditCategory` enum |
| `Ora/Persistence/AuditLogger.swift` | Add `recordScriptExecution()` method |
| `Ora/Persistence/Models/AppSettings.swift` | Add `scriptTrustRecordsJSON: String?` field for trust persistence |
| `Ora/Preferences/Tabs/SkillsPreferencesView.swift` | Add script settings section |
| `Ora/Skills/SkillStore.swift` | Expose script manifest info |
| `Ora/Skills/SkillMetadata.swift` | Add `hasScripts: Bool` field |
| `OraTests/Tools/ToolDiscoveryTests.swift` | Verify `tools.discover` surfaces `skills.run_script` when requested |

### 5.3 Tests to Add

| File | Coverage |
|:-----|:---------|
| `OraTests/Skills/ScriptManifestTests.swift` | Manifest parsing, validation, defaults |
| `OraTests/Skills/SkillScriptWorkerTests.swift` | Execution, timeout, output capture, signals; uses mock scripts in a temp directory |
| `OraTests/Skills/ScriptEnvironmentTests.swift` | Env filtering, Ora context injection |
| `OraTests/Skills/ScriptTrustManagerTests.swift` | Trust levels, hash validation, revocation |
| `OraTests/Skills/ScriptSandboxTests.swift` | Path validation, shebang parsing, size limits |
| `OraTests/Skills/SkillsRunScriptToolTests.swift` | Full tool flow with mocks |

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

- [ ] AC-6: Bundled skills' scripts execute without confirmation
- [ ] AC-7: Untrusted user skills require per-execution confirmation; the confirmation dialog is shown by `SkillsRunScriptTool` (not ToolHost's generic dialog, because `kind = .read`)
- [ ] AC-8: User can mark a skill as "trusted" in Settings
- [ ] AC-9: Trusted skill scripts execute without confirmation (subject to AC-10)
- [ ] AC-10: Script content changes (hash mismatch) revoke trust automatically
- [ ] AC-11: Global toggle disables all script execution

### Execution

- [ ] AC-12: `skills.run_script` has `kind = .read` and keeps default `loadPolicy = .deferred` — ToolHost does not show a generic confirmation dialog; the tool manages all confirmation logic internally; tool remains discoverable via `tools.discover`
- [ ] AC-13: `skills.run_script` executes scripts via `Foundation.Process` (no shell intermediary)
- [ ] AC-14: Arguments are passed as positional command-line args via `Process.arguments` — no shell interpolation, values passed verbatim
- [ ] AC-15: Scripts run with controlled environment variables (filtered per §4.4 allowlist)
- [ ] AC-16: Working directory is skill's `scripts/` folder
- [ ] AC-17: Default timeout is 30 seconds, configurable per-script in manifest
- [ ] AC-18: SIGTERM sent on timeout, SIGKILL after 5s grace period
- [ ] AC-19: Exit codes are captured and returned to agent
- [ ] AC-20: Scripts declaring `capabilities: ["network"]` in manifest (or with no manifest) display a network warning in the confirmation dialog — even for trusted skills, once per script version (hash-keyed)

### Output Handling

- [ ] AC-21: stdout and stderr captured separately
- [ ] AC-22: Output truncated at 64KB with indicator
- [ ] AC-23: JSON output parsed and returned as structured data
- [ ] AC-24: Non-zero exit code returns error with stderr

### Audit & Logging

- [ ] AC-25: All script executions logged to audit trail
- [ ] AC-26: Audit includes: skill, script, args, SHA-256 hash of script file, exit code
- [ ] AC-27: Audit includes: execution time, whether confirmation was shown

### Settings UI

- [ ] AC-28: Script execution toggle in Skills preferences
- [ ] AC-29: Per-skill trust management (trust/revoke)
- [ ] AC-30: View script trust status and stored hashes

## 7. Verification Plan

### Automated Tests

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
- [ ] Unit tests for path sandboxing
- [ ] Unit tests for output truncation and JSON parsing
- [ ] Unit tests for timeout and signal handling
- [ ] Unit tests for `tools.discover` ranking/visibility of `skills.run_script`
- [ ] Integration test for full execution flow with mock script

### Manual Tests

- [ ] Execute a bundled skill script, verify no confirmation prompt
- [ ] Execute an untrusted user script, verify confirmation appears
- [ ] Trust a skill, verify subsequent scripts run without confirmation
- [ ] Modify a trusted script, verify trust is revoked
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

### Layer 1: Execution Infrastructure
Build `SkillScriptWorker`, `ScriptEnvironment`, `ScriptSandbox` (shebang + path validation). Write `SkillsRunScriptTool` with `kind = .read`. At this point only bundled scripts work — user scripts are blocked pending Layer 2.

### Layer 2: Confirmation & Trust
Add `ScriptTrustManager` with bundled/trusted/untrusted levels. Wire the trust-aware confirmation dialog in `SkillsRunScriptTool`. Add `AppSettings.scriptTrustRecordsJSON` for persistence. All trust model ACs (AC-6 through AC-11) become testable here.

### Layer 3: Settings & Polish
Add script settings section to `SkillsPreferencesView` (global toggle, per-skill trust UI). Add `ScriptManifest` parsing and network capability warning. All AC-28 through AC-30 become testable here.

**All acceptance criteria (AC-1 through AC-30) must pass before the story is considered complete.**

---

## Implementation Details

### SkillScriptWorker Actor

`SkillScriptWorker` is responsible only for **execution mechanics** — path resolution, shebang parsing, env building, spawning the process, capturing output, and enforcing the timeout. Trust checking and confirmation dialogs are handled upstream by `SkillsRunScriptTool`.

```swift
/// Standalone actor for script execution. No trust logic here — all trust/confirmation
/// decisions are made by SkillsRunScriptTool before calling run().
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

    // Trust records persisted as JSON in AppSettings (SwiftData) under key
    // "scriptTrustRecords". Loaded at init, saved on every grant/revoke.
    private var trustedSkills: [String: TrustedSkillRecord] = [:]
    private let persistenceManager: PersistenceManager

    struct TrustedSkillRecord: Codable {
        let skillID: String
        let grantedAt: Date
        let scriptHashes: [String: String]  // scriptPath -> SHA256
    }

    public func trustLevel(for skillID: String) async -> TrustLevel {
        // Check if bundled
        // Check if user-trusted with valid hashes
        // Default to untrusted
    }

    public func grantTrust(skillID: String, scripts: [URL]) async {
        // Compute hashes, store record, persist to AppSettings
    }

    public func revokeTrust(skillID: String) async {
        // Remove from trusted set, persist to AppSettings
    }

    public func validateHashes(skillID: String) async -> Bool {
        // Recompute hashes, compare with stored; revoke automatically on mismatch
    }
}
```

**Persistence note:** Trust records survive app restarts. They are stored as a JSON-encoded `[String: TrustedSkillRecord]` blob in `AppSettings.scriptTrustRecordsJSON` (a new `String?` field on the SwiftData `AppSettings` model). `ScriptTrustManager` reads this on init and writes it on every `grantTrust` / `revokeTrust` call.

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

(TBD after implementation.)

## Code Review Findings

(TBD by review agent.)

## Completion Status

(TBD after merge.)
