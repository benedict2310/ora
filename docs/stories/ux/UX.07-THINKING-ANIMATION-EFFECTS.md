# UX.07 - Thinking & Tool State Animation Effects

**Epic:** UX
**Status:** Complete
**Priority:** P2 (Polish)
**Estimated Effort:** 1-2 days
**Dependencies:** F.07
**Target:** macOS 26 (Tahoe)

---

## 1. Objective

Improve visual feedback during "thinking" and "tool calling" states with polished animations:
1. **Thinking state**: Animated shimmer/spotlight effect on text
2. **Tool calling state**: Chromatic aberration effect to indicate processing

---

## 2. User Story

As a user, I want visual feedback during thinking and tool operations that feels modern and polished, indicating the assistant is actively working.

---

## 3. Scope

### In Scope
- Shimmer/spotlight animation for thinking text
- Chromatic aberration effect for tool operations
- Accessibility: respect `reduceMotion` setting

### Out of Scope
- Audio feedback
- Haptic feedback
- Custom progress indicators

---

## 4. Research & Resources

### 4.1 Repositories Investigated

| Repository | Stars | Description | Verdict |
|------------|-------|-------------|---------|
| [markiv/SwiftUI-Shimmer](https://github.com/markiv/SwiftUI-Shimmer) | ~500 | Lightweight shimmer modifier | ⚠️ Has open crash issue #26 |
| [twostraws/Inferno](https://github.com/twostraws/Inferno) | ~1000 | Metal shaders for SwiftUI | ✅ Best option - has both effects |

### 4.2 Inferno Repository Details

**Author:** Paul Hudson (Hacking with Swift)
**License:** MIT
**Requirements:** iOS 17+ / macOS 14+
**Releases:** None (commits to main only)

**Relevant Shaders:**
- `Shimmer.metal` - Spotlight effect that sweeps across content
- `ColorPlanes.metal` - Chromatic aberration (RGB channel separation)

**Open Issues:**
- #41: Xcode package import issue (not macOS-specific)
- #32: ContentPreviewSelector doesn't work on iOS (not macOS)

### 4.3 Key Technical Findings

#### Shader Types in SwiftUI
1. **colorEffect** - Modifies pixel colors, receives `position` and `color` automatically
2. **layerEffect** - Can sample neighboring pixels, receives `SwiftUI::Layer`
3. **distortionEffect** - Distorts geometry

#### Text View Limitations
- `colorEffect` does NOT work reliably on `Text` views directly
- Text needs special handling:
  - Use `foregroundStyle(shader)` since Shader conforms to ShapeStyle
  - Or wrap in container with `.drawingGroup()` first
  - Or use pure SwiftUI animation (LinearGradient + mask)

**Reference:** [Applying Metal shader to text in SwiftUI](https://augmentedcode.io/2023/08/07/applying-metal-shader-to-text-in-swiftui/)

---

## 5. Implementation Attempts

### Attempt 1: Metal Shader with colorEffect (FAILED)

**Approach:** Copy Inferno's `Shimmer.metal` and apply via `.colorEffect()`

```swift
Text("Thinking")
    .visualEffect { view, proxy in
        view.colorEffect(
            ShaderLibrary.shimmer(
                .float2(proxy.size),
                .float(elapsedTime),
                .float(duration),
                .float(gradientWidth),
                .float(maxLightness)
            )
        )
    }
```

**Result:** Text disappeared, only gray bubble visible.

**Root Cause:** `colorEffect` doesn't work properly on Text views.

### Attempt 2: Pure SwiftUI Shimmer - Wrong Mask Direction (FAILED)

**Approach:** Use LinearGradient with mask overlay

```swift
content
    .overlay {
        LinearGradient(colors: [.clear, .white.opacity(0.6), .clear], ...)
            .offset(x: phase * width)
            .mask(content)
    }
    .onAppear {
        withAnimation(.linear(duration: duration).repeatForever()) {
            phase = 1.0
        }
    }
```

**Result:** Animation not visible.

**Root Cause:** Mask was applied BACKWARDS - was masking the gradient overlay with content, instead of masking the content with the gradient.

### Attempt 3: Pure SwiftUI Shimmer - Correct Mask (SUCCESS)

**Approach:** Based on [markiv/SwiftUI-Shimmer](https://github.com/markiv/SwiftUI-Shimmer) - mask the CONTENT with the gradient

```swift
content
    .mask(
        LinearGradient(
            gradient: Gradient(colors: [.black.opacity(0.7), .black, .black.opacity(0.7)]),
            startPoint: startPoint,
            endPoint: endPoint
        )
    )
    .animation(.linear(duration: duration).delay(0.25).repeatForever(autoreverses: false), value: isInitialState)
    .onAppear {
        DispatchQueue.main.asyncAfter(deadline: .now()) {
            isInitialState = false
        }
    }
```

**Result:** Working shimmer animation on Text views.

**Key Insight:** The gradient acts as an alpha mask - black = fully visible, transparent = hidden. By animating the gradient's `startPoint`/`endPoint`, the spotlight sweeps diagonally across the text.

### Final Implementation

**Thinking State:**
- Uses `.secondary` foregroundStyle for automatic light/dark mode adaptation
- Semibold font weight for readability
- Pure SwiftUI shimmer effect (no Metal shaders on text)
- Narrower bubble width (140px) when in thinking-only state

```swift
Text(label ?? "Thinking")
    .font(.body.weight(.semibold))
    .foregroundStyle(.secondary)
    .shimmer(active: !reduceMotion, duration: 1.2, bandSize: 0.3)
```

**Tool State:**
- Uses Metal `colorPlanes` shader for chromatic aberration
- Applied to HStack container (not directly to Text) via `.drawingGroup()`
- Animated oscillating intensity for subtle movement

```swift
HStack(spacing: 6) {
    Image(systemName: "gearshape")
    Text(label)
}
.chromaticAberration(active: !reduceMotion, intensity: 2.0, animated: true)
```

---

## 6. Files Created

```
Ora/Shaders/
├── ColorPlanes.metal      # Chromatic aberration shader
├── Shimmer.metal          # Shimmer shader (unused - doesn't work on Text)
└── ShaderEffects.swift    # SwiftUI view modifiers
```

### ColorPlanes.metal (Working)
```metal
[[ stitchable ]] half4 colorPlanes(float2 position, SwiftUI::Layer layer, float2 offset) {
    float2 red = position - (offset * 2.0);
    float2 blue = position - offset;
    half4 color = layer.sample(position);
    color.r = layer.sample(red).r;
    color.b = layer.sample(blue).b;
    return color * color.a;
}
```

### Shimmer.metal (Not Working on Text)
- Full HSL conversion for lightness modification
- Diagonal gradient sweep animation
- Works on Image views, not Text views

---

## 7. Resolved Issues

### Issue 1: Shimmer Not Applying to Text (RESOLVED)

**Symptom:** Text content disappears or animation not visible
**Root Cause:** Metal `colorEffect` doesn't work on AppKit-backed Text views, and initial pure SwiftUI approach had the mask direction backwards.

**Solution:** Use SwiftUI-Shimmer's approach - mask the content WITH the gradient (not overlay masked with content). The gradient's start/end points are animated to create the sweeping effect.

---

## 8. Acceptance Criteria

- [x] AC-1: Thinking state shows animated shimmer/spotlight on text
- [x] AC-2: Tool calling state has chromatic aberration effect
- [x] AC-3: Animations respect `reduceMotion` accessibility setting
- [x] AC-4: No performance regression
- [x] AC-5: Works in both light and dark modes

---

## 9. References

### Articles
- [Applying Metal shader to text in SwiftUI](https://augmentedcode.io/2023/08/07/applying-metal-shader-to-text-in-swiftui/)
- [How to add Metal shaders to SwiftUI views](https://www.hackingwithswift.com/quick-start/swiftui/how-to-add-metal-shaders-to-swiftui-views-using-layer-effects)
- [Metal Shaders in SwiftUI - Design+Code](https://designcode.io/swiftui-handbook-metal-shaders/)
- [Create custom visual effects with SwiftUI - WWDC24](https://developer.apple.com/videos/play/wwdc2024/10151/)

### Apple Documentation
- [colorEffect(_:isEnabled:)](https://developer.apple.com/documentation/swiftui/view/coloreffect(_:isenabled:))
- [layerEffect(_:maxSampleOffset:isEnabled:)](https://developer.apple.com/documentation/swiftui/view/layereffect(_:maxsampleoffset:isenabled:))
- [Shader](https://developer.apple.com/documentation/swiftui/shader)

### GitHub
- [twostraws/Inferno](https://github.com/twostraws/Inferno) - Source of shaders
- [markiv/SwiftUI-Shimmer](https://github.com/markiv/SwiftUI-Shimmer) - Alternative (has crash issues)

---

*Created: 2026-01-21*
*Completed: 2026-01-21*
