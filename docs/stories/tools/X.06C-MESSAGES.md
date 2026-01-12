# X.06C - Messages: Send & Open (Guarded)

**Epic:** Tools
**Status:** Not Started
**Priority:** P1 (Important)
**Estimated Effort:** 1–2 days
**Dependencies:** X.0A
**Target:** macOS 26 (Tahoe)
**Design Reference:** None

---

## 1. Objective

Allow sending iMessages/SMS via the Messages app with strict confirmation guardrails to prevent accidental messaging.

## 2. User Story

As a user, I want to send short messages and open chats by voice so that I can communicate quickly while staying focused.

## 3. Scope

### In Scope

- **Open Chat:** `messages.open_chat` (handle/name).
- **Send Message:** `messages.send` (to, message, service).
- **Guardrails:** `requiresConfirmation = true` for sending.

### Out of Scope

- Reading message history (Privacy risk).
- Sending attachments.
- Group chat creation.

## 4. Architecture Alignment

- **Component:** `Ora/Tools/Messages`
- **Safety:** Tool must implement `requiresConfirmation`.
- **Foundation:** `AppleScriptRunner` (X.0A).

## 5. Implementation Plan (Draft)

### 5.1 Files to Create

- `Ora/Tools/Messages/MessagesToolError.swift`
- `Ora/Tools/Messages/MessagesSendTool.swift`
- `Ora/Tools/Messages/MessagesOpenChatTool.swift`

### 5.2 Files to Modify

- `Ora/Tools/ToolRegistry.swift`

### 5.3 Tests to Add

- `OraTests/Tools/Messages/MessagesToolsTests.swift`

### 5.4 Dependencies/Config

- None.

## 6. Acceptance Criteria

- [ ] AC-1: `messages.open_chat` opens the chat window for the recipient.
- [ ] AC-2: `messages.send` drafts and sends the message (simulated in test).
- [ ] AC-3: `messages.send` triggers the confirmation dialog in Ora UI (via `Tool.requiresConfirmation`).
- [ ] AC-4: Permission denied returns actionable remediation.
- [ ] AC-5: Tool correctly identifies "iMessage" vs "SMS" service if specified.

## 7. Verification Plan

### Automated Tests

- Verify `requiresConfirmation` property is true for send tool.
- Verify AppleScript generation for sending.

### Manual Tests

- Try "Text John Hello" -> Verify Ora asks "Ready to send 'Hello' to John?".
- Confirm -> Verify Messages app sends it.

## 8. Performance / Reliability Considerations

- Messages AppleScript can be slow to launch if the app is closed.

## 9. Risks & Mitigations

- **Risk:** Sending to wrong person. **Mitigation:** Strict confirmation dialog showing resolved handle.

## 10. Open Questions

- None.

---

## Implementation Summary

(TBD after implementation.)

## Code Review Findings

(TBD by review agent.)

## Completion Status

(TBD after merge.)
