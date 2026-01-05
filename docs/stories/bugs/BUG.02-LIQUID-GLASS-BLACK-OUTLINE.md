# BUG.02 - Liquid Glass Black Outline Artifact

**Status:** ✅ Fixed
**Priority:** P2 (Visual polish)
**Affects:** Light mode only (dark mode appears fixed)
**Target:** macOS 26 (Tahoe)
**Fixed:** 2026-01-05

---

## 1. Problem Description

Black outline/border artifacts appear around glass effect elements in the overlay UI when in **light mode**. The issue appears to be fixed in dark mode after recent changes.

**Affected components:**
- Chat bubbles (ChatBubbleView)
- Confirmation dialog (ToolStateView)
- Possibly the outer GlassEffectContainer

---

## 2. Root Cause Analysis

### Glass Effect Architecture

The overlay uses nested glass effects:
1. **Outer container:** `GlassEffectContainer(spacing: 12)` - macOS system component
2. **Inner elements:** Individual `.glassEffect()` modifiers on bubbles

### Key Constraint
> "Glass cannot sample other glass; container provides shared sampling region."

`GlassEffectContainer` is supposed to solve this by providing a unified sampling region, but artifacts can still occur due to:
- Modifier order issues
- Clipping/masking after glass effect
- Conflicting edge computations

---

## 3. Research: Fixes for Liquid Glass Black Outlines

### Fix A — Use shape-aware glass instead of clipping/masking after

**Don't do this (causes artifacts):**
```swift
content
  .glassEffect()
  .clipShape(RoundedRectangle(cornerRadius: 24))
```

**Do this instead:**
```swift
content
  .glassEffect(in: .rect(cornerRadius: 24))
```

**Status:** ✅ Already implemented - all glass effects use `in: shape` parameter

### Fix B — Make glassEffect the last modifier

**Pattern:**
- Do layout first (frame, padding, alignment)
- Build bubble background
- Apply `.glassEffect(...)` **last**
- Avoid additional clipShape/mask after it

**Status:** ✅ Implemented
- ChatBubbleView: `userChromaOverlay` moved BEFORE `glassEffect`
- VoiceInputControlView: Uses `compositingGroup()` before shadow

### Fix C — Avoid .mask() on glass containers

Use single unified Shape for glass effect, avoid mask modifier.

**Status:** ✅ Not using mask

### Fix D — UIKit interop layer rounding

Not applicable - using pure SwiftUI glass effects.

---

## 4. The Adaptivity vs Artifact Tradeoff

### Glass Variants

| Variant | Background Adaptivity | Artifact Risk |
|:--------|:---------------------|:--------------|
| `.regular` | Full (light/dark) | Higher |
| `.clear` | Limited | Lower |
| `.identity` | None | Unknown |

### Current Implementation

Using `.regular` variant for background adaptivity:

```swift
// ChatBubbleView.swift
private func glassStyle(for role: Role) -> Glass {
    switch role {
    case .user:
        return .regular.tint(Color(...).opacity(0.4))
    case .assistant:
        return .regular.tint(.white.opacity(0.06))
    case .tool:
        return .regular.tint(.white.opacity(0.08))
    }
}

// ToolStateView.swift
.glassEffect(.regular.tint(.white.opacity(0.08)), in: shape)
```

### Previous Attempt

Changed to `.clear` variant which reduced artifacts but broke background adaptivity on dark backgrounds.

---

## 5. Current File Locations

| File | Component | Glass Usage |
|:-----|:----------|:------------|
| `Ora/Overlay/OverlayView.swift:25` | Outer container | `GlassEffectContainer(spacing: 12)` |
| `Ora/Overlay/ChatBubbleView.swift:96-106` | Chat bubbles | `.regular.tint(...)` |
| `Ora/Overlay/ToolStateView.swift:54-56` | Confirm dialog | `.regular.tint(.white.opacity(0.08))` |
| `Ora/Overlay/VoiceInputControlView.swift:64-74` | State indicator | `.regular.tint(.black.opacity(0.9))` |
| `Ora/Overlay/OverlayView.swift:234-237` | Follow-up prompt | `.regular.tint(.white.opacity(0.08))` |

---

## 6. Options to Investigate

### Option 1: Conditional variant based on color scheme
```swift
@Environment(\.colorScheme) var colorScheme

var glassVariant: Glass {
    colorScheme == .dark ? .regular : .clear
}
```
- Pro: Best of both worlds
- Con: May cause visual discontinuity when switching modes

### Option 2: Adjust tint opacity further
Lower opacity might reduce artifact visibility while keeping `.regular`:
```swift
.regular.tint(.white.opacity(0.02))  // Even lower
```

### Option 3: Try .identity variant
```swift
.glassEffect(.identity, in: shape)
```
- Pro: No tint, might avoid artifacts
- Con: No background adaptivity

### Option 4: Remove nested glass effects
Don't apply `.glassEffect()` to inner bubbles when inside `GlassEffectContainer`:
```swift
// Let GlassEffectContainer handle all glass rendering
base
    .background(shape.fill(Color.white.opacity(0.1)))
```

### Option 5: File Apple Feedback
If this is a macOS 26 bug, report to Apple with reproduction case.

---

## 7. Acceptance Criteria

- [ ] No black outline artifacts in light mode
- [ ] No black outline artifacts in dark mode (currently working)
- [ ] Background adaptivity works correctly in both modes
- [ ] Glass morphing transitions still work in GlassEffectContainer

---

## 8. Test Plan

1. Launch app in light mode → check for black outlines on:
   - Outer panel border
   - User chat bubbles
   - Assistant chat bubbles
   - Confirmation dialog
   - State indicator pill

2. Launch app in dark mode → verify no artifacts

3. Switch between light/dark mode → verify glass adapts correctly

4. Test glass morphing (VoiceInputControlView state changes)

---

## 9. Research Prompt

Use this prompt with web search tools to find solutions:

```
SwiftUI macOS 26 Tahoe iOS 26 liquid glass glassEffect black outline border artifact fix 2025 2026

Specific queries to try:
- "SwiftUI glassEffect black border artifact fix"
- "GlassEffectContainer nested glass rendering issue"
- "liquid glass dark outline light mode SwiftUI"
- "SwiftUI .regular vs .clear glass variant artifacts"
- "macOS 26 glass effect rendering bug workaround"
- "WWDC 2025 liquid glass best practices edge artifacts"
```

Also check:
- Apple Developer Forums for "glassEffect artifact" or "liquid glass border"
- GitHub issues on SwiftUI glass effect repos
- Medium/Dev.to articles on liquid glass implementation pitfalls

### Expected Deliverables from Research

When using AI-assisted search, gather and document:

1. **Code snippets** - Any working solutions with `.glassEffect()` that avoid black outlines
2. **Modifier order** - Confirmed correct order of modifiers for nested glass effects
3. **Variant comparison** - Real-world experiences with `.regular` vs `.clear` vs `.identity`
4. **GlassEffectContainer tips** - Best practices for spacing parameter and nested elements
5. **Light mode specific fixes** - Any workarounds specifically for light mode artifacts
6. **Apple Feedback references** - Any filed radars or feedback IDs for this issue
7. **Version-specific info** - Whether this is fixed in newer macOS 26.x betas

Format findings as actionable code changes we can apply to:
- `ChatBubbleView.swift`
- `ToolStateView.swift`
- `VoiceInputControlView.swift`
- `OverlayView.swift`

---

## 10. References

- Research document: `/Users/bene/Downloads/fixes_for_liquid_glass_black_outlines_a_d.md`
- [Apple GlassEffectContainer Documentation](https://developer.apple.com/documentation/swiftui/glasseffectcontainer/)
- [LiquidGlassReference on GitHub](https://github.com/conorluddy/LiquidGlassReference)
- [Adopting Liquid Glass: Experiences and Pitfalls](https://juniperphoton.substack.com/p/adopting-liquid-glass-experiences)
