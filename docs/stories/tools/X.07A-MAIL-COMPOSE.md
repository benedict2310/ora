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

## 5. Implementation Plan

### 5.1 Files to Create

- `Ora/Tools/Mail/MailToolError.swift`
- `Ora/Tools/Mail/MailAppleScript.swift`
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

- [x] AC-1: `mail.create_draft` creates a draft with all fields populated. ✅ Verified in `Ora/Tools/Mail/MailCreateDraftTool.swift` and `Ora/Tools/Mail/MailAppleScript.swift`.
- [x] AC-2: `mail.create_draft` returns a draft ID. ✅ Verified in `Ora/Tools/Mail/MailAppleScript.swift`.
- [x] AC-3: `mail.open_draft` opens the window for the given draft ID. ✅ Verified in `Ora/Tools/Mail/MailOpenDraftTool.swift` and `Ora/Tools/Mail/MailAppleScript.swift`.
- [x] AC-4: `mail.send` sends the email. ✅ Verified in `Ora/Tools/Mail/MailSendTool.swift` and `Ora/Tools/Mail/MailAppleScript.swift`.
- [x] AC-5: `mail.send` requires confirmation. ✅ Verified in `Ora/Tools/Mail/MailSendTool.swift`.
- [x] AC-6: Permission denied returns remediation. ✅ Verified in `Ora/Tools/Mail/MailToolError.swift` and `OraTests/Tools/Mail/MailComposeToolsTests.swift`.

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

**Date:** 2026-01-22
**Branch:** `feat/apple-mail-integration`
**Commits:** 2

### Files Changed
- `Ora/Tools/Mail/MailAppleScript.swift` - Build AppleScript payloads and parse JSON envelopes.
- `Ora/Tools/Mail/MailToolError.swift` - Map Mail automation failures to user-facing remediation.
- `Ora/Tools/Mail/MailCreateDraftTool.swift` - Create drafts with confirmation.
- `Ora/Tools/Mail/MailSendTool.swift` - Send emails with confirmation.
- `Ora/Tools/Mail/MailOpenDraftTool.swift` - Open drafts via Apple Mail.
- `Ora/Tools/ToolRegistry.swift` - Register Mail tools.
- `OraTests/Tools/Mail/MailComposeToolsTests.swift` - Coverage for schemas, validation, and parsing.
- `docs/stories/tools/X.07A-MAIL-COMPOSE.md` - Plan, AC verification, and summary updates.

### Ready for Review
- [x] All acceptance criteria verified
- [ ] Tests passing (full suite timed out; targeted tests passed)
- [x] Working tree clean

## Code Review Findings

**Reviewer:** Codex Subagent
**Date:** 2026-01-22T07:57:37+01:00
**Commit reviewed:** 51139dc
**Iteration:** 1

### Summary
- Files reviewed: 8
- Build status: Pass

### Issues Found

#### P0 - Critical (Must fix)
- [ ] None.

#### P1 - Major (Should fix)
- [x] `Ora/Tools/Mail/MailAppleScript.swift` - In `openDraftScript`, the loop `repeat with candidate in messages of draftsBox` iterates strictly one-by-one, generating excessive AppleEvents. For users with many drafts, this will cause timeouts or UI freezes. **Fix:** Use an AppleScript `whose` filter: `set targetMessage to first message of draftsBox whose id is draftId`. ✅ Fixed by switching to `first message of draftsBox whose id is draftIdValue`.

#### P2 - Minor (Can defer)
- [ ] `Ora/Tools/Mail/MailAppleScript.swift` - Significant code duplication between `createDraftScript` and `sendEmailScript` for account lookup and sender resolution.

### Future Considerations (Out of Scope)
- None.

### Approval Status
- [x] All P0 issues resolved
- [x] All P1 issues resolved
- [ ] Ready for merge

## Completion Status

(TBD after merge.)
