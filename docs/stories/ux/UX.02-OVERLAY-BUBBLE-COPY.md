# UX.02 - Overlay Bubble Copy Action

**Epic:** UX
**Status:** In Progress
**Priority:** P2 (Medium)
**Estimated Effort:** 1 day
**Dependencies:** F.10
**Target:** macOS 26 (Tahoe)
**Design Reference:** F.10 Liquid Glass Overlay Refresh

---

## 1. Objective

Allow users to copy any bubble text from the overlay via a hover affordance.

## 2. User Story

As a user, I want a quick way to copy text from the overlay so I can paste responses into other apps without retyping.

## 3. Scope

### In Scope

- Show a small copy icon on hover or focus for text bubbles (user, assistant, and tool text).
- Copy the bubble content to the macOS clipboard.
- Provide a brief visual confirmation (icon swap or subtle label).
- Respect Reduce Motion and Reduce Transparency.

### Out of Scope

- Rich formatting in the clipboard (plain text only).
- Copy actions for tool blocks without primary text.
- Global "copy transcript" actions.

## 4. Architecture Alignment

- Interaction lives in `ChatBubbleView` and does not mutate pipeline state.
- Uses `NSPasteboard.general` for clipboard writes via a small abstraction to enable tests.
- Focus and hover are handled at the bubble level to keep behavior local.

## 5. Implementation Plan

### 5.1 Files to Modify

- `Ora/Overlay/ChatBubbleView.swift`: add hover/focus-driven copy affordance and action.
- `Ora/Overlay/OverlayView.swift`: ensure bubble action hit-testing does not block scroll.

### 5.2 UX Details

- Only show copy affordance when `text` is non-empty.
- Hover shows a small icon button in the top-right corner of the bubble.
- Keyboard focus also reveals the button for accessibility.
- After click, swap icon to a checkmark for ~1 second.
- Respect Reduce Motion (no springy transitions).

### 5.3 Tests

- `OraTests/Overlay/ChatBubbleCopyTests.swift`: unit-test the copy handler using an injected pasteboard abstraction.

## 6. Acceptance Criteria

- [x] AC-1: Hovering a text bubble reveals a copy icon (user, assistant, tool text). ✅ Verified in `ChatBubbleView.swift:60-64` - overlay shows copy button on hover
- [x] AC-2: Clicking the icon copies the bubble text to the clipboard. ✅ Verified in `ChatBubbleView.swift:112-114` - uses pasteboard abstraction
- [x] AC-3: A "copied" visual state appears briefly after the action. ✅ Verified in `ChatBubbleView.swift:90,115-121` - checkmark icon for 1 second
- [x] AC-4: Tool state blocks or empty bubbles do not show the copy affordance. ✅ Verified by test `test_copyButton_notShownForStateOnlyBubble`
- [x] AC-5: The copy affordance is keyboard accessible. ✅ Verified in `ChatBubbleView.swift:72-74` - accessibilityAction named "Copy"

## 7. Verification Plan

### Automated

- Run `./build.sh test`.

### Manual

- Hover user, assistant, and tool text bubbles; confirm icon appears.
- Click icon; paste into TextEdit and confirm content.
- Verify partial bubbles copy the current text snapshot.
- Toggle Reduce Motion/Transparency.

## 8. Risks & Mitigations

- Risk: Hover button interferes with scrolling. Mitigation: keep the button small and avoid full-width overlays.
- Risk: Clipboard writes leak sensitive data. Mitigation: follow explicit user action only.

## 9. Open Questions

- Should we also add a `contextMenu` fallback for non-pointer users?

---

## Implementation Summary

**Date:** 2026-01-17
**Branch:** `feat/UX.02-overlay-bubble-copy`

### Files Changed

- `Ora/Overlay/ChatBubbleView.swift` - Added copy affordance with hover state, pasteboard abstraction
- `OraTests/Overlay/ChatBubbleCopyTests.swift` - Created test suite for copy functionality

### Key Implementation Details

1. **Pasteboard Abstraction:** `PasteboardWriting` protocol with `SystemPasteboard` implementation enables test injection
2. **Hover State:** `@State isHovered` tracks mouse hover, shows copy button in top-right corner
3. **Copy Confirmation:** `@State isCopied` shows checkmark icon for 1 second after copy
4. **Accessibility:** `accessibilityAction(named: "Copy")` enables VoiceOver copy action
5. **Reduce Motion:** Transitions respect `reduceMotion` setting (opacity only vs. scale+opacity)
6. **Enum Rename:** `State` → `BubbleState` to avoid conflict with SwiftUI's `@State`

### Ready for Review

- [x] All acceptance criteria verified
- [x] Tests passing (975/975)
- [x] Working tree clean

---

## Code Review Findings

**Reviewer:** Codex Subagent
**Date:** 2026-01-17T19:54:00Z
**Commit reviewed:** 4def033
**Iteration:** 1

### Summary
- Files reviewed: 2
- Build status: Pass

### Issues Found

#### P0 - Critical (Must fix)
- None

#### P1 - Major (Should fix)
- None

#### P2 - Minor (Can defer)
- [ ] `Ora/Overlay/ChatBubbleView.swift:80-81` - Redundant logic in `shouldShowCopyButton`. The check `if self.state != nil && self.text == nil` is unreachable because the `guard let text = self.text` at line 79 already returns false if `text` is nil.

### Future Considerations (Out of Scope)
- None

### Approval Status
- [x] All P0 issues resolved
- [x] All P1 issues resolved
- [x] Ready for merge

---

## Code Review Findings

**Reviewer:** Codex Subagent
**Date:** 2026-01-17T19:58:00Z
**Commit reviewed:** c0e5f17
**Iteration:** 2

### Summary
- Files reviewed: 7
- Build status: Pass

### Issues Found

#### P0 - Critical (Must fix)
- None

#### P1 - Major (Should fix)
- None

#### P2 - Minor (Can defer)
- None

### Future Considerations (Out of Scope)
- None

### Approval Status
- [x] All P0 issues resolved
- [x] All P1 issues resolved
- [x] Ready for merge
