# UX.05 - Glass Artifact Mitigation for Chat Bubbles

**Epic:** UX
**Status:** Open
**Priority:** P1 (Visual Polish)
**Estimated Effort:** 1-2 days
**Dependencies:** F.07
**Target:** macOS 26 (Tahoe)
**Related:** docs/stories/bugs/BUG.02-LIQUID-GLASS-BLACK-OUTLINE.md, UX.04 (rejected)

---

## 1. Objective

Reduce or eliminate black outline artifacts between adjacent glass chat bubbles while **preserving the individual floating bubble aesthetic**. Unlike UX.04's rejected "unified glass" approach, these solutions keep per-bubble `.glassEffect()` calls.

## 2. User Story

As a user, I want the chat overlay to display clean glass bubbles without visible dark borders between them, especially in light mode.

## 3. Background

### The Problem

When multiple views with `.glassEffect()` are adjacent, dark outline artifacts appear at their boundaries. This is because "glass cannot sample other glass"—each glass region samples the background behind it independently, causing visual discontinuities where regions meet.

### What We Already Have

Per BUG.02, these fixes are already implemented:
- ✅ `GlassEffectContainer` wraps all glass elements
- ✅ Shape-aware glass (`in: shape` parameter)
- ✅ `.glassEffect()` as last modifier
- ✅ No `.mask()` on glass containers

### What Failed (UX.04)

Applying `.glassEffect()` to the ScrollView container created an opaque glass panel instead of floating bubbles. This fundamentally broke the visual design and was reverted.

### Current Architecture

```
GlassEffectContainer(spacing: 4)
├── VoiceInputControlView        → .glassEffect(.regular.tint(.black.opacity(0.9)))
└── chatScrollView (no glass)
    └── LazyVStack(spacing: 20)
        ├── ChatBubbleView       → .glassEffect(.regular.tint(...))
        ├── ChatBubbleView       → .glassEffect(.regular.tint(...))
        ├── ToolStateView        → .glassEffect(.regular.tint(...))
        └── FollowUpPromptView   → .glassEffect(.regular.tint(...))
```

## 4. Proposed Solutions

### Option A: Increase Row Spacing (Low Risk)

**Theory:** If bubbles are farther apart, the boundary artifacts become less noticeable or disappear entirely because glass regions don't visually overlap.

**Implementation:**
```swift
// OverlayLayout.swift
static let rowSpacing: CGFloat = 32  // Was 20
```

**Pros:**
- Simple one-line change
- No architectural changes
- Easy to tune

**Cons:**
- May make UI feel sparse
- Doesn't fully eliminate artifacts, just makes them less visible

---

### Option B: Conditional Glass Variant (Medium Risk)

**Theory:** The `.clear` variant has fewer artifacts than `.regular`, but loses background adaptivity. Use `.clear` in light mode (where artifacts are most visible) and `.regular` in dark mode.

**Implementation:**
```swift
// ChatBubbleView.swift
@Environment(\.colorScheme) private var colorScheme

private func glassStyle(for role: Role) -> Glass {
    let variant: Glass = colorScheme == .light ? .clear : .regular

    switch role {
    case .user:
        return variant.tint(Color(red: 0.12, green: 0.55, blue: 0.95).opacity(0.4))
    case .assistant:
        return variant.tint(.white.opacity(0.06))
    case .tool:
        return variant.tint(.white.opacity(0.08))
    }
}
```

**Apply same pattern to:**
- `ToolStateView.swift`
- `FollowUpPromptView` in `OverlayView.swift`

**Pros:**
- Targets the specific problem (light mode artifacts)
- Preserves dark mode appearance

**Cons:**
- May cause visual discontinuity when switching modes
- `.clear` variant may look different than desired in light mode

---

### Option C: Lower Tint Opacity (Low Risk)

**Theory:** Reducing the tint opacity may make boundary artifacts less visible while maintaining the glass effect.

**Implementation:**
```swift
// ChatBubbleView.swift
private func glassStyle(for role: Role) -> Glass {
    switch role {
    case .user:
        return .regular.tint(Color(red: 0.12, green: 0.55, blue: 0.95).opacity(0.25)) // Was 0.4
    case .assistant:
        return .regular.tint(.white.opacity(0.03))  // Was 0.06
    case .tool:
        return .regular.tint(.white.opacity(0.04))  // Was 0.08
    }
}
```

**Pros:**
- Simple opacity adjustments
- No architectural changes

**Cons:**
- May make bubbles too subtle/hard to distinguish
- Doesn't address root cause

---

### Option D: Decrease GlassEffectContainer Spacing (Low Risk)

**Theory:** The `spacing` parameter controls when glass elements merge. A smaller value means elements must be closer to merge. Setting it very low (or 0) may prevent partial merging that causes artifacts.

**Implementation:**
```swift
// OverlayView.swift
GlassEffectContainer(spacing: 0) {  // Was 4
    // ...
}

// OverlayLayout.swift
static let containerSpacing: CGFloat = 0  // Was 4
```

**Pros:**
- One-line change
- May prevent edge-case merging behavior

**Cons:**
- May affect VoiceInputControlView morphing
- Unclear if this addresses the sampling artifact issue

---

### Option E: Window Shadow Invalidation (Experimental)

**Theory:** Per Apple Forums thread, calling `invalidateShadow()` on NSWindow can clear visual artifacts from transparent views.

**Implementation:**
```swift
// OverlayWindowController.swift
// After layout changes or scrolling
self.window?.invalidateShadow()
```

**Pros:**
- May fix edge rendering issues
- Non-invasive

**Cons:**
- May cause flickering if called too frequently
- Unclear if it addresses this specific artifact type

---

### Option F: Hybrid - Spacing + Conditional Variant

**Combine Options A and B for maximum effect.**

**Implementation:**
1. Increase `rowSpacing` to 28-32
2. Use `.clear` variant in light mode only
3. Keep `.regular` variant in dark mode

---

## 5. Recommended Approach

**Start with Option A (spacing) + Option C (lower opacity)** as they are lowest risk:

1. Increase `rowSpacing` from 20 to 28
2. Lower tint opacities slightly
3. Test in both light and dark mode
4. If artifacts persist, try Option B (conditional variant)

## 6. Implementation Plan

### Phase 1: Spacing Adjustment
- `Ora/Overlay/OverlayLayout.swift` - Increase `rowSpacing`

### Phase 2: Opacity Tuning
- `Ora/Overlay/ChatBubbleView.swift` - Reduce tint opacities in `glassStyle(for:)`
- `Ora/Overlay/ToolStateView.swift` - Reduce tint opacity
- `Ora/Overlay/OverlayView.swift` - Reduce FollowUpPromptView tint opacity

### Phase 3: Conditional Variant (if needed)
- Add `@Environment(\.colorScheme)` to affected views
- Implement conditional `.clear` vs `.regular` based on color scheme

### Phase 4: Window Shadow (if needed)
- `Ora/Overlay/OverlayWindowController.swift` - Add `invalidateShadow()` calls

## 7. Acceptance Criteria

- [ ] AC-1: Black outline artifacts are significantly reduced or eliminated in light mode
- [ ] AC-2: Dark mode appearance is preserved or improved
- [ ] AC-3: Individual floating bubble aesthetic is maintained (no opaque panels)
- [ ] AC-4: VoiceInputControlView morphing still works
- [ ] AC-5: `reduceTransparency` accessibility path still works
- [ ] AC-6: All existing tests pass
- [ ] AC-7: No new visual flickering or performance issues

## 8. Verification Plan

### Manual Tests

**Light Mode:**
- [ ] Launch app, check for black outlines between bubbles
- [ ] Scroll through conversation, verify no artifacts appear
- [ ] Test with 2-3 bubbles (minimal case)
- [ ] Test with 10+ bubbles (scrolling case)

**Dark Mode:**
- [ ] Verify bubbles still look correct
- [ ] Verify no regression in appearance

**Mode Switching (if Option B implemented):**
- [ ] Switch between light/dark mode
- [ ] Verify smooth transition without jarring changes

## 9. Research Sources

- [Understanding GlassEffectContainer](https://dev.to/arshtechpro/understanding-glasseffectcontainer-in-ios-26-2n8p)
- [Grouping elements in GlassEffectContainer](https://www.createwithswift.com/grouping-elements-within-a-glass-effect-container-in-swiftui/)
- [Glassifying custom SwiftUI views](https://swiftwithmajid.com/2025/07/23/glassifying-custom-swiftui-views-groups/)
- [Liquid Glass pitfalls](https://juniperphoton.substack.com/p/adopting-liquid-glass-experiences)
- [LiquidGlassReference](https://github.com/conorluddy/LiquidGlassReference)
- [Apple Forums - Graphics artifacts with transparency](https://developer.apple.com/forums/thread/696742)

---

## Implementation Summary

(TBD after implementation.)

## Code Review Findings

(TBD by review agent.)

## Completion Status

(TBD after merge.)
