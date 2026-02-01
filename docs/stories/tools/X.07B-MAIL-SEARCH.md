# X.07B - Mail: Search & Open

**Epic:** Tools
**Status:** Not Started
**Priority:** P1 (Important)
**Estimated Effort:** 1–2 days
**Dependencies:** X.07A (Complete)
**Target:** macOS 26 (Tahoe)
**Design Reference:** None

---

## 1. Objective

Allow finding emails and opening them in the Mail app.

**Privacy Constraint:** Do NOT read full email bodies aloud or return them to the LLM context by default. The goal is "Find -> Open -> User Reads".

**Fuzzy Search Requirement:** Since Ora is a voice assistant, all search queries pass through ASR which regularly introduces spelling errors. `mail.search` must use a two-tier search pattern: try exact/substring matching first via AppleScript `whose` clauses, then fall back to Jaro-Winkler fuzzy scoring on the returned results if the initial search returns too few results. This follows the established pattern from `ContactsSearchTool` (M.09 / fuzzy app search).

## 2. User Story

As a user, I want to find specific emails and open them so I can read them myself — even when speech recognition slightly misspells names or subjects.

## 3. Scope

### In Scope

- **Search:** `mail.search` (query, mailbox, account, limit).
  - Tier 1: AppleScript `whose` clause matching on subject/sender (fast, exact).
  - Tier 2: If Tier 1 returns no results, fetch recent messages and apply Jaro-Winkler fuzzy scoring on subject and sender fields (threshold 0.80).
  - Return fuzzy results sorted by descending score.
  - Include `match_score` in result metadata for fuzzy matches.
- **Open:** `mail.open_message` (id) — opens message in Mail.
- **List Mailboxes:** `mail.list_mailboxes` — lists available mailboxes.
- Reuse `StringSimilarity.jaroWinkler()` from `Ora/Tools/Contacts/StringSimilarity.swift`.

### Out of Scope

- Reading full email bodies (Privacy).
- Searching attachments.
- Phonetic name variants beyond Jaro-Winkler.

## 4. Architecture Alignment

- **Component:** `Ora/Tools/Mail`
- **Privacy:** `mail.search` result payload must exclude `content` field. Only return: subject, from, date, message ID, mailbox.
- **Reuses:** `StringSimilarity` enum (no new dependencies), `MailAppleScript` runner from X.07A, `MailToolError` from X.07A.
- **Threading:** Tool execution is async. AppleScript runs via `AppleScriptRunner`. Fuzzy scoring is in-memory on returned results — fast.
- **No guardrails needed:** All three tools are read-only (`ToolKind.read`).

## 5. Implementation Plan (Draft)

### 5.1 Files to Create

- `Ora/Tools/Mail/MailSearchTool.swift` — `mail.search` tool with two-tier fuzzy pattern.
- `Ora/Tools/Mail/MailOpenMessageTool.swift` — `mail.open_message` tool.
- `Ora/Tools/Mail/MailListMailboxesTool.swift` — `mail.list_mailboxes` tool.

### 5.2 Files to Modify

- `Ora/Tools/Mail/MailAppleScript.swift` — Add AppleScript builders for search, open message, list mailboxes.
- `Ora/Tools/ToolRegistry.swift` — Register the three new tools.
- `Ora/Resources/system-prompt.txt` — Add mail search rules (fuzzy matching note, privacy constraint).

### 5.3 Tests to Add

- `OraTests/Tools/Mail/MailSearchToolTests.swift`:
  - `test_search_returnsHeadersOnly` — Verify no body in results.
  - `test_search_returnsStableMessageId` — Verify message ID format.
  - `test_search_fuzzyFallback_findsTypo` — Verify fuzzy finds "Jonh" → "John".
  - `test_search_fuzzyFallback_respectsThreshold` — Verify dissimilar queries return empty.
  - `test_search_fuzzyFallback_sortedByScore` — Verify descending order.
  - `test_search_respectsLimit` — Verify limit parameter.
  - `test_openMessage_validatesId` — Verify ID validation.
  - `test_listMailboxes_returnsNames` — Verify mailbox list format.

### 5.4 Dependencies/Config

- X.07A must be complete (it is).
- No new external dependencies.

## 6. Acceptance Criteria

- [x] AC-1: `mail.search` returns headers (Subject, From, Date, Mailbox) but NOT body.
- [x] AC-2: `mail.search` returns a stable message ID for opening.
- [x] AC-3: `mail.open_message` brings the message window to front.
- [x] AC-4: `mail.list_mailboxes` returns valid mailbox names.
- [x] AC-5: When exact/substring search returns results, fuzzy scoring does not run.
- [x] AC-6: When exact search returns no results, fuzzy fallback scores subject/sender using `StringSimilarity.jaroWinkler()` with threshold 0.80.
- [x] AC-7: Fuzzy results are sorted by descending score and include `match_score` in metadata.
- [x] AC-8: All three tools are registered in `ToolRegistry`.
- [x] AC-9: System prompt updated with mail search rules.
- [x] AC-10: Unit tests cover both exact and fuzzy search paths.

## 7. Verification Plan

### Automated Tests

- [x] Unit tests for search result schema (ensure no body).
- [x] Unit tests for fuzzy fallback path (typo scenarios).
- [x] Unit tests for threshold filtering and score ordering.
- [x] Unit tests for mailbox listing and message opening.

### Manual Tests

- [ ] "Find email from Apple" → Verify list with subject/date/sender.
- [ ] "Open the first one" → Verify Mail window opens.
- [ ] "Find email from Jonh" (ASR typo) → Verify fuzzy finds "John".
- [ ] "List my mailboxes" → Verify mailbox names returned.

## 8. Performance / Reliability Considerations

- AppleScript `whose` clause is the fast primary path — O(1) in Mail's index.
- Fuzzy fallback fetches recent messages (capped at ~100) and scores in-memory — <10ms.
- Mail search can be slow on very large mailboxes; use efficient `whose` clauses and limit results.

## 9. Risks & Mitigations

- **Risk:** AppleScript IDs in Mail can change. **Mitigation:** Use `message id` (RFC header) if possible, or handle staleness gracefully with clear error.
- **Risk:** Fuzzy false positives on common words. **Mitigation:** 0.80 threshold is conservative; score both subject and sender, take best match.
- **Risk:** Large mailbox performance. **Mitigation:** Limit fuzzy fallback to recent 100 messages; exact search uses Mail's built-in index.

## 10. Open Questions

- None.

---

## Implementation Summary

Implemented `mail.search`, `mail.open_message`, and `mail.list_mailboxes` tools using AppleScript. 
- `mail.search` uses a two-tier pattern: exact/substring search via AppleScript `whose` clauses, falling back to Jaro-Winkler fuzzy matching (0.80 threshold) on recent 100 messages if no exact results found.
- `mail.open_message` opens the specified message and activates Mail app.
- `mail.list_mailboxes` allows discovery of available mailboxes.
- Privacy is maintained by only returning headers (Subject, From, Date, Mailbox, MessageID) and explicitly excluding the message body from tool results.

## Code Review Findings

**Reviewer:** Codex Subagent
**Date:** 2026-02-01T15:45:00Z
**Commit reviewed:** bc79235
**Iteration:** 1

### Summary
- Files reviewed: 10
- Build status: Pass (✅ Tests: 1179/1179 passed)

### Issues Found

#### P0 - Critical (Must fix)
- None

#### P1 - Major (Should fix)
- None

#### P2 - Minor (Can defer)
- None

### Future Considerations (Out of Scope)
- Large mailbox performance: While Tier 1 is indexed, Tier 2 (fuzzy fallback) fetches up to 100 recent messages. If those messages have huge headers, there might be a slight delay, but it's well within acceptable limits for a fallback path.

### Approval Status
- [x] All P0 issues resolved
- [x] All P1 issues resolved
- [x] Ready for merge
