# UX.04 - Unified Glass Sampling Region for Chat Overlay

**Epic:** UX
**Status:** ❌ Rejected
**Priority:** P0 (Critical - Visual Bug)
**Estimated Effort:** 2-3 days
**Dependencies:** F.07
**Target:** macOS 26 (Tahoe)
**Design Reference:** docs/stories/bugs/BUG.02-LIQUID-GLASS-BLACK-OUTLINE.md

---

## ⚠️ REJECTION NOTICE

**Date:** 2026-01-15
**Reason:** This approach does not work as designed.

Applying `.glassEffect()` to the ScrollView container creates an **opaque glass panel** instead of
individual floating glass bubbles. The implementation was attempted, merged, and immediately reverted
because it fundamentally broke the overlay's visual appearance:

- Created a solid dark rectangular background behind all bubbles
- Lost the individual floating glass bubble aesthetic
- Made the UI look significantly worse than the original

**The core assumption was wrong:** "Unified glass sampling region" via container-level `.glassEffect()`
does not produce floating bubbles with shared sampling—it produces a single opaque glass panel.

**Alternative:** See **UX.05-GLASS-ARTIFACT-MITIGATION.md** for approaches that preserve the
individual floating bubble design while mitigating black outline artifacts.

**Reverted in:** Commit `13dd98a` on main

---

## 1. Objective (Original - DO NOT IMPLEMENT)

Eliminate black outline artifacts between chat bubbles by refactoring the overlay to use a **single unified glass sampling region** instead of per-bubble glass effects. This follows Apple's Liquid Glass guidance: "Glass cannot sample other glass."

## 2. User Story

As a user, I want the chat overlay to display clean, artifact-free glass bubbles so the interface feels polished and professional in both light and dark modes.

## 3. Scope

### In Scope

- Apply single `.glassEffect()` to the chat content container (LazyVStack or encompassing view)
- Remove individual `.glassEffect()` calls from ChatBubbleView, ToolStateView, FollowUpPromptView
- Implement per-bubble styling via tinted background shapes
- Preserve VoiceInputControlView's separate glass region (it has intentional morphing behavior)
- Maintain `reduceTransparency` accessibility fallback
- Update OverlayLayout constants as needed
- Add/update tests for the new architecture

### Out of Scope

- Changing VoiceInputControlView's glass implementation (it works correctly)
- Adding new UI features beyond the glass refactor
- Changing bubble shapes or colors (preserve existing visual design)
- Performance optimization beyond what's inherent to the architectural change

## 4. Architecture Alignment

### Problem Statement

**Current Architecture (Problematic):**

```
GlassEffectContainer(spacing: N)
├── VoiceInputControlView        → .glassEffect() ✅ (intentionally separate)
└── ScrollView/LazyVStack
    ├── ChatBubbleView           → .glassEffect() ❌ (separate sampling)
    ├── ChatBubbleView           → .glassEffect() ❌ (separate sampling)
    ├── ToolStateView            → .glassEffect() ❌ (separate sampling)
    └── FollowUpPromptView       → .glassEffect() ❌ (separate sampling)
```

Each bubble independently applies `.glassEffect()`, creating separate glass regions that cannot sample each other. This causes **black outline artifacts** at bubble boundaries, especially in light mode.

**Target Architecture (Fixed):**

```
GlassEffectContainer(spacing: N)
├── VoiceInputControlView        → .glassEffect() ✅ (keep separate for morphing)
└── ScrollView/LazyVStack        → .glassEffect() ✅ (ONE unified region)
    ├── ChatBubbleView           → .background(tintedShape) ✅ (no glass)
    ├── ChatBubbleView           → .background(tintedShape) ✅ (no glass)
    ├── ToolStateView            → .background(tintedShape) ✅ (no glass)
    └── FollowUpPromptView       → .background(tintedShape) ✅ (no glass)
```

All chat content shares ONE glass sampling region. Per-bubble styling is achieved via **tinted background shapes** on top of the unified blur.

### Per-Bubble Styling Strategy

Since we can't use `.glassEffect(.tint())` on individual bubbles (that would create separate glass regions), we use **translucent background fills** on top of the unified blur:

| Role | Shape | Background Color |
|:-----|:------|:-----------------|
| User | Capsule | `Color.blue.opacity(0.3)` + chroma overlay |
| Assistant | RoundedRectangle(18) | `Color.white.opacity(0.1)` |
| Tool | RoundedRectangle(18) | `Color.white.opacity(0.12)` |
| FollowUp | RoundedRectangle(18) | `Color.white.opacity(0.08)` |
| Error | RoundedRectangle(18) | `Color.red.opacity(0.15)` |

### VoiceInputControlView Isolation

VoiceInputControlView must remain separate because:
1. It has its own `glassEffectID` for morphing animations
2. It uses a different glass tint (`.black.opacity(0.9)`)
3. It needs to visually stand apart from the chat content

### Accessibility: Reduce Transparency

The `reduceTransparency` code paths must continue to work:
- Container level: Apply `.glassEffect()` only when `!reduceTransparency`
- Bubble level: Keep using solid backgrounds for `reduceTransparency` path

## 5. Implementation Plan (Draft)

### 5.1 Files to Create

- None (this is a refactor of existing files)

### 5.2 Files to Modify

**Phase 1-2: ChatBubbleView Refactor**
- `Ora/Overlay/ChatBubbleView.swift`
  - Add `bubbleBackgroundColor(for role: Role) -> Color` method returning tinted colors
  - Refactor `bubbleContent` to use `.background(shape.fill(color))` instead of `.glassEffect()`
  - Keep `userChromaOverlay` for user bubbles
  - Preserve `reduceTransparency` path (no changes needed - already uses solid backgrounds)
  - Remove `glassStyle(for:)` method (no longer needed)

**Phase 3: ToolStateView Refactor**
- `Ora/Overlay/ToolStateView.swift`
  - Replace `.glassEffect()` with `.background(shape.fill(Color.white.opacity(0.12)))`
  - Preserve `reduceTransparency` path

**Phase 4: FollowUpPromptView Refactor**
- `Ora/Overlay/OverlayView.swift` (contains FollowUpPromptView)
  - Replace `.glassEffect()` with `.background(shape.fill(Color.white.opacity(0.08)))`
  - Preserve `reduceTransparency` path

**Phase 5: Apply Unified Glass to Container**
- `Ora/Overlay/OverlayView.swift`
  - Wrap LazyVStack content in a view that applies `.glassEffect(.regular, in: containerShape)`
  - Only apply when `!reduceTransparency`
  - Use `RoundedRectangle(cornerRadius: 12, style: .continuous)` as container shape

**Phase 6: Cleanup**
- `Ora/Overlay/OverlayLayout.swift`
  - Update documentation to reflect new architecture
  - Adjust spacing constants if needed

### 5.3 Tests to Add

- `OraTests/Overlay/OverlayLayoutTests.swift`
  - Update spacing constant tests if values changed

- `OraTests/OverlayViewsTests.swift`
  - Add test verifying ChatBubbleView produces correct background colors per role
  - Add test verifying reduceTransparency path works correctly

### 5.4 Implementation Details

**Key Code Pattern for Container Glass:**

```swift
// In OverlayView.swift - chatScrollView
private var chatScrollView: some View {
    let containerShape = RoundedRectangle(cornerRadius: 12, style: .continuous)

    return ScrollViewReader { proxy in
        ScrollView {
            LazyVStack(alignment: .leading, spacing: OverlayLayout.rowSpacing) {
                // ... all bubble views ...
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 8)
        }
        .scrollIndicators(.hidden)
        // Apply unified glass to entire scroll content
        .if(!reduceTransparency) { view in
            view.glassEffect(.regular, in: containerShape)
        }
        // ... onChange handlers ...
    }
}
```

**Key Code Pattern for Bubble Backgrounds:**

```swift
// In ChatBubbleView.swift - bubbleContent
@ViewBuilder
private var bubbleContent: some View {
    let shape = self.bubbleShape(for: self.role)
    let backgroundColor = self.bubbleBackgroundColor(for: self.role)

    let base = VStack(...) {
        // content
    }
    .padding(...)

    if self.reduceTransparency {
        // Existing solid background path (unchanged)
        base
            .userChromaOverlay(enabled: self.role == .user, shape: shape)
            .background(shape.fill(self.baseFillColor(for: self.role)))
            .overlay(shape.stroke(Color.white.opacity(0.08), lineWidth: 0.6))
    } else {
        // NEW: Translucent background on unified glass (no .glassEffect here)
        base
            .userChromaOverlay(enabled: self.role == .user, shape: shape)
            .background(shape.fill(backgroundColor))
    }
}

private func bubbleBackgroundColor(for role: Role) -> Color {
    switch role {
    case .user:
        return Color(red: 0.12, green: 0.55, blue: 0.95).opacity(0.25)
    case .assistant:
        return Color.white.opacity(0.08)
    case .tool:
        return Color.white.opacity(0.10)
    }
}
```

## 6. Acceptance Criteria

### Functional Criteria

- [ ] AC-1: No black outline artifacts between chat bubbles in light mode
- [ ] AC-2: No black outline artifacts between chat bubbles in dark mode
- [ ] AC-3: User bubbles display with blue tint and capsule shape
- [ ] AC-4: Assistant bubbles display with subtle white tint and rounded rectangle shape
- [ ] AC-5: Tool state views display with subtle tint and rounded rectangle shape
- [ ] AC-6: Follow-up prompt displays with subtle tint
- [ ] AC-7: VoiceInputControlView morphing animations still work (separate glass region)
- [ ] AC-8: `reduceTransparency` accessibility setting shows solid backgrounds (no glass)
- [ ] AC-9: `reduceMotion` accessibility setting still respected

### Non-Functional Criteria

- [ ] AC-10: Scrolling performance is not degraded with long conversations (50+ messages)
- [ ] AC-11: No visual flickering during bubble appearance/disappearance
- [ ] AC-12: Build succeeds with no new warnings
- [ ] AC-13: All existing tests pass

## 7. Verification Plan

### Automated Tests

- [ ] Run `./build.sh test` - all tests pass
- [ ] Run Thread Sanitizer: `./build.sh test-tsan` - no threading issues

### Manual Tests

**Light Mode:**
- [ ] Short conversation (2-3 messages) - no black outlines
- [ ] Long conversation (10+ messages) with scrolling - no black outlines
- [ ] Tool proposal display - no black outlines
- [ ] Follow-up prompt display - no black outlines
- [ ] VoiceInputControlView state transitions - morphing works

**Dark Mode:**
- [ ] Repeat all light mode tests

**Accessibility:**
- [ ] Enable "Reduce Transparency" - bubbles show solid backgrounds
- [ ] Enable "Reduce Motion" - no morphing animations

**Performance:**
- [ ] Scroll through 50+ message conversation - smooth scrolling
- [ ] Rapid message arrival (streaming) - no visual jitter

## 8. Risks & Mitigations

| Risk | Likelihood | Impact | Mitigation |
|:-----|:-----------|:-------|:-----------|
| Per-bubble tints look different than glass tints | Medium | Medium | Tune opacity values to match original appearance |
| Container glass covers gaps between bubbles | High | Low | Expected per Apple's design; entire panel is one glass surface |
| VoiceInputControlView morphing breaks | Low | High | Keep it completely isolated; don't change its implementation |
| Performance regression with large conversations | Low | Medium | LazyVStack + single glass region should improve performance |

## 9. Open Questions

1. **Q:** Should the container glass shape have rounded corners?
   **A:** Start with `RoundedRectangle(cornerRadius: 12)` to match bubble aesthetic; adjust if needed.

2. **Q:** What glass style should the container use?
   **A:** `.regular` with no tint - the per-bubble backgrounds provide the tint.

---

## Implementation Summary

(TBD after implementation.)

## Code Review Findings

(TBD by review agent.)

## Completion Status

(TBD after merge.)
