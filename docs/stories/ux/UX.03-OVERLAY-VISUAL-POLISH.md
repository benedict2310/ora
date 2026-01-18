# UX.03 - Overlay Visual Polish

**Epic:** UX
**Status:** ✅ Complete
**Priority:** P2 (Medium)
**Estimated Effort:** 2 days
**Dependencies:** F.10
**Target:** macOS 26 (Tahoe)
**Design Reference:** agent-tools/GlassChatPreview/README.md

---

## 1. Objective

Refine the overlay layout, bubble styling, voice input control, and motion so the UI feels calmer, clearer, and more intentional.

## 2. User Story

As a user, I want the overlay to feel well-spaced and visually consistent so it is easier to scan and trust.

## 3. Scope

### In Scope

- Rebalance panel size, content width, and vertical spacing.
- Refine chat bubble shapes, typography, and role differentiation.
- Refresh voice input control spacing and copy to match the new layout.
- Add subtle show/hide motion (slide + fade) with Reduce Motion support.

### Out of Scope

- New assets or custom fonts.
- Changes to the audio/LLM pipeline.
- Agent transparency and bubble copy interactions (covered by UX.01/UX.02).
- New preferences for styling.

## 4. Architecture Alignment

- All UI changes remain inside `Ora/Overlay`.
- Overlay positioning stays top-center with a small margin.
- Reduce Motion and Reduce Transparency are respected at every layer.
- Avoid regressions in focus recovery; prefer SwiftUI content transitions over panel alpha animation.

## 5. Implementation Plan

### 5.1 Files to Modify

- `Ora/Overlay/OverlayView.swift`: update panel dimensions, spacing, and max widths.
- `Ora/Overlay/OverlayWindowController.swift`: refine panel sizing and add slide-in/out animation.
- `Ora/Overlay/ChatBubbleView.swift`: adjust shape/spacing/typography for clearer hierarchy.
- `Ora/Overlay/VoiceInputControlView.swift`: refine layout, label style, and idle/active spacing.
- `Ora/Overlay/ToolStateView.swift`: align tool block styling with updated bubble styles.
- `OraTests/Overlay/OverlayWindowTests.swift`: update size/position expectations.

### 5.2 Visual Changes

- Panel size targets: increase width for long responses, reduce height when idle.
- Bubble width: slight increase for assistant/tool, tighter for user.
- Role differentiation: clearer label/weight for tool states without overpowering the glass look.
- Voice input: align its width with the chat column and adjust copy for calm tone.

### 5.3 Motion

- Show: small downward slide (8-12pt) + fade in.
- Hide: reverse slide + fade out.
- Motion disabled when Reduce Motion is enabled.

## 6. Acceptance Criteria

- [x] AC-1: Overlay panel dimensions and content spacing feel balanced for short and long messages.
  - ✅ Panel resized to 520x400, content max width 480, row spacing 24
- [x] AC-2: User/assistant/tool bubbles are visually distinct but cohesive.
  - ✅ User bubbles max 320px, assistant/tool max 380px, consistent corner radii
- [x] AC-3: Voice input control aligns with the chat column and feels calmer.
  - ✅ Max width aligned with assistant bubbles (380), smaller text/indicators, calmer copy
- [x] AC-4: Show/hide motion is subtle and respects Reduce Motion.
  - ✅ 10pt slide + fade animation, checks NSWorkspace.accessibilityDisplayShouldReduceMotion
- [x] AC-5: No regression in overlay positioning or focus recovery.
  - ✅ All existing tests pass, positioning uses centralized constants

## 7. Verification Plan

### Automated

- Run `./build.sh test`.

### Manual

- Activate overlay: confirm slide + fade in, stable top-center position.
- Send short and long messages: confirm bubble widths and spacing.
- Trigger tool proposal: confirm tool block matches updated style.
- Toggle Reduce Motion/Transparency.

## 8. Risks & Mitigations

- Risk: Animation conflicts with focus recovery. Mitigation: keep animation short and guard against repeated show calls.
- Risk: Layout tweaks regress on small screens. Mitigation: test on multiple display sizes.

## 9. Open Questions

- Should the overlay height adapt to content (up to a max) or remain fixed?

---

## Implementation Summary

**Date:** 2026-01-18
**Branch:** `feat/UX.03-overlay-visual-polish`
**Commits:** 4

### Files Changed

- `Ora/Overlay/OverlayLayout.swift` - Expanded with panel dimensions, bubble sizing, animation constants
- `Ora/Overlay/OverlayWindowController.swift` - Added slide+fade show/hide animations with Reduce Motion support
- `Ora/Overlay/OverlayView.swift` - Updated to use centralized layout constants
- `Ora/Overlay/ChatBubbleView.swift` - Differentiated bubble max widths by role
- `Ora/Overlay/VoiceInputControlView.swift` - Refined sizing, calmer copy, aligned with chat column
- `OraTests/Overlay/OverlayLayoutTests.swift` - Updated for new constants, added new property tests
- `OraTests/Overlay/OverlayWindowTests.swift` - Updated to use centralized constants

### Key Changes

1. **Centralized Layout System:** All overlay dimensions, spacing, and animation values now live in `OverlayLayout.swift`

2. **Panel Dimensions:**
   - Width: 560 → 520 (tighter)
   - Height: 380 → 400 (taller for more content)
   - Top margin: 10 → 12

3. **Bubble Sizing:**
   - Assistant/tool bubbles: max 380px
   - User bubbles: max 320px (narrower for visual distinction)
   - Bubble inset: 24 → 20

4. **Spacing:**
   - Row spacing: 28 → 24 (slightly tighter)
   - Bubble content spacing: 8 → 6
   - Tool content spacing: 12 → 10

5. **Voice Input Control:**
   - Smaller indicator dots (10 → 8px)
   - Smaller text (caption.bold → caption2.semibold)
   - Calmer copy: "Listening..." → "Listening…"
   - Reduced shadow intensity

6. **Show/Hide Animation:**
   - Slide distance: 10pt
   - Show duration: 0.25s
   - Hide duration: 0.15s
   - Respects Reduce Motion accessibility setting

---

## Code Review Findings

**Reviewer:** Codex Subagent
**Date:** 2026-01-18T22:05:00Z
**Commit reviewed:** ec30277
**Iteration:** 2

### Summary
- Files reviewed: 8
- Build status: Pass

### Issues Found

#### P0 - Critical (Must fix)
- [x] None

#### P1 - Major (Should fix)
- [x] None

#### P2 - Minor (Can defer)
- [ ] `OverlayWindowController.swift` - The `show` method resets `alphaValue` to 0 before animating. If the panel is already visible (e.g. rapid hotkey usage), this might cause a visual flash. Consider checking if panel is already visible.
- [ ] `OverlayWindowController.swift` - Previous code had a comment about `runAnimationGroup` being unreliable in Release builds. Verify that this implementation (using `animator()`) is stable in Release configuration.

### Future Considerations (Out of Scope)
- Consider extracting `panel` creation and layout logic into a dedicated `OverlayPanelManager` if `OverlayWindowController` grows larger.

### Approval Status
- [x] All P0 issues resolved
- [x] All P1 issues resolved
- [x] Ready for merge

---

## Completion Status

- [x] Implementation complete
- [x] Code review passed (2 iterations)
- [x] PR merged: https://github.com/benedict2310/ora/pull/77
- [x] Merged to main: d025366
- [x] Date: 2026-01-18
