# S.03 - Skill Scripts

**Epic:** Skills
**Status:** Future
**Priority:** P2 (Medium)
**Estimated Effort:** 6 days
**Dependencies:** S.01 (Skills Runtime), O.04 (Confirmation Flow)
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
    let PATH: String  // Filtered to safe paths only
    let LANG: String
    let TZ: String

    // Ora-provided context
    let ORA_SKILL_ID: String
    let ORA_SKILL_ROOT: String
    let ORA_SCRIPT_NAME: String
    let ORA_REQUEST_ID: String

    // Explicitly NOT inherited
    // - API keys, tokens, credentials
    // - SSH_AUTH_SOCK
    // - AWS_*, GOOGLE_*, etc.
}
```

### 4.5 Supported Script Types

| Type | Shebang Example | Detection |
|:-----|:----------------|:----------|
| Bash | `#!/bin/bash` | `.sh`, shebang |
| Zsh | `#!/bin/zsh` | `.zsh`, shebang |
| Python 3 | `#!/usr/bin/env python3` | `.py`, shebang |
| AppleScript | `#!/usr/bin/osascript` | `.scpt`, `.applescript` |
| Ruby | `#!/usr/bin/env ruby` | `.rb`, shebang |
| Node.js | `#!/usr/bin/env node` | `.js`, `.mjs`, shebang |

Execution uses the shebang; extension is fallback for detection only.

### 4.6 Integration with Existing Patterns

**ToolHost Integration:**
- `SkillsRunScriptTool` implements `Tool` protocol
- Uses existing confirmation flow via `ToolHost.execute()`
- `kind = .mutate` ensures confirmation requirement

**Audit Logging:**
- Extend `AuditCategory` with `.scriptExecution`
- Log script hash to detect tampering
- Log full command line and exit code

**ToolRegistry:**
- Register `skills.run_script` alongside other skills tools

## 5. Implementation Plan (Draft)

### 5.1 Files to Create

| File | Purpose |
|:-----|:--------|
| `Ora/Skills/ScriptManifest.swift` | Parse and validate `scripts/manifest.json` |
| `Ora/Skills/ScriptRunner.swift` | Process spawning, output capture, timeout |
| `Ora/Skills/ScriptEnvironment.swift` | Environment variable filtering and Ora context |
| `Ora/Skills/ScriptTrustManager.swift` | Trust levels, hash tracking, revocation |
| `Ora/Skills/ScriptSandbox.swift` | Path validation, size limits, shebang parsing |
| `Ora/Tools/Skills/SkillsRunScriptTool.swift` | Tool implementation |

### 5.2 Files to Modify

| File | Change |
|:-----|:-------|
| `Ora/Tools/ToolRegistry.swift` | Register `skills.run_script` tool |
| `Ora/Persistence/AuditLogEntry.swift` | Add `scriptExecution` category |
| `Ora/Persistence/AuditLogger.swift` | Add `recordScriptExecution()` method |
| `Ora/Preferences/Tabs/SkillsPreferencesView.swift` | Add script settings section |
| `Ora/Skills/SkillStore.swift` | Expose script manifest info |
| `Ora/Skills/SkillMetadata.swift` | Add `hasScripts: Bool` field |

### 5.3 Tests to Add

| File | Coverage |
|:-----|:---------|
| `OraTests/Skills/ScriptManifestTests.swift` | Manifest parsing, validation, defaults |
| `OraTests/Skills/ScriptRunnerTests.swift` | Execution, timeout, output capture, signals |
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
- [ ] AC-7: Untrusted user skills require per-execution confirmation
- [ ] AC-8: User can mark a skill as "trusted" in Settings
- [ ] AC-9: Trusted skill scripts execute without confirmation
- [ ] AC-10: Script content changes (hash mismatch) revoke trust
- [ ] AC-11: Global toggle disables all script execution

### Execution

- [ ] AC-12: `skills.run_script` tool executes scripts via Process API
- [ ] AC-13: Scripts run with controlled environment variables
- [ ] AC-14: Working directory is skill's `scripts/` folder
- [ ] AC-15: Default timeout is 30 seconds, configurable per-script
- [ ] AC-16: SIGTERM sent on timeout, SIGKILL after 5s grace period
- [ ] AC-17: Exit codes are captured and returned to agent

### Output Handling

- [ ] AC-18: stdout and stderr captured separately
- [ ] AC-19: Output truncated at 64KB with indicator
- [ ] AC-20: JSON output parsed and returned as structured data
- [ ] AC-21: Non-zero exit code returns error with stderr

### Audit & Logging

- [ ] AC-22: All script executions logged to audit trail
- [ ] AC-23: Audit includes: skill, script, args, hash, exit code
- [ ] AC-24: Audit includes: execution time, confirmation status

### Settings UI

- [ ] AC-25: Script execution toggle in Skills preferences
- [ ] AC-26: Per-skill trust management (trust/revoke)
- [ ] AC-27: View script trust status and hashes

## 7. Verification Plan

### Automated Tests

- [ ] Unit tests for manifest parsing (valid, invalid, missing)
- [ ] Unit tests for shebang detection and validation
- [ ] Unit tests for environment filtering
- [ ] Unit tests for trust manager (grant, revoke, hash check)
- [ ] Unit tests for path sandboxing
- [ ] Unit tests for output truncation and JSON parsing
- [ ] Unit tests for timeout and signal handling
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

## Phased Implementation

Given the security sensitivity, consider implementing in phases:

### Phase 1: Bundled Scripts Only
- Only scripts in bundled skills can execute
- Auto-approved, no confirmation needed
- Full audit logging
- Establishes execution infrastructure

### Phase 2: User Scripts with Confirmation
- User skill scripts require per-execution confirmation
- Confirmation dialog shows script details
- No trust persistence yet

### Phase 3: Trust Management
- Add "Trust this skill" option
- Hash-based trust invalidation
- Settings UI for trust management

---

## Implementation Details

### ScriptRunner Actor

```swift
public actor ScriptRunner {

    public struct ScriptResult: Sendable {
        public let exitCode: Int32
        public let stdout: String
        public let stderr: String
        public let executionTime: TimeInterval
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
        case confirmationDenied
    }

    private let trustManager: ScriptTrustManager
    private let sandbox: ScriptSandbox
    private let maxOutputBytes = 64 * 1024
    private let defaultTimeout: TimeInterval = 30
    private let killGracePeriod: TimeInterval = 5

    public func run(
        skillID: String,
        scriptPath: String,
        arguments: [String],
        confirmed: Bool
    ) async throws -> ScriptResult {
        // 1. Validate path
        let resolvedPath = try sandbox.resolve(skillID: skillID, scriptPath: scriptPath)

        // 2. Check trust
        let trustLevel = await trustManager.trustLevel(for: skillID)
        if trustLevel == .untrusted && !confirmed {
            throw ScriptError.confirmationDenied
        }

        // 3. Parse shebang and validate interpreter
        let interpreter = try sandbox.parseShebang(at: resolvedPath)

        // 4. Build environment
        let env = ScriptEnvironment.build(skillID: skillID, scriptPath: scriptPath)

        // 5. Execute with timeout
        return try await executeWithTimeout(
            interpreter: interpreter,
            script: resolvedPath,
            arguments: arguments,
            environment: env.asDictionary()
        )
    }

    private func executeWithTimeout(
        interpreter: String,
        script: URL,
        arguments: [String],
        environment: [String: String]
    ) async throws -> ScriptResult {
        // Process execution with timeout, signal handling, output capture
        // ...
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

    private var trustedSkills: [String: TrustedSkillRecord] = [:]

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
        // Compute hashes, store record
    }

    public func revokeTrust(skillID: String) async {
        // Remove from trusted set
    }

    public func validateHashes(skillID: String) async -> Bool {
        // Recompute hashes, compare with stored
    }
}
```

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

## Notes

This story is prioritized as **Future/P2** because:

1. Core skills (S.01) must be validated first
2. Security model requires careful design review
3. Confirmation flow (O.04) should be complete first
4. User research on trust UX would be valuable

The phased approach allows shipping value incrementally while managing risk.

---

## Implementation Summary

(TBD after implementation.)

## Code Review Findings

(TBD by review agent.)

## Completion Status

(TBD after merge.)
