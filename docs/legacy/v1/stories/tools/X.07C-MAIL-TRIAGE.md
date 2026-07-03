# X.07C - Mail: Triage

**Epic:** Tools
**Status:** Not Started
**Priority:** P1 (Important)
**Estimated Effort:** 1–2 days
**Dependencies:** X.07B
**Target:** macOS 26 (Tahoe)
**Design Reference:** None

---

## 1. Objective

Enable basic inbox management: marking read/unread, flagging, and moving messages.

## 2. User Story

As a user, I want to triage my inbox by voice so I can clear my backlog efficiently.

## 3. Scope

### In Scope

- **Mark Read:** `mail.mark_read` (id, read=true/false).
- **Flag:** `mail.flag_message` (id, flagged=true/false).
- **Move:** `mail.move_message` (id, mailbox).

### Out of Scope

- Deleting messages (Safety risk for v1).
- Creating mailboxes.

## 4. Architecture Alignment

- **Component:** `Ora/Tools/Mail`
- **Foundation:** Reuse `MailService` (or equivalent provider) established in `X.07B` for AppleScript interaction.
- **ID Stability:** Must use the same message ID format as `mail.search` (X.07B) to ensure actions target the correct message.
- **Safety:** These are state-changing but reversible actions. Confirmation optional (default: false).
- **Error Handling:** Handle cases where the message ID is stale or the message has been moved/deleted externally.

## 5. Implementation Plan (Draft)

### 5.1 Files to Create

- `Ora/Tools/Mail/MailMarkReadTool.swift`
- `Ora/Tools/Mail/MailFlagTool.swift`
- `Ora/Tools/Mail/MailMoveTool.swift`

### 5.2 Files to Modify

- `Ora/Tools/ToolRegistry.swift`

### 5.3 Tests to Add

- `OraTests/Tools/Mail/MailTriageToolsTests.swift`

### 5.4 Dependencies/Config

- None.

## 6. Acceptance Criteria

- [ ] AC-1: `mail.mark_read` toggles read status.
- [ ] AC-2: `mail.flag_message` toggles flagged status.
- [ ] AC-3: `mail.move_message` moves email to target mailbox.
- [ ] AC-4: If mailbox missing, return error with candidates.
- [ ] AC-5: If message ID not found, return a clear error.

## 7. Verification Plan

### Automated Tests

- Verify state change logic via mocks (mocking `MailService`).

### Manual Tests

- **Mark Read:** "Mark the last email from Apple as read." -> Verify blue dot disappears in Mail.app.
- **Flag:** "Flag that email." -> Verify flag icon appears in Mail.app.
- **Move:** "Move it to the Archive folder." -> Verify email moves to Archive in Mail.app.

## 8. Performance / Reliability Considerations

- Moving messages can take time to sync.

## 9. Risks & Mitigations

- **Risk:** Moving to non-existent mailbox. **Mitigation:** Validate mailbox existence first.

## 10. Open Questions

- None.

---

## Implementation Summary

(TBD after implementation.)

## Code Review Findings

(TBD by review agent.)

## Completion Status

(TBD after merge.)
