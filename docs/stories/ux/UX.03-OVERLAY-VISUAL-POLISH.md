# UX.03 - Overlay Visual Polish

**Epic:** UX
**Status:** Open
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

- AC-1: Overlay panel dimensions and content spacing feel balanced for short and long messages.
- AC-2: User/assistant/tool bubbles are visually distinct but cohesive.
- AC-3: Voice input control aligns with the chat column and feels calmer.
- AC-4: Show/hide motion is subtle and respects Reduce Motion.
- AC-5: No regression in overlay positioning or focus recovery.

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
