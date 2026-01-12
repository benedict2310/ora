# X.07B - Mail: Search & Open

**Epic:** Tools
**Status:** Not Started
**Priority:** P1 (Important)
**Estimated Effort:** 1–2 days
**Dependencies:** X.07A
**Target:** macOS 26 (Tahoe)
**Design Reference:** None

---

## 1. Objective

Allow finding emails and opening them in the Mail app.

**Privacy Constraint:** Do NOT read full email bodies aloud or return them to the LLM context by default. The goal is "Find -> Open -> User Reads".

## 2. User Story

As a user, I want to find specific emails and open them so I can read them myself.

## 3. Scope

### In Scope

- **Search:** `mail.search` (query, mailbox, account, limit).
- **Open:** `mail.open_message` (id).
- **List Mailboxes:** `mail.list_mailboxes`.

### Out of Scope

- Reading full email bodies (Privacy).
- Searching attachments.

## 4. Architecture Alignment

- **Component:** `Ora/Tools/Mail`
- **Privacy:** `mail.search` result payload must exclude `content` field.

## 5. Implementation Plan (Draft)

### 5.1 Files to Create

- `Ora/Tools/Mail/MailSearchTool.swift`
- `Ora/Tools/Mail/MailOpenMessageTool.swift`
- `Ora/Tools/Mail/MailListMailboxesTool.swift`

### 5.2 Files to Modify

- `Ora/Tools/ToolRegistry.swift`

### 5.3 Tests to Add

- `OraTests/Tools/Mail/MailSearchToolsTests.swift`

### 5.4 Dependencies/Config

- None.

## 6. Acceptance Criteria

- [ ] AC-1: `mail.search` returns headers (Subject, From, Date) but NOT body.
- [ ] AC-2: `mail.search` returns a stable ID for opening.
- [ ] AC-3: `mail.open_message` brings the message window to front.
- [ ] AC-4: `mail.list_mailboxes` returns valid mailbox names.

## 7. Verification Plan

### Automated Tests

- Verify search result schema (ensure no body).

### Manual Tests

- "Find email from Apple" -> Verify list.
- "Open the first one" -> Verify Mail window opens.

## 8. Performance / Reliability Considerations

- Mail search can be slow; use efficient AppleScript `whose` clauses.

## 9. Risks & Mitigations

- **Risk:** AppleScript IDs in Mail can change. **Mitigation:** Use `message id` (header) if possible, or handle staleness gracefully.

## 10. Open Questions

- None.

---

## Implementation Summary

(TBD after implementation.)

## Code Review Findings

(TBD by review agent.)

## Completion Status

(TBD after merge.)
