# X.08 - Recent Items: Mail & Notes

**Epic:** Tools
**Status:** Not Started
**Priority:** P1 (High)
**Estimated Effort:** 1 day
**Dependencies:** X.07B (Mail Search), X.06A (Notes Capture)
**Target:** macOS 26 (Tahoe)
**Design Reference:** None

---

## 1. Objective

Allow users to browse recent mail messages and recently modified notes without specifying a search query. Currently both `mail.search` and `notes.search_notes` require a query string — "show me my latest emails" or "what notes do I have?" fail because no keyword is provided. This story adds two new read-only tools (`mail.recent`, `notes.recent`) that return the most recent items by default.

## 2. User Story

As a user, I want to ask "show me my recent emails" or "what are my latest notes" and get a useful list — without needing to know a specific subject or title to search for.

## 3. Scope

### In Scope

- **`mail.recent`** — List recent mail messages (newest first), optionally filtered by mailbox or account.
  - Parameters: `mailbox` (optional), `account` (optional), `limit` (optional, default 10, max 50).
  - Returns: message headers only (subject, from, date, mailbox, message_id). No body content.
  - Reuses existing `MailAppleScript.recentMessagesScript()` and the `mailboxHelpers` infrastructure.
- **`notes.recent`** — List recently modified notes, optionally filtered by folder or account.
  - Parameters: `folder` (optional), `account` (optional), `limit` (optional, default 10, max 50).
  - Returns: note_id, title, folder, modification_date.
  - New `NotesAppleScript.recentNotesScript()` — Apple Notes iterates notes in modification-date order by default.
  - Includes `modification_date` from Notes' `modification date` property.
- Both tools are `ToolKind.read` (no confirmation required).
- Register both tools in `ToolRegistry`.
- Update system prompt with usage instructions.

### Out of Scope

- Reading full email bodies or note contents (privacy — use `notes.read_note` / `mail.open_message` for that).
- Sorting or filtering by date range (no date parameters; just "most recent N").
- Fuzzy matching (not applicable — no query to match against).
- Any changes to existing `mail.search` or `notes.search_notes` tools.

## 4. Architecture Alignment

- **Component:** `Ora/Tools/Mail` and `Ora/Tools/Notes`
- **Privacy:** `mail.recent` must NOT return message body. `notes.recent` returns title/folder/date only.
- **Reuses:** `MailAppleScript.recentMessagesScript()` (already exists), `MailAppleScript.parseEnvelope()`, `NotesAppleScript.buildScript()`, `NotesAppleScript.parseEnvelope()`, `AppleScriptRunner`.
- **Threading:** Tool execution is async. AppleScript runs via `AppleScriptRunner`. No concurrency concerns.
- **No guardrails needed:** Both tools are read-only (`ToolKind.read`).
- **Audit logging:** Handled automatically by `ToolHost.execute()`.
- **Mail AppleScript context:** The `mailboxHelpers` handlers require `tell application "Mail"` inside each handler body (fixed in X.07B bugfix). New code must follow this pattern.

## 5. Implementation Plan (Draft)

### 5.1 Files to Create

- `Ora/Tools/Mail/MailRecentTool.swift` — `mail.recent` tool implementation.
- `Ora/Tools/Notes/NotesRecentTool.swift` — `notes.recent` tool implementation.

### 5.2 Files to Modify

- `Ora/Tools/Notes/NotesAppleScript.swift` — Add `recentNotesScript(folder:account:limit:)` builder.
- `Ora/Tools/ToolRegistry.swift` — Register `MailRecentTool` and `NotesRecentTool`.
- `Ora/Resources/system-prompt.txt` — Add usage rules for `mail.recent` and `notes.recent`.

### 5.3 Tests to Add

- `OraTests/Tools/Mail/MailRecentToolTests.swift`:
  - `test_recent_returnsHeadersOnly` — Verify no body in results.
  - `test_recent_returnsMessageId` — Verify message_id present for follow-up.
  - `test_recent_respectsLimit` — Verify limit parameter passed to script.
  - `test_recent_defaultsLimit` — Verify default limit is 10.
  - `test_recent_clampsLimit` — Verify max 50.
  - `test_recent_passesMailboxFilter` — Verify mailbox arg forwarded.
  - `test_recent_passesAccountFilter` — Verify account arg forwarded.
  - `test_recent_noRequiredParams` — Verify empty args is valid.
- `OraTests/Tools/Notes/NotesRecentToolTests.swift`:
  - `test_recent_returnsTitleAndFolder` — Verify note_id, title, folder, modification_date.
  - `test_recent_returnsModificationDate` — Verify date field present.
  - `test_recent_respectsLimit` — Verify limit parameter.
  - `test_recent_defaultsLimit` — Verify default limit is 10.
  - `test_recent_clampsLimit` — Verify max 50.
  - `test_recent_passesFolderFilter` — Verify folder arg forwarded.
  - `test_recent_passesAccountFilter` — Verify account arg forwarded.
  - `test_recent_noRequiredParams` — Verify empty args is valid.
- Verify both tools registered in `ToolRegistry` (add to existing registry tests).

### 5.4 Dependencies/Config

- No new external dependencies.
- No `project.yml` changes.

## 6. Acceptance Criteria

- [x] AC-1: `mail.recent` returns message headers (subject, from, date, mailbox, message_id) but NOT body.
- [x] AC-2: `mail.recent` accepts optional `mailbox`, `account`, and `limit` parameters; all parameters are optional.
- [x] AC-3: `mail.recent` defaults to 10 results, caps at 50.
- [x] AC-4: `notes.recent` returns note_id, title, folder, and modification_date.
- [x] AC-5: `notes.recent` accepts optional `folder`, `account`, and `limit` parameters; all parameters are optional.
- [x] AC-6: `notes.recent` defaults to 10 results, caps at 50.
- [x] AC-7: Both tools are registered in `ToolRegistry`.
- [x] AC-8: System prompt updated with usage instructions for both tools.
- [x] AC-9: Unit tests cover both tools with mocked AppleScript execution.
- [x] AC-10: Neither tool returns full content/body (privacy constraint).

## 7. Verification Plan

### Automated Tests

- [x] Unit tests for `mail.recent` schema, validation, execution with mock runner.
- [x] Unit tests for `notes.recent` schema, validation, execution with mock runner.
- [x] Unit tests for limit clamping, default values, and filter forwarding.
- [x] Registry tests confirm both tools are present.

### Manual Tests

- [ ] "Show me my recent emails" → Verify list with subject/date/sender.
- [ ] "What are my latest notes?" → Verify list with title/folder/date.
- [ ] "Show my last 3 emails" → Verify limit respected.
- [ ] "Recent notes in Work folder" → Verify folder filter works.
- [ ] "Open the first one" (after mail.recent) → Verify message_id usable with mail.open_message.

## 8. Performance / Reliability Considerations

- `mail.recent` iterates Mail messages in order (newest first by default in Apple Mail). Capped at 50 max — no risk of scanning entire mailbox.
- `notes.recent` iterates Notes in modification-date order. Capped at 50 max.
- AppleScript execution is async and sandboxed — timeouts handled by `AppleScriptRunner`.
- Both tools return minimal data (headers/titles only) to keep LLM context compact.

## 9. Risks & Mitigations

- **Risk:** Apple Notes iteration order may not be strictly by modification date on all accounts (e.g., iCloud vs On My Mac). **Mitigation:** Use Notes' `modification date` property to sort or at minimum include it in results so the LLM can reason about recency.
- **Risk:** Large mailbox with slow iteration. **Mitigation:** Default limit of 10 with max 50 keeps iteration bounded.
- **Risk:** Mail account with no messages. **Mitigation:** Return empty array with clear summary ("No recent messages found.").

## 10. Open Questions

- None.

---

## Implementation Summary

(TBD after implementation.)

## Code Review Findings

**Reviewer:** Codex Subagent
**Date:** 2026-02-01T21:38:00+01:00
**Commit reviewed:** 419865e
**Iteration:** 1

### Summary
- Files reviewed: 13
- Build status: Pass

### Issues Found

#### P0 - Critical (Must fix)
- None

#### P1 - Major (Should fix)
- None

#### P2 - Minor (Can defer)
- None

### Approval Status
- [x] All P0 issues resolved
- [x] All P1 issues resolved
- [x] Ready for merge
