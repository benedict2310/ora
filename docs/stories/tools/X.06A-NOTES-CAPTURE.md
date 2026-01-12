# X.06A - Notes: Capture & Retrieve

**Epic:** Tools
**Status:** Not Started
**Priority:** P1 (Important)
**Estimated Effort:** 1–2 days
**Dependencies:** X.0A, X.05
**Target:** macOS 26 (Tahoe)
**Design Reference:** None

---

## 1. Objective

Enable Ora to capture thoughts and retrieve existing notes using the default Apple Notes app, validating the AppleScript foundation.

## 2. User Story

As a user, I want to create and find notes via voice command so that I can capture thoughts and retrieve information without manually navigating the Notes app.

## 3. Scope

### In Scope

- **Create Note:** `notes.create_note` (body, optional title, folder, account).
- **Search Notes:** `notes.search_notes` (query, limit) returning ID/Name/Folder.
- **Open Note:** `notes.open_note` (by ID).
- **List Folders:** `notes.list_folders` (account filter).

### Out of Scope

- Appending to notes (handled in X.06B).
- Complex formatting (rich text/images).
- Folder creation/deletion.

## 4. Architecture Alignment

- **Component:** `Ora/Tools/Notes`
- **Foundation:** Uses `AppleScriptRunner` (X.0A).
- **Permissions:** Must handle `permission_denied` gracefully.

## 5. Implementation Plan (Draft)

### 5.1 Files to Create

- `Ora/Tools/Notes/NotesToolError.swift`
- `Ora/Tools/Notes/NotesCreateTool.swift`
- `Ora/Tools/Notes/NotesSearchTool.swift`
- `Ora/Tools/Notes/NotesOpenTool.swift`
- `Ora/Tools/Notes/NotesListFoldersTool.swift`

### 5.2 Files to Modify

- `Ora/Tools/ToolRegistry.swift`

### 5.3 Tests to Add

- `OraTests/Tools/Notes/NotesToolsTests.swift`

### 5.4 Dependencies/Config

- None.

## 6. Acceptance Criteria

- [ ] AC-1: `notes.create_note` creates a note in the default folder.
- [ ] AC-2: `notes.create_note` respects the specified folder (if it exists).
- [ ] AC-3: `notes.search_notes` returns top results with stable IDs, titles, and folder names.
- [ ] AC-4: `notes.open_note` opens the correct note by ID.
- [ ] AC-5: `notes.list_folders` returns available folders.
- [ ] AC-6: Permission denied errors return actionable remediation instructions.

## 7. Verification Plan

### Automated Tests

- Unit tests for AppleScript generation and JSON result parsing.
- Mock `AppleScriptRunner` to verify tool logic.

### Manual Tests

- Verify creating a note actually appears in Notes.app.
- Verify searching finds the newly created note.

## 8. Performance / Reliability Considerations

- Search performance depends on AppleScript; enforce `limit` parameter.

## 9. Risks & Mitigations

- **Risk:** Notes app structure changes. **Mitigation:** Use robust object specifiers in AppleScript.

## 10. Open Questions

- None.

---

## Implementation Summary

(TBD after implementation.)

## Code Review Findings

(TBD by review agent.)

## Completion Status

(TBD after merge.)
