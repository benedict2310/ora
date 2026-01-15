# UX.00 - Overlay Bubble Spacing

**Epic:** UX
**Status:** Open
**Priority:** P1 (High)
**Estimated Effort:** 1 day
**Dependencies:** F.07
**Target:** macOS 26 (Tahoe)
**Design Reference:** docs/stories/bugs/BUG.02-LIQUID-GLASS-BLACK-OUTLINE.md

---

## 1. Objective

Normalize spacing between overlay bubbles so Liquid Glass shapes do not sit near the container’s blending threshold, reducing black outline artifacts in light mode.

## 2. User Story

As a user, I want the overlay bubbles to feel clean and cohesive so glass effects do not show distracting outlines.

## 3. Scope

### In Scope

- Standardize vertical spacing between chat bubbles, tool blocks, and follow-up prompts.
- Align `GlassEffectContainer(spacing:)` with interior layout spacing so shapes do not partially blend at rest.
- Align bubble outer padding so adjacent glass shapes do not nearly-touch.
- Keep spacing changes consistent across user/assistant/tool bubbles.
- Respect Reduce Motion/Reduce Transparency settings.

### Out of Scope

- Changing glass variants or tint colors.
- Modifying tool execution or agent pipeline behavior.
- New animations or layout restructuring beyond spacing and padding.

## 4. Architecture Alignment

- UI-only changes inside `Ora/Overlay`, assuming the current liquid-glass overlay is in place.
- Preserve `GlassEffectContainer` usage and glass modifier ordering (BUG.02 fixes).
- Keep the overlay state machine untouched; spacing is a rendering concern only.
- Align with PRD UX principles: predictable, readable, and minimal distraction.
- Follow Apple’s guidance: container spacing controls when Liquid Glass effects blend, and container spacing larger than interior layout spacing can cause blending at rest.
- Follow Apple’s guidance: apply `glassEffect` after modifiers that affect appearance.

## 5. Implementation Plan (Draft)

### 5.1 Files to Create

- `Ora/Overlay/OverlayLayout.swift` - Shared spacing constants for container spacing, row spacing, and bubble padding.

### 5.2 Files to Modify

- `Ora/Overlay/OverlayView.swift` - Apply shared spacing constants to `GlassEffectContainer(spacing:)`, `LazyVStack`, and conditional blocks.
- `Ora/Overlay/ChatBubbleView.swift` - Use shared padding/spacing constants for bubble content.
- `Ora/Overlay/ToolStateView.swift` - Align outer spacing with chat bubbles.
- `Ora/Overlay/OverlayView.swift` - Ensure follow-up prompt uses the same vertical spacing cadence.

### 5.3 Tests to Add

- `OraTests/Overlay/OverlayLayoutTests.swift` - Validate shared spacing constants are defined and stable.

### 5.4 Dependencies/Config

- None.

## 6. Acceptance Criteria

- [ ] AC-1: `GlassEffectContainer` spacing is less than or equal to the message row spacing so bubbles do not blend at rest.
- [ ] AC-2: Vertical spacing between consecutive overlay rows is consistent across message, tool, and follow-up blocks.
- [ ] AC-3: Light mode no longer shows black outline seams caused by near-touching glass bubbles.
- [ ] AC-4: Dark mode appearance remains unchanged or improved.
- [ ] AC-5: Reduce Motion/Transparency behavior remains intact.
- [ ] AC-6: No regressions in scrolling or bubble alignment.

## 7. Verification Plan

### Automated Tests

- [ ] Run `./build.sh test`.

### Manual Tests

- [ ] Light mode: read a short back-and-forth; verify no black outlines between bubbles.
- [ ] Light mode: verify bubbles remain visually separate at rest (no partial morphing).
- [ ] Light mode: trigger tool proposal and follow-up; verify spacing consistency.
- [ ] Dark mode: repeat the same checks.
- [ ] Toggle Reduce Motion/Transparency.

## 8. Performance / Reliability Considerations

- Keep spacing changes minimal to avoid layout jitter during streaming updates.

## 9. Risks & Mitigations

- Risk: Spacing adjustments alone may not fully eliminate outlines.  
  Mitigation: Keep BUG.02 options open for follow-up if needed.

## 10. Open Questions

- Should spacing tighten for consecutive assistant tokens while streaming, or remain uniform?

---

## Implementation Summary

(TBD after implementation.)

## Code Review Findings

(TBD by review agent.)

## Completion Status

(TBD after merge.)
