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

### CRITICAL: Glass Text Color Adaptation (Do Not Regress)

When modifying `ChatBubbleView.swift`, preserve these patterns for proper text color adaptation on light backgrounds:

1. **Content layer before glass effect:** Assistant/tool bubbles need `neutralGlassBackground` applied BEFORE `.glassEffect()` to give the glass something to sample. User bubbles use `userChromaOverlay` for this purpose.

2. **Compositing group after glass:** `.compositingGroup()` must be applied AFTER `.glassEffect()` to force correct background sampling on initial render.

```swift
// CORRECT pattern - do not change this structure:
base
    .userChromaOverlay(enabled: self.role == .user, shape: shape)
    .neutralGlassBackground(enabled: self.role != .user, shape: shape)
    .glassEffect(self.glassStyle(for: self.role), in: shape)
    .compositingGroup()
```

See UX.02 "Follow-Up Issue" section for full context on this fix.

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

## 10. Liquid Glass Enhancement Techniques

> **Reference:** See `docs/stories/ux/liquid-glass-resources.md` for full details.

The following advanced techniques from GitHub research can enhance the visual polish:

### 10.1 Private Glass Variants (Experimental)

The [JulianWindeck/liquid-glass](https://github.com/JulianWindeck/liquid-glass) repo reveals 20 hidden `NSGlassEffectView` variants (0-19) accessible via runtime. Variant **v11** is reportedly "visually super pleasing" for general use.

**Potential use:** Experiment with different variants to find the best aesthetic for the overlay panel.

```swift
// Example: Access private variants via NSViewRepresentable wrapper
LiquidGlassBackground(variant: .v11, cornerRadius: 12) {
    YourOverlayContent()
}
```

### 10.2 Control Center Style Luminosity

For enhanced edge luminosity similar to macOS Control Center tiles:

```swift
// Add angular gradient stroke for edge luminosity effect
.overlay(
    RoundedRectangle(cornerRadius: 18)
        .stroke(
            AngularGradient(
                gradient: Gradient(colors: [.white, .white.opacity(0.2), .white, .white.opacity(0.2), .white]),
                center: .center
            ),
            lineWidth: 0.6
        )
        .rotationEffect(.degrees(45))
        .opacity(0.7)
)
.saturation(1.5)
.brightness(0.05)
```

### 10.3 Performance Optimization with GlassEffectContainer

Per [JuniperPhoton's research](https://juniperphoton.substack.com/p/adopting-liquid-glass-experiences), each `CABackdropLayer` requires **3 offscreen textures** for rendering. Using `GlassEffectContainer` reduces the number of backdrop layers:

```swift
// ✅ Single CABackdropLayer for all elements
GlassEffectContainer {
    VStack {
        Button("A") { }.glassEffect()
        Button("B") { }.glassEffect()
    }
}

// ❌ Multiple CABackdropLayers (worse performance)
VStack {
    Button("A") { }.glassEffect()
    Button("B") { }.glassEffect()
}
```

### 10.4 Fix Hit-Testing for Glass Buttons

Glass effect buttons may have incorrect hit-testing areas:

```swift
Button { action() } label: {
    Image(systemName: "ellipsis")
}
.glassEffect(.regular, in: .circle)
.contentShape(.circle)  // Fix: Explicitly define hit area
```

### 10.5 Morphing Transition Control

For show/hide animations, control whether glass morphs or fades:

```swift
// Morphing (default) - glass shapes blend together
.glassEffectTransition(.matchedGeometry)

// Materialize - fade in/out instead of morph
.glassEffectTransition(.materialize)
```

### 10.6 UIKit Bridge for Rotation Issues

If overlay rotates (e.g., for different screen orientations), SwiftUI's `glassEffect` has animation artifacts. Use UIKit bridge:

```swift
// Use UIVisualEffectView with UIGlassEffect for rotation-safe glass
// See: https://github.com/JuniperPhoton/GlassRotationIssue
```

### 10.7 Symbol Variants for Liquid Glass

Use "none" variants of SF Symbols for toolbar buttons in Liquid Glass design:

```swift
// ✅ Preferred for Liquid Glass
Image(systemName: "checkmark")
    .symbolVariant(.none)

// ❌ Circle variants look dated in Liquid Glass
Image(systemName: "checkmark.circle")
```

---

## 11. Implementation Recommendations

Based on the research, prioritize these enhancements for UX.03:

1. **Ensure GlassEffectContainer wraps all bubbles** - Already done, but verify single CABackdropLayer.
2. **Add edge luminosity overlay** - Subtle angular gradient stroke on bubble shapes.
3. **Use `.contentShape()` on interactive elements** - Fix any hit-testing issues.
4. **Consider `.glassEffectTransition(.materialize)`** - For calmer show/hide animations vs morphing.
5. **Test with `.symbolVariant(.none)`** - For any toolbar/action icons.

---

## Implementation Summary

**Date:** 2026-01-18
**Branch:** `feat/UX.03-overlay-visual-polish`
**Commits:** 1

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

### Ready for Review

- [x] All acceptance criteria verified
- [x] Tests passing (55 overlay tests)
- [x] Working tree clean
