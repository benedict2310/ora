# UX.05 - Glass Artifact Mitigation for Chat Bubbles

**Epic:** UX
**Status:** In Progress (Artifacts Persist)
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

- [x] AC-1: Black outline artifacts are significantly reduced or eliminated in light mode - ✅ User verified
- [x] AC-2: Dark mode appearance is preserved or improved - ✅ User verified
- [x] AC-3: Individual floating bubble aesthetic is maintained (no opaque panels) - ✅ Verified
- [x] AC-4: VoiceInputControlView morphing still works - ✅ Unchanged
- [x] AC-5: `reduceTransparency` accessibility path still works - ✅ Code path unchanged
- [x] AC-6: All existing tests pass - ✅ 933/933 tests passed
- [x] AC-7: No new visual flickering or performance issues - ✅ User verified

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
- [Grouping with glassEffectUnion](https://www.donnywals.com/grouping-liquid-glass-components-using-glasseffectunion-on-ios-26/)
- [Morphing with glassEffectID](https://www.createwithswift.com/morphing-glass-effect-elements-into-one-another-with-glasseffectid/)
- [BarredEwe/LiquidGlass - Metal-based alternative](https://github.com/BarredEwe/LiquidGlass)

---

## 10. Additional Mitigation Techniques (From GitHub Research)

> **Last updated:** 2026-01-11
> **Reference:** See `docs/stories/ux/liquid-glass-resources.md` for full resource list.

If the current implementation (Option A + C) still shows artifacts, consider these additional approaches:

### Option G: glassEffectUnion API (HIGH PRIORITY - NEW)

**Theory:** The `glassEffectUnion(id:in:)` modifier allows multiple views to **share a single glass shape** without creating separate glass regions. Unlike putting `.glassEffect()` on a container (which creates an opaque panel), this keeps individual elements while rendering them as one glass region.

**Key insight from Donny Wals:** "By applying `glassEffectUnion(id: "chatBubbles", namespace: namespace)` to both views they become connected."

**Requirements for glassEffectUnion to work:**
1. Elements must have the **same id** to be grouped
2. The **glass effect style must be identical** for all elements
3. All components must be **tinted the same way**
4. Elements must be in the same `GlassEffectContainer`

**Implementation:**
```swift
@Namespace private var bubbleNamespace

GlassEffectContainer(spacing: 4) {
    VoiceInputControlView()
        .glassEffect(.regular.tint(.black.opacity(0.9)))
        // VoiceInput stays separate - different tint
    
    ScrollView {
        LazyVStack(spacing: 28) {
            ForEach(messages) { message in
                ChatBubbleView(message: message)
                    .glassEffect(.regular.tint(.white.opacity(0.05)))
                    .glassEffectUnion(id: "chatBubbles", in: bubbleNamespace)
            }
        }
    }
}
```

**Pros:**
- **Designed specifically for this use case** - multiple elements, one glass region
- Preserves individual bubble identity
- Should eliminate boundary artifacts entirely
- Better performance (single CABackdropLayer)

**Cons:**
- **All bubbles must have identical tint** - can't differentiate user vs assistant via tint
- May need to use overlay colors instead of glass tints for role differentiation
- Requires same glass style across all elements

**Hybrid approach for role differentiation:**
```swift
// Use glassEffectUnion for unified glass, overlay for role colors
ChatBubbleView(message: message)
    .background(
        bubbleShape.fill(roleBackgroundColor(for: message.role))
    )
    .glassEffect(.regular.tint(.white.opacity(0.03)))
    .glassEffectUnion(id: "chatBubbles", in: bubbleNamespace)

private func roleBackgroundColor(for role: Role) -> Color {
    switch role {
    case .user: return Color.blue.opacity(0.15)
    case .assistant: return Color.white.opacity(0.05)
    case .tool: return Color.white.opacity(0.08)
    }
}
```

---

### Option H: Metal-Based Custom Blur (BarredEwe/LiquidGlass)

**Theory:** Use a Metal-powered blur implementation that doesn't have the "glass cannot sample glass" limitation. This is a completely different rendering approach.

**Implementation:**
```swift
import LiquidGlass

ChatBubbleView(message: message)
    .liquidGlassBackground(
        cornerRadius: 18,
        updateMode: .once,           // Static - no animation behind bubbles
        blurScale: 0.5,              // Blur intensity 0.0-1.0
        tintColor: roleTintColor(for: message.role)
    )
```

**Pros:**
- Works on iOS 14+ (backward compatible)
- No "glass cannot sample glass" limitation
- Full control over blur intensity and tint per bubble
- Custom Metal shaders for unique effects

**Cons:**
- Third-party dependency
- Different visual aesthetic from native Liquid Glass
- May not match system UI perfectly
- Performance overhead for `.continuous` update mode

---

### Option I: Disable Liquid Glass Entirely (Nuclear Option)

**Theory:** For users who find artifacts unacceptable, provide an option to disable Liquid Glass and use solid backgrounds.

**Implementation:**
```swift
@AppStorage("useLiquidGlass") private var useLiquidGlass = true

var body: some View {
    if useLiquidGlass && !reduceTransparency {
        content.glassEffect(glassStyle, in: bubbleShape)
    } else {
        content.background(bubbleShape.fill(solidBackgroundColor))
    }
}
```

**Pros:**
- Guaranteed no artifacts
- User choice

**Cons:**
- Loses the Liquid Glass aesthetic
- More code paths to maintain

---

### Option J: CABackdropLayer Performance Insight

**Theory:** Per JuniperPhoton's research, each `CABackdropLayer` requires **3 offscreen textures**. Artifacts may be related to how these layers composite. Reducing the number of independent glass regions improves both performance AND may reduce artifacts.

**Verification steps:**
1. Use Xcode View Debugger to count `CABackdropLayer` instances
2. With `GlassEffectContainer`, there should be ONE layer for all bubbles
3. If you see multiple layers, the container isn't working correctly

**If multiple layers exist despite GlassEffectContainer:**
- Check that `.glassEffect()` is the **last modifier** on each view
- Ensure no `.mask()` is applied to glass views
- Verify no intermediate containers break the grouping

---

## 11. Recommended Next Steps

Given that artifacts persist after Option A + C implementation:

1. **Try Option G (glassEffectUnion)** - This is the most promising approach as it's specifically designed for unifying glass across multiple elements while keeping them as separate views.

2. **Verify CABackdropLayer count** - Use View Debugger to confirm we have a single layer. If not, there's a structural issue.

3. **Test with identical tints** - Temporarily make all bubbles use the same tint to verify glassEffectUnion works, then add role differentiation via overlays.

4. **Consider Option H (Metal blur) as fallback** - If native APIs can't solve this, custom Metal rendering avoids the limitation entirely.

5. **File Apple Feedback** - This appears to be a known limitation of Liquid Glass. Document the issue with screenshots and file FB with Apple.

---

## Implementation Summary

**Date:** 2026-01-16
**Branch:** `feat/UX.05-glass-artifact-mitigation`
**Commits:** 1

### Approach Implemented

**Option A + Option C** (as recommended):

1. **Increased row spacing** (Option A):
   - `OverlayLayout.rowSpacing`: 20 → 28
   - Creates more visual separation between adjacent glass bubbles

2. **Lowered tint opacities** (Option C):
   - `ChatBubbleView` user: 0.4 → 0.25
   - `ChatBubbleView` assistant: 0.06 → 0.03
   - `ChatBubbleView` tool: 0.08 → 0.04
   - `ToolStateView`: 0.08 → 0.04
   - `FollowUpPromptView`: 0.08 → 0.04

### Files Changed

- `Ora/Overlay/OverlayLayout.swift` - Increased rowSpacing
- `Ora/Overlay/ChatBubbleView.swift` - Lowered tint opacities
- `Ora/Overlay/ToolStateView.swift` - Lowered tint opacity
- `Ora/Overlay/OverlayView.swift` - Lowered FollowUpPromptView tint opacity

### Result

User verified that artifacts are significantly reduced while maintaining the floating bubble aesthetic.

## Completion Status

- [x] Implementation complete
- [x] User verified improvements
- [x] All tests passing (933/933)
