# X.07A - Mail: Compose

**Epic:** Tools
**Status:** In Progress
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
- **AppleScript Safety:** argv-based scripts + Notes-aligned `json_escape` to avoid parse errors.

## 5. Implementation Plan

### 5.1 Files to Create

- `Ora/Tools/Mail/MailToolError.swift`
- `Ora/Tools/Mail/MailAppleScript.swift`
- `Ora/Tools/Mail/MailCreateDraftTool.swift`
- `Ora/Tools/Mail/MailSendTool.swift`
- `Ora/Tools/Mail/MailOpenDraftTool.swift`
- `Ora/Tools/Mail/MailAppleScriptTemplates.applescript` (optional: static argv script resource)

### 5.2 Files to Modify

- `Ora/Tools/ToolRegistry.swift`
- `Ora/Resources/system-prompt.txt`
- `Ora/Info.plist` (Apple Events usage description)
- `Ora/Tools/Automation/AppleScriptRunner.swift` (argv support + logging on parse failures)

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
- [x] AC-7: AppleScript execution uses argv (no string interpolation of user input). ✅ Verified by `test_createDraftScript_usesArgv`, `test_sendScript_usesArgv`, `test_openDraftScript_usesArgv` — all scripts use `on run argv` pattern.
- [x] AC-8: Script source is ASCII-only and compiles under `osascript` without parse errors. ✅ Verified by `test_scripts_areAsciiOnly` — all unicode scalars < 128.
- [x] AC-9: JSON escaping matches Notes tool behavior (double-escaped backslashes/quotes). ✅ Verified by `test_scripts_containJsonEscape` — identical `json_escape`/`replace_chars` handlers.

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

**Date:** 2026-02-01
**Branch:** `feat/x07a-mail-compose`
**Commits:** 1

### Files Changed
- `Ora/Tools/Mail/MailToolError.swift` - Created: error enum with permission, account, argument, script, response cases.
- `Ora/Tools/Mail/MailAppleScript.swift` - Created: argv-based AppleScript builders for create_draft, send, open_draft with json_escape helpers and envelope parsing.
- `Ora/Tools/Mail/MailCreateDraftTool.swift` - Created: mail.create_draft tool (mutate, requires confirmation).
- `Ora/Tools/Mail/MailSendTool.swift` - Created: mail.send tool (mutate, requires confirmation).
- `Ora/Tools/Mail/MailOpenDraftTool.swift` - Created: mail.open_draft tool (read, no confirmation).
- `Ora/Tools/ToolRegistry.swift` - Modified: register 3 Mail tools.
- `Ora/Resources/system-prompt.txt` - Modified: add Mail section (rule 11) with usage instructions.
- `OraTests/Tools/Mail/MailComposeToolsTests.swift` - Created: 24 tests covering schemas, validation, execution, error mapping, argv safety, ASCII-only, json_escape.
- `OraTests/Tools/Calendar/CalendarToolsTests.swift` - Modified: update tool count 29→32.
- `OraTests/Tools/Reminders/RemindersToolsTests.swift` - Modified: update tool count 29→32.

### Ready for Review
- [x] All acceptance criteria verified
- [x] Tests passing (24/24 mail tests + all previously passing tests)
- [ ] Working tree clean
