# F.10 - Liquid Glass Overlay Refresh

**Epic:** Foundations
**Status:** Not Started
**Priority:** P1 (High)
**Estimated Effort:** 3-4 days
**Dependencies:** F.07
**Target:** macOS 26 (Tahoe)
**Design Reference:** agent-tools/GlassChatPreview/README.md, agent-tools/GlassChatPreview_snapshot_20260102-142219

---

## 1. Objective

Upgrade the Ora overlay to the new liquid-glass chat UI with voice input morphing and state-driven bubble rendering.

## 2. User Story

As a power user or accessibility user, I want a clear, modern overlay that shows listening, thinking, tool execution, and responses in a liquid-glass chat layout so that I can trust what Ora is doing and respond quickly.

## 3. Scope

### In Scope

- Replace the current overlay UI with the liquid-glass chat layout from `GlassChatPreview`.
- Render chat bubbles for user/assistant/tool states with left/right alignment.
- Add the voice input control that morphs between idle (listening pill) and active input.
- Preserve tool proposal confirmation and follow-up prompt flows inside the new layout.
- Keep overlay sizing/positioning aligned with current top-center behavior.
- Respect accessibility settings (Reduce Motion/Reduce Transparency).

### Out of Scope

- Changes to ASR/LLM/Tool pipelines or their state machines.
- New preferences or user-tunable styling controls.
- New assets beyond the existing system symbols and colors.

## 4. Architecture Alignment

- UI remains in `Ora/Overlay` and uses `OverlayViewModel` as the single source of truth (`@MainActor`).
- Overlay states map to the existing UI state machine in `ARCHITECTURE.md` (listening → thinking → proposing/executing → completed).
- Use `GlassEffectContainer` and `glassEffect` to align with Liquid Glass design guidance; avoid stacking glass-on-glass.
- Preserve boundary rules: UI only renders state; it does not call tools directly.
- References: PRD “User Experience Principles” (push-to-talk, streaming, predictability), Architecture “UI State Machine”.

## 5. Implementation Plan (Draft)

### 5.1 Files to Create

- `Ora/Overlay/VoiceInputControlView.swift` - Listening pill + morphing input bubble.
- `Ora/Overlay/ChatBubbleView.swift` - User/assistant/tool bubble rendering.
- `Ora/Overlay/ToolStateView.swift` - Tool execution/proposal visual state block.

### 5.2 Files to Modify

- `Ora/Overlay/OverlayView.swift` - Replace layout with liquid-glass chat surface; integrate new subviews.
- `Ora/Overlay/OverlayWindowController.swift` - Adjust panel size/position if needed for the new layout.
- `Ora/Overlay/OverlayState.swift` - Extend view model helpers if needed for tool bubble state or partial transcript handling.

### 5.3 Tests to Add

- `OraTests/Overlay/OverlayViewModelTests.swift` - Ensure partial transcript updates and mode changes map to expected messages.
- `OraTests/Overlay/OverlayWindowTests.swift` - Validate overlay sizing/positioning for the new layout.

### 5.4 Dependencies/Config

- No new dependencies expected.

## 6. Acceptance Criteria

- [ ] AC-1: Overlay UI matches the liquid-glass chat layout with left/right bubbles and a top-centered overlay position.
- [ ] AC-2: Voice input control morphs between idle pill and active input bubble without abrupt jumps.
- [ ] AC-3: User bubbles have a visible light-blue chroma overlay while preserving glass depth; agent/tool bubbles remain neutral.
- [ ] AC-4: Tool proposal confirmation and follow-up prompt are still shown in-context.
- [ ] AC-5: Reduce Motion/Reduce Transparency settings are respected (animations/tints degrade gracefully).

## 7. Verification Plan

### Automated Tests

- [ ] Overlay view model tests for partial ASR updates and assistant streaming.
- [ ] Overlay window tests for panel sizing/positioning.

### Manual Tests

- [ ] Press ⌥Space to show overlay; verify voice input control appears and animates in.
- [ ] Speak and release hotkey; verify listening → thinking → responding bubble progression.
- [ ] Trigger tool proposal; verify confirmation UI appears within the overlay.
- [ ] Toggle Reduce Motion/Transparency and confirm the UI remains legible.

## 8. Performance / Reliability Considerations

- Avoid continuous animations outside the listening pulse; keep transitions short and discrete.
- Use `GlassEffectContainer` to keep glass sampling consistent and avoid performance regressions.

## 9. Risks & Mitigations

- Liquid Glass tint appears muted on low-contrast backgrounds - use chroma overlay on user bubbles to preserve hue.
- Overlay feels too dense at 400x300 - adjust panel height/width if needed while retaining top-center placement.

## 10. Open Questions

- Resolve input control pill to serve as the single status indicator for all overlay states.
- Final copy for tool status labels deferred to tool implementation stories.

---

## Implementation Summary

(TBD after implementation.)

## Code Review Findings

(TBD by review agent.)

## Completion Status

(TBD after merge.)
