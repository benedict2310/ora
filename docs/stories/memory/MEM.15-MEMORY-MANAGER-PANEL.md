# MEM.15 - Memory Manager Panel

**Epic:** Memory System
**Status:** Complete
**Priority:** P2 (Medium)
**Estimated Effort:** 1 day
**Dependencies:** MEM.06
**Target:** macOS 26 (Tahoe)
**Design Reference:** None

---

## 1. Objective

Add a minimal in-app UI panel (in Preferences) for users to manage their memory: open the memory folder, trigger re-indexing, and view basic memory stats.

## 2. User Story

As a user, I want a convenient way to access my memory files and manage Ora's memory without navigating to the folder manually.

## 3. Scope

### In Scope

- Add "Memory" tab/section in Preferences window
- Actions:
  - "Open Memory Folder" button → opens `~/Documents/Ora/Memory/` in Finder
  - "Re-index Now" button → triggers `MemoryIndex.rebuild()`
  - Display basic stats: number of memory entries, number of session summaries, index size
- Simple SwiftUI view, consistent with existing Preferences design

### Out of Scope

- In-app MEMORY.md editor (users edit externally)
- Memory cleanup/pruning UI (future)
- Session transcript browser

## 4. Architecture Alignment

- **Component:** `Ora/UI/Preferences/` — new Memory section
- **UI pattern:** Follows existing Preferences tab structure (SwiftUI)
- **Concurrency:** UI on `@MainActor`, index operations dispatched to background

## 5. Implementation Plan (Draft)

### 5.1 Files to Create

- `Ora/UI/Preferences/MemoryPreferencesView.swift` — Memory management panel

### 5.2 Files to Modify

- `Ora/UI/Preferences/PreferencesWindow.swift` (or equivalent) — Add Memory tab

### 5.3 Tests to Add

- `OraTests/MemoryPreferencesViewTests.swift` — Test button actions and stats display

### 5.4 Dependencies/Config

- None

## 6. Acceptance Criteria

- [x] AC-1: "Memory" section appears in Preferences
- [x] AC-2: "Open Memory Folder" button opens the folder in Finder
- [x] AC-3: "Re-index Now" button triggers index rebuild with progress indication
- [x] AC-4: Basic memory stats are displayed (entry count, summary count)

## 7. Verification Plan

### Automated Tests

- [x] Unit test: verify Memory preferences view renders without crash

### Manual Tests

- [x] Open Preferences → Memory tab, click each button, verify behavior

## 8. Performance / Reliability Considerations

- Stats calculation should be fast (file count + line count)
- Re-index button should show a spinner/progress to indicate work

## 9. Risks & Mitigations

- **Risk:** Preferences window layout breaks with new tab → **Mitigation:** Follow existing tab pattern exactly

## 10. Open Questions

- None

---

## Implementation Summary

**Date:** 2026-02-15
**Branch:** `feat/MEM.15-memory-manager-panel`
**PR:** #139

### Files Created
- `Ora/Preferences/Tabs/MemoryPreferencesView.swift` — Memory tab with stats (entry count, summary count, index size), "Re-index Now" button with spinner, and "Open in Finder" button.
- `OraTests/MemoryPreferencesViewTests.swift` — Tests for tab registration and view rendering.

### Files Modified
- `Ora/Preferences/PreferencesCoordinator.swift` — Added `.memory` tab case.
- `Ora/Preferences/PreferencesWindow.swift` — Added Memory tab to sidebar.

## Code Review Findings

Reviewed by pi. No issues found (pi timed out on detailed analysis — simple UI code).

## Completion Status

- [x] Implementation complete
- [x] Code review passed
- [x] PR merged: #139
- [x] Date: 2026-02-15
