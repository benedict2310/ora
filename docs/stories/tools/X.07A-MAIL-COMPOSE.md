# X.07A - Mail: Compose

**Epic:** Tools
**Status:** Not Started
**Priority:** P1 (Important)
**Estimated Effort:** 1–2 days
**Dependencies:** X.00
**Target:** macOS 26 (Tahoe)
**Design Reference:** None

---

## 1. Objective

Enable composing and sending emails via Apple Mail. Sending is a high-stakes action requiring confirmation.

## 2. User Story

As a user, I want to draft and send emails by voice so that I can process communication quickly.

## 3. Scope

### In Scope

- **Create Draft:** `mail.create_draft` (to, cc, bcc, subject, body, account).
- **Send:** `mail.send` (to, subject, body).
- **Open Draft:** `mail.open_draft` (id).
- **Safety:** Confirmation for `mail.send`.

### Out of Scope

- Attachments.
- Complex HTML bodies.

## 4. Architecture Alignment

- **Component:** `Ora/Tools/Mail`
- **Foundation:** `AppleScriptRunner` (X.00).
- **Safety:** `mail.send` must have `requiresConfirmation = true`.

## 5. Implementation Plan (Draft)

### 5.1 Files to Create

- `Ora/Tools/Mail/MailToolError.swift`
- `Ora/Tools/Mail/MailCreateDraftTool.swift`
- `Ora/Tools/Mail/MailSendTool.swift`
- `Ora/Tools/Mail/MailOpenDraftTool.swift`

### 5.2 Files to Modify

- `Ora/Tools/ToolRegistry.swift`

### 5.3 Tests to Add

- `OraTests/Tools/Mail/MailComposeToolsTests.swift`

### 5.4 Dependencies/Config

- None.

## 6. Acceptance Criteria

- [ ] AC-1: `mail.create_draft` creates a draft with all fields populated.
- [ ] AC-2: `mail.create_draft` returns a draft ID.
- [ ] AC-3: `mail.open_draft` opens the window for the given draft ID.
- [ ] AC-4: `mail.send` sends the email.
- [ ] AC-5: `mail.send` requires confirmation.
- [ ] AC-6: Permission denied returns remediation.

## 7. Verification Plan

### Automated Tests

- Verify JSON parameter parsing.
- Verify `requiresConfirmation` flags.

### Manual Tests

- "Draft an email to mom saying hi" -> Check Drafts folder.
- "Send an email to..." -> Verify confirmation prompt.

## 8. Performance / Reliability Considerations

- Mail app must be running; `AppleScriptRunner` should handle launching or error if not.

## 9. Risks & Mitigations

- **Risk:** Spamming. **Mitigation:** Confirmation dialog.

## 10. Open Questions

- None.

---

## Implementation Summary

(TBD after implementation.)

## Code Review Findings

(TBD by review agent.)

## Completion Status

(TBD after merge.)
