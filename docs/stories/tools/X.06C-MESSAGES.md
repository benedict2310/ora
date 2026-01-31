# X.06C - Messages: Send & Open (Guarded)

**Epic:** Tools
**Status:** In Progress
**Priority:** P1 (Important)
**Estimated Effort:** 1–2 days
**Dependencies:** X.0A
**Target:** macOS 26 (Tahoe)
**Design Reference:** None

---

## 1. Objective

Enable Ora to send iMessage/SMS via the Messages app with strict confirmation guardrails, plus a safe “open chat” action. This is the minimum reliable integration for macOS 26+.

## 2. User Story

As a user, I want to send short messages and open chats by voice so that I can communicate quickly while staying focused.

## 3. Scope

### In Scope

- **Send Message:** `messages.send` (handle, message, service)
- **Open Chat:** `messages.open_chat` (handle, service)
- **Guardrails:** `requiresConfirmation = true` for sending
- **Automation permission handling** (clear remediation when denied)

### Out of Scope

- Reading inbox / message history (privacy + reliability)
- Message receive hooks (AppleScript “on message received” handlers are unreliable in modern macOS)
- Attachments or rich media
- Group chat creation
- Direct DB access to `~/Library/Messages/chat.db` (future)

## 4. Architecture Alignment

- **Component:** `Ora/Tools/Messages`
- **Foundation:** `AppleScriptRunner` (X.0A)
- **Focus Tracking:** `ExternalFocusTracker` for user-visible operations (open chat)

### AppleScript Strategy (Send / Open)

- Use **single AppleScript payload** with strong escaping and JSON envelope output.
- Target account resolution order:
  1. If `service` is provided, try that service type (iMessage/SMS/RCS)
  2. Fallback to iMessage
  3. Fallback to first account

### Permissions

- `NSAppleEventsUsageDescription` must exist in Info.plist
- User must grant **Automation → Messages** in System Settings
- If sandboxed in the future, add `com.apple.security.automation.apple-events` entitlement

## 5. Implementation Plan (Draft)

### 5.1 Files to Create

- `Ora/Tools/Messages/MessagesAppleScript.swift`
- `Ora/Tools/Messages/MessagesToolError.swift`
- `Ora/Tools/Messages/MessagesSendTool.swift`
- `Ora/Tools/Messages/MessagesOpenChatTool.swift`

### 5.2 Files to Modify

- `Ora/Tools/ToolRegistry.swift`
- `Ora/Resources/system-prompt.txt`
- `Ora/Info.plist` (Apple Events usage description)

### 5.3 Tests to Add

- `OraTests/Tools/Messages/MessagesToolsTests.swift`
  - schema coverage
  - required parameter validation
  - JSON envelope parsing
  - permission-denied mapping

### 5.4 Dependencies/Config

- None beyond Apple Events permission + Automation prompt.

## 6. Acceptance Criteria

- [ ] AC-1: `messages.open_chat` opens a chat in Messages for the handle.
- [ ] AC-2: `messages.send` sends a message via Messages (requires confirmation).
- [ ] AC-3: `messages.send` uses `requiresConfirmation = true` (guardrails enforced).
- [ ] AC-4: Permission denied returns actionable remediation.
- [ ] AC-5: Tool honors service hints (`iMessage`, `SMS`, `RCS`) when provided.

## 7. Verification Plan

### Automated Tests

- Verify `requiresConfirmation` for `messages.send`.
- Validate required parameters for send/open.
- Ensure AppleScript JSON envelope parsing succeeds.
- Verify permission-denied mapping for Apple Events failure.

### Manual Tests

- “Text John hello” → Ora asks for confirmation, then sends.
- “Open chat with Sarah” → Messages opens the conversation.
- Disable Automation permission → verify remediation error.

## 8. Performance / Reliability Considerations

- Messages can be slow to launch if closed; keep operations async.
- Avoid parsing or reading message history in v1 to minimize privacy risk.

## 9. Risks & Mitigations

- **Risk:** Sending to wrong person. **Mitigation:** Confirmation dialog + clear handle in summary.
- **Risk:** Automation permission denied. **Mitigation:** Actionable error with Settings path.
- **Risk:** Service mismatch (SMS vs iMessage). **Mitigation:** service hint + fallback order.

## 10. Open Questions

- Should we add optional chat.db read-only support (requires Full Disk Access)?
- Should we normalize handles via Contacts before sending?

---

## Implementation Summary

(TBD after implementation.)

## Code Review Findings

(TBD by review agent.)

## Completion Status

(TBD after merge.)
