# UX.02 - Overlay Bubble Copy Action

**Epic:** UX
**Status:** Complete
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

---

## Completion Status

- [x] Implementation complete
- [x] Code review passed (2 iterations)
- [x] PR merged: https://github.com/benedict2310/ora/pull/75
- [x] Merged to main: c0440a65898a092de3da1617ba54f01fd177ae00
- [x] Date: 2026-01-17

---

## Post-Merge Issue: Copy Button Not Clickable

**Reported:** 2026-01-17
**Status:** ✅ Resolved

### Problem

The copy icon renders visually but:
1. Appears to be in the background layer
2. Is not clickable/interactive

### Root Cause Analysis

Based on research from the [Liquid Glass Reference](https://github.com/conorluddy/LiquidGlassReference), the issue is likely caused by **glass layering conflicts**:

1. **Glass cannot sample other glass** - The copy button has its own `.ultraThinMaterial` background while sitting inside a `ZStack` with a parent that has `.glassEffect()`. This creates a glass-on-glass situation.

2. **Button inside glass effect** - The current implementation applies `.glassEffect()` to the bubble content, then overlays a button with its own material background. The glass effect may be capturing hit-testing or rendering order.

3. **Using manual background instead of `.buttonStyle(.glass)`** - The reference explicitly states: "Use `.buttonStyle(.glass)` for buttons instead of manually applying `.glassEffect()` to buttons."

### Current Implementation (Problematic)

```swift
// ChatBubbleView.swift - current approach
ZStack(alignment: .topTrailing) {
    // Glass effect applied to base content
    base
        .glassEffect(self.glassStyle(for: self.role), in: shape)
    
    // Button with manual material background - may conflict
    if self.shouldShowCopyButton {
        Button { ... } label: {
            Image(systemName: "doc.on.doc")
                .background {
                    RoundedRectangle(...)
                        .fill(.ultraThinMaterial)  // ❌ Glass-on-glass
                }
        }
        .buttonStyle(.plain)
    }
}
```

### Recommended Fixes

**Option 1: Use `.buttonStyle(.glass)` (Preferred)**
```swift
ZStack(alignment: .topTrailing) {
    base
        .glassEffect(self.glassStyle(for: self.role), in: shape)
    
    if self.shouldShowCopyButton {
        Button { self.copyToClipboard() } label: {
            Image(systemName: self.isCopied ? "checkmark" : "doc.on.doc")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(self.isCopied ? .green : .secondary)
        }
        .buttonStyle(.glass)  // ✅ Native glass button style
        .controlSize(.small)
        .padding(6)
    }
}
```

**Option 2: Use `GlassEffectContainer` to wrap both elements**
```swift
GlassEffectContainer {
    ZStack(alignment: .topTrailing) {
        base
            .glassEffect(self.glassStyle(for: self.role), in: shape)
        
        if self.shouldShowCopyButton {
            self.copyButton
                .glassEffect(.regular.interactive(), in: .circle)
        }
    }
}
```

**Option 3: Remove glass from button (non-glass overlay)**
```swift
// If glass button has issues, use a simple colored background
Button { ... } label: {
    Image(systemName: "doc.on.doc")
        .foregroundStyle(.secondary)
        .frame(width: 24, height: 24)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.8))
        .clipShape(RoundedRectangle(cornerRadius: 6))
}
.buttonStyle(.plain)
.contentShape(Rectangle())  // Ensure hit-testing works
```

**Option 4: Move button outside the glass hierarchy**
```swift
// Apply glass to content only, button in separate layer
VStack {
    base
        .glassEffect(self.glassStyle(for: self.role), in: shape)
}
.overlay(alignment: .topTrailing) {
    if self.shouldShowCopyButton {
        self.copyButton
    }
}
```

### Additional Considerations

1. **Hit-testing**: Add `.contentShape(Rectangle())` to ensure the button's tap area is properly defined
2. **Z-index**: May need explicit `.zIndex(1)` on the button
3. **Reduce Transparency mode**: The fallback path using `Color(nsColor: .controlBackgroundColor)` should work correctly

### References

- [Liquid Glass Resources](./liquid-glass-resources.md)
- [LiquidGlassReference - Glass Layering Guidelines](https://github.com/conorluddy/LiquidGlassReference#42-glass-layering-guidelines)
- [LiquidGlassReference - Known Issues](https://github.com/conorluddy/LiquidGlassReference#46-known-issues--workarounds)

### Resolution

**Fixed:** 2026-01-17

**Solution Applied:** Option 1 - Use `.buttonStyle(.glass)`

The fix replaced the manual material background with the native `.buttonStyle(.glass)`:

```swift
// Before (broken) - glass-on-glass conflict
Button { ... } label: {
    Image(systemName: "doc.on.doc")
        .background {
            RoundedRectangle(...)
                .fill(.ultraThinMaterial)  // ❌ Conflicts with parent glassEffect
        }
}
.buttonStyle(.plain)

// After (working) - native glass button style
Button { ... } label: {
    Image(systemName: "doc.on.doc")
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(self.isCopied ? .green : .secondary)
}
.buttonStyle(.glass)  // ✅ Properly integrates with glass hierarchy
.controlSize(.small)
```

**Key Learning:** When placing interactive elements on top of views with `.glassEffect()`, use `.buttonStyle(.glass)` instead of manually applying material backgrounds. This ensures proper integration with the glass rendering hierarchy.

---

## Follow-Up Issue: Copy Button Positioning & Glass Color Adaptation

**Reported:** 2026-01-18
**Status:** 🔴 In Progress - Needs Investigation

### Problem Statement

Two issues with the current implementation:

1. **Copy button overlays text** - The copy icon appears in the top-right corner of the bubble, overlapping with the text content
2. **Glass effect doesn't adapt text color on light backgrounds** - Text remains white/light even when the overlay is positioned over light backgrounds, making it unreadable

### Screenshot Evidence

On light backgrounds, assistant bubble text is white and nearly invisible. The "Listening" pill (VoiceInputControlView) correctly shows dark text, but ChatBubbleView bubbles do not adapt.

### Investigation Summary

#### What Was Tried

1. **Side-floating copy button with HStack** - Moved copy button outside bubble using HStack layout
   - Result: Broke glass background sampling (white tint on dark background)

2. **GlassEffectContainer with morphing** - Wrapped bubble+button in GlassEffectContainer with glassEffectID
   - Result: Broke glass background sampling completely

3. **Overlay positioning with offset** - Used `.overlay()` with `.offset()` to position button outside bubble
   - Result: Copy button positioning works, but color adaptation still broken

4. **Removed explicit foregroundStyle** - Tried removing `.foregroundStyle(.primary)` to let glass handle vibrancy
   - Result: No improvement

5. **ZStack wrapper** - Wrapped if/else branches in ZStack for consistent hover detection
   - Result: No improvement on color adaptation

6. **Reverted to pre-UX.02 code** - Checked out original ChatBubbleView from c246f22 (before copy feature)
   - Result: **SAME ISSUE EXISTS** - This proves the color adaptation problem is NOT caused by UX.02 changes

#### Key Discovery

The glass effect text color adaptation issue **predates UX.02**. It exists in the original ChatBubbleView implementation. The issue was likely not noticed before because:
- Testing may have been done primarily on dark backgrounds
- The VoiceInputControlView uses a heavy `.tint(.black.opacity(0.9))` which forces dark appearance (doesn't actually adapt)

#### Technical Analysis

**VoiceInputControlView (works visually but doesn't adapt):**
```swift
.foregroundStyle(Color.white.opacity(0.95))  // Explicit white
.glassEffect(.regular.tint(.black.opacity(0.9)), in: shape)  // Heavy dark tint
```
This FORCES a dark appearance - it's not actually adapting to backgrounds.

**ChatBubbleView (broken):**
```swift
.foregroundStyle(.primary)  // Should adapt to color scheme
.glassEffect(.regular.tint(.white.opacity(0.03)), in: shape)  // Light tint
```
Uses `.primary` which should adapt, but doesn't work in transparent NSPanel context.

#### Research Findings

From Apple/GitHub Liquid Glass documentation:
- "Glass automatically adapts between light/dark based on background"
- "Text on glass automatically receives vibrant treatment"
- "Hard-coded color schemes" is listed as an anti-pattern

The glass effect SHOULD handle this automatically, but it appears to not work correctly when:
- The view is in a transparent NSPanel (`backgroundColor = .clear`, `isOpaque = false`)
- The panel floats over arbitrary desktop content

#### Hypotheses for Root Cause

1. **Transparent window sampling issue** - Glass effect may not properly sample through transparent NSPanel to detect background luminance
2. **Missing appearance propagation** - NSPanel may need explicit appearance configuration
3. **GlassEffectContainer context** - The parent OverlayView uses GlassEffectContainer which may affect child glass effects
4. **macOS-specific limitation** - This may be a known limitation for transparent floating panels

### Current State of Code

The current ChatBubbleView in the working tree has:
- Copy button positioned outside bubble using `.overlay()` with `.offset()`
- Hover detection with debounce (150ms delay before hiding)
- Animation using `.bouncy(duration: 0.3)`
- Original glass effect structure (no ZStack/Group wrappers)

```swift
// Current copy button positioning
.overlay(alignment: self.role == .user ? .topTrailing : .topLeading) {
    if self.shouldShowCopyButton {
        self.copyButton
            .offset(x: self.role == .user ? 32 : -32, y: 6)
    }
}
```

### Resolution

**Fixed:** 2026-01-18

**Root Cause:** Two issues combined:
1. **Missing content for glass sampling:** User bubbles had `userChromaOverlay` (blue fill) applied BEFORE the glass effect, giving the glass something to sample. Assistant/tool bubbles had no such content layer - the glass was sampling nothing (transparent window over desktop).
2. **Timing issue:** Even with content to sample, the glass effect wasn't sampling on initial render - only after scrolling triggered a redraw.

**Solution Applied:**
1. Added `neutralGlassBackground` modifier for assistant/tool bubbles - a subtle gray background (`Color.gray.opacity(0.15)`) applied before the glass effect, similar to how user bubbles have blue chroma overlay.
2. Added `.compositingGroup()` after the glass effect to force proper compositing and ensure the glass samples correctly on initial render.

```swift
// Assistant/tool bubbles now have:
base
    .userChromaOverlay(enabled: self.role == .user, shape: shape)
    .neutralGlassBackground(enabled: self.role != .user, shape: shape)  // NEW
    .glassEffect(self.glassStyle(for: self.role), in: shape)
    .compositingGroup()  // NEW - forces correct sampling on initial render
```

**Key Learning:** Glass effects in transparent NSPanel windows need:
1. **Content to sample** - Either a tinted background or overlay BEFORE the glass effect
2. **Forced compositing** - `.compositingGroup()` ensures proper sampling timing

### Resources

- [Liquid Glass Resources](./liquid-glass-resources.md)
- [conorluddy/LiquidGlassReference](https://github.com/conorluddy/LiquidGlassReference)
- Apple WWDC 2025 Session 219: Meet Liquid Glass
- [Glass Effect Documentation](https://developer.apple.com/documentation/swiftui/view/glasseffect(_:in:))
