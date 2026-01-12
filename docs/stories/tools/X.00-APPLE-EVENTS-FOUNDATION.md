# X.00 - Apple Events Automation Foundation

**Epic:** Tools
**Status:** In Progress
**Priority:** P0 (Critical Path)
**Estimated Effort:** 2 days
**Dependencies:** X.01
**Target:** macOS 26 (Tahoe)
**Design Reference:** None

---

## 1. Objective

Provide a single, robust "automation substrate" for controlling scriptable macOS apps via **Apple Events** (AppleScript). The substrate must run scripts reliably, return machine-readable JSON results, normalize errors (especially Automation permission failures), and support timeouts and structured logging.

## 2. User Story

As a developer, I want a unified way to execute AppleScripts and parse their output so that I can implement reliable tools for Notes, Mail, and Messages without duplicating error handling or process management logic.

## 3. Scope

### In Scope

- Shared `AppleScriptRunner` for executing scripts via `osascript` or `NSAppleScript`.
- Standard JSON envelope for script output.
- Error normalization (mapping raw errors to `permission_denied`, `timeout`, etc.).
- Debug logging and timeout management.
- Capability probing (checking if apps are installed/authorized).

### Out of Scope

- Specific tool implementations (Notes, Mail, etc.).
- GUI Scripting (System Events) wrappers (focus on direct Apple Events).

## 4. Architecture Alignment

- **Component:** `Ora/Tools/Automation`
- **Concurrency:** `async/await` wrapper around process execution.
- **Error Handling:** Typed `AppleScriptError` mapping to `ToolError`.
- **Permissions:** Detection of `errAEEventWouldRequireUserConsent` (-1744) or similar.

## 5. Implementation Plan (Draft)

### 5.1 Files to Create

- `Ora/Tools/Automation/AppleScriptRunner.swift` - Core runner logic.
- `Ora/Tools/Automation/AppleScriptError.swift` - Error types and mapping.
- `Ora/Tools/Automation/AppleScriptUtils.swift` - JSON parsing and helper functions.

### 5.2 Files to Modify

- `Ora/Tools/ToolRegistry.swift` - (Optional) Registration if runner is a service.

### 5.3 Tests to Add

- `OraTests/Tools/Automation/AppleScriptRunnerTests.swift` - Unit tests for runner, JSON parsing, and error mapping (mocking `Process` output).

### 5.4 Dependencies/Config

- None.

## 6. Acceptance Criteria

- [x] AC-1: Runner executes an AppleScript and returns stdout. - Verified in `AppleScriptRunner.swift:43-96`, tested by `test_execute_simpleScript_returnsOutput`
- [x] AC-2: Runner can parse and return JSON payloads from a standard envelope. - Verified in `AppleScriptUtils.swift:52-71`, tested by `test_parseJSONEnvelope_validJSON_returnsValue`
- [x] AC-3: Runner supports timeout and returns specific `timeout` error. - Verified in `AppleScriptRunner.swift:173-212`, tested by `test_execute_timeout_throwsTimeoutError`
- [x] AC-4: Permission errors normalize to `permission_denied` with remediation guidance. - Verified in `AppleScriptError.swift:21-32,101-134`, tested by `test_parse_recognizesPermissionErrorCode_1744`
- [x] AC-5: Error messages include debug metadata (error number, raw message). - Verified in `AppleScriptError.swift:54-82`, tested by `test_permissionDeniedError_debugInfo_includesAllFields`
- [x] AC-6: Safe cancellation behavior (no runaway loops). - Verified in `AppleScriptRunner.swift:158-172`, tested by `test_cancelAll_terminatesRunningScripts`

## 7. Verification Plan

### Automated Tests

- Unit tests verifying JSON parsing of success/failure envelopes.
- Unit tests verifying error code mapping from raw osascript stderr.
- Timeout tests.

### Manual Tests

- Run a test script against an unprivileged app to verify "Permission Denied" flow.
- Run a long script to verify timeout.

## 8. Performance / Reliability Considerations

- **Timeout:** Scripts must not hang indefinitely. Default timeout 10s.
- **Concurrency:** Thread-safe execution.

## 9. Risks & Mitigations

- **Risk:** `osascript` can be slow to start. **Mitigation:** Keep scripts compiled or use `NSAppleScript` if `Process` overhead is too high (though `Process` is safer for isolation).
- **Risk:** Permission prompts block execution. **Mitigation:** Detect blocking state or rely on timeout.

## 10. Open Questions

- Should we use `NSUserAppleScriptTask`? (Likely overkill, `Process` is sufficient for v1).

---

## Implementation Summary

**Date:** 2026-01-12
**Branch:** `feat/X.00-apple-events-foundation`
**Commits:** 1

### Files Created

- `Ora/Tools/Automation/AppleScriptError.swift` - Categorized error types with parsing from osascript stderr
- `Ora/Tools/Automation/AppleScriptRunner.swift` - Actor-based runner with timeout and cancellation support
- `Ora/Tools/Automation/AppleScriptUtils.swift` - JSON envelope parsing and script building utilities
- `OraTests/Tools/Automation/AppleScriptRunnerTests.swift` - 43 unit and integration tests

### Key Implementation Details

1. **Error Types:** `AppleScriptError` enum with 6 categories (`permissionDenied`, `timeout`, `executionFailed`, `invalidOutput`, `processStartFailed`, `cancelled`)
2. **Permission Detection:** Recognizes error codes -1744, -1743, -10004, -600, -10006 plus keyword-based detection
3. **JSON Parsing:** Uses JSONSerialization with manual conversion to JSONValue for reliable parsing
4. **Timeout Mechanism:** Uses task group with racing timeout task, terminates process on timeout
5. **Actor Isolation:** Thread-safe execution via Swift actor

### Ready for Review

- [x] All acceptance criteria verified
- [x] Tests passing (914 total, 43 new)
- [x] Build succeeds

## Code Review Findings

(TBD by review agent.)

## Completion Status

(TBD after merge.)
