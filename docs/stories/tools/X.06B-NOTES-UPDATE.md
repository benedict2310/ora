# X.06B - Notes: Update

**Epic:** Tools
**Status:** Not Started
**Priority:** P1 (Important)
**Estimated Effort:** 0.5–1.5 days
**Dependencies:** X.06A
**Target:** macOS 26 (Tahoe)
**Design Reference:** None

---

## 1. Objective

Enable appending content to existing notes, facilitating "log" style workflows (e.g., "Add this to my Meeting Notes").

## 2. User Story

As a user, I want to append text to an existing note so that I can maintain running logs or lists without creating new note fragments.

## 3. Scope

### In Scope

- **Append:** `notes.append_to_note` (target ID/Title, content).
- **Ambiguity Resolution:** Logic to handle multiple notes with the same name (return candidates).

### Out of Scope

- Prepending content.
- Deleting content.
- Replacing content.

## 4. Architecture Alignment

- **Component:** `Ora/Tools/Notes`
- **Logic:** Two-step resolution (ID -> Title -> Ambiguity Check -> Append).

## 5. Implementation Plan (Draft)

### 5.1 Files to Create

- `Ora/Tools/Notes/NotesAppendTool.swift`

### 5.2 Files to Modify

- `Ora/Tools/ToolRegistry.swift`

### 5.3 Tests to Add

- `OraTests/Tools/Notes/NotesAppendToolTests.swift`

### 5.4 Dependencies/Config

- None.

## 6. Acceptance Criteria

- [ ] AC-1: Append works when target is a valid Note ID.
- [ ] AC-2: Append works when target is a unique Note Title.
- [ ] AC-3: If title matches multiple notes, tool returns a candidate list (no modification).
- [ ] AC-4: If title matches zero notes, tool returns a "not found" error.
- [ ] AC-5: Content is appended preserving existing text.

## 7. Verification Plan

### Automated Tests

- Test ambiguity logic with mock search results.

### Manual Tests

- Create two notes named "Daily Log", try to append, verify it asks for clarification.

## 8. Performance / Reliability Considerations

- Fetching note body to append might be slow for very large notes; verify if `append` command exists in Notes AppleScript suite to avoid full read-write cycle.

## 9. Risks & Mitigations

- **Risk:** Race conditions if note is edited externally. **Mitigation:** AppleScript `save` usually handles this, but conflicts are possible.

## 10. Open Questions

- Does Notes.app AppleScript support direct `append` or do we need `get body` + `set body`? (Likely `make new HTML attachment` or `set body to body & ...`).

---

## Implementation Summary

(TBD after implementation.)

## Code Review Findings

(TBD by review agent.)

## Completion Status

(TBD after merge.)
