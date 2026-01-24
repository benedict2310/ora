# Shader-Based Bubble Animation Research

**Branch:** `explore/shader-bubble-animations`
**Date:** 2026-01-22
**Status:** Research Complete

---

## 1. Executive Summary

This document explores options for animating response bubbles using shaders in SwiftUI, without adding new dependencies. The project already has a working shader infrastructure that can be extended.

**Key Finding:** SwiftUI offers three shader types via Metal (`colorEffect`, `layerEffect`, `distortionEffect`) plus powerful built-in animation APIs. The existing `GlassChatPreview` in `agent-tools/` provides an ideal playground for experimentation.

---

## 2. Existing Infrastructure

### Current Shader Files
```
Ora/Shaders/
├── ColorPlanes.metal      # Chromatic aberration (layerEffect)
├── Shimmer.metal          # Shimmer sweep (colorEffect - doesn't work on Text)
└── ShaderEffects.swift    # SwiftUI view modifiers
```

### Test Playground
```
agent-tools/GlassChatPreview/   # Perfect for experimenting with bubble animations
```

---

## 3. SwiftUI Shader Types

SwiftUI (iOS 17+ / macOS 14+) provides three shader modifier types:

| Type | Signature | Use Case |
|------|-----------|----------|
| **colorEffect** | `half4 fn(float2 position, half4 color, ...)` | Modify pixel colors (hue, saturation, etc.) |
| **layerEffect** | `half4 fn(float2 position, SwiftUI::Layer layer, ...)` | Sample neighboring pixels (blur, ripple) |
| **distortionEffect** | `float2 fn(float2 position, ...)` | Warp geometry (wave, wobble, jelly) |

### Important Limitations
- **colorEffect does NOT work on Text views** - use `foregroundStyle(shader)` or wrap in `.drawingGroup()`
- **layerEffect requires `maxSampleOffset`** - tells SwiftUI how far pixels may be displaced
- **Shaders have no concept of time** - must drive animation from SwiftUI via `TimelineView`

---

## 4. Animation Options (No New Dependencies)

### Option A: Pure SwiftUI (Simplest)

Already available in SwiftUI without Metal shaders:

```swift
// Breathing/pulsing effect
.phaseAnimator([1.0, 1.02, 1.0]) { view, phase in
    view.scaleEffect(phase)
} animation: { _ in .easeInOut(duration: 0.8) }

// Complex multi-stage animations
.keyframeAnimator(initialValue: AnimationState(), trigger: trigger) { view, state in
    view
        .scaleEffect(state.scale)
        .opacity(state.opacity)
} keyframes: { _ in
    KeyframeTrack(\.scale) {
        SpringKeyframe(1.05, duration: 0.15)
        SpringKeyframe(1.0, duration: 0.3)
    }
}

// Spring/bouncy built-in animations
.animation(.spring(response: 0.4, dampingFraction: 0.7), value: isActive)
.animation(.bouncy(duration: 0.35), value: state)
```

**Pros:** No Metal code needed, automatic accessibility (reduceMotion), simpler
**Cons:** Limited to built-in transforms, can't do pixel-level effects

### Option B: Metal Distortion Effects

For geometry-warping effects like waves, wobble, or jelly:

#### Wave Effect
```metal
// Wave.metal
#include <metal_stdlib>
using namespace metal;

[[ stitchable ]] float2 wave(
    float2 position,
    float wavelength,
    float amplitude,
    float time
) {
    float offset = sin(time + position.x / wavelength) * amplitude;
    return position - float2(0, offset);
}
```

```swift
// SwiftUI usage
TimelineView(.animation) { timeline in
    let time = Float(startDate.distance(to: timeline.date))
    content
        .visualEffect { view, proxy in
            view.distortionEffect(
                ShaderLibrary.wave(
                    .float(50),  // wavelength
                    .float(3),   // amplitude
                    .float(time)
                ),
                maxSampleOffset: CGSize(width: 0, height: 10)
            )
        }
}
```

#### Wobble/Jelly Effect
```metal
// Wobble.metal
#include <metal_stdlib>
using namespace metal;

[[ stitchable ]] float2 wobble(
    float2 position,
    float2 size,
    float time,
    float intensity
) {
    float2 uv = position / size;
    // Horizontal wobble based on vertical position
    float xOffset = sin(uv.y * 10.0 + time * 4.0) * intensity;
    // Vertical wobble based on horizontal position
    float yOffset = sin(uv.x * 8.0 + time * 3.0) * intensity * 0.5;
    return position + float2(xOffset, yOffset);
}
```

#### Edge Ripple on Appear
```metal
// EdgeRipple.metal
#include <metal_stdlib>
using namespace metal;

[[ stitchable ]] float2 edgeRipple(
    float2 position,
    float2 size,
    float progress,  // 0.0 to 1.0
    float intensity
) {
    float2 uv = position / size;
    float2 center = float2(0.5, 0.5);
    float dist = length(uv - center);

    // Ripple emanates from edges inward
    float wave = sin((1.0 - dist) * 20.0 - progress * 15.0);
    float decay = (1.0 - progress) * intensity;
    float2 direction = normalize(uv - center);

    return position + direction * wave * decay;
}
```

### Option C: Metal Layer Effects

For pixel-sampling effects like ripples, blur, or chromatic aberration:

#### Ripple Effect (Full Implementation)
```metal
// Ripple.metal
#include <metal_stdlib>
#include <SwiftUI/SwiftUI.h>
using namespace metal;

[[ stitchable ]] half4 ripple(
    float2 position,
    SwiftUI::Layer layer,
    float2 origin,
    float time,
    float amplitude,
    float frequency,
    float decay,
    float speed
) {
    float distance = length(position - origin);
    float delay = distance / speed;
    float t = max(0.0, time - delay);

    float rippleAmount = amplitude * sin(frequency * t) * exp(-decay * t);
    float2 n = normalize(position - origin);
    float2 newPosition = position + rippleAmount * n;

    half4 color = layer.sample(newPosition);
    // Add subtle brightness at ripple peaks
    color.rgb += 0.2 * (rippleAmount / amplitude) * color.a;

    return color;
}
```

```swift
// SwiftUI RippleModifier
struct RippleModifier: ViewModifier {
    var origin: CGPoint
    var elapsedTime: TimeInterval
    var duration: TimeInterval = 3.0
    var amplitude: Double = 12
    var frequency: Double = 15
    var decay: Double = 8
    var speed: Double = 1200

    func body(content: Content) -> some View {
        content.visualEffect { view, _ in
            view.layerEffect(
                ShaderLibrary.ripple(
                    .float2(origin),
                    .float(elapsedTime),
                    .float(amplitude),
                    .float(frequency),
                    .float(decay),
                    .float(speed)
                ),
                maxSampleOffset: CGSize(width: amplitude, height: amplitude),
                isEnabled: elapsedTime > 0 && elapsedTime < duration
            )
        }
    }
}
```

---

## 5. Recommended Animations by Bubble State

| State | Recommended Effect | Implementation |
|-------|-------------------|----------------|
| **Appear** | Scale bounce + fade | Pure SwiftUI `spring` animation |
| **User bubble** | Subtle bounce on send | `keyframeAnimator` with scale |
| **Thinking** | Shimmer (existing) | Already implemented |
| **Tool calling** | Rotating gear (existing) | Already implemented |
| **Completed** | Brief highlight + settle | Opacity pulse + slight scale |
| **Hover** | Gentle glow | Border color animation |

### Conservative Recommendation

Start with **pure SwiftUI animations** (Option A) for bubble appear/transitions:

```swift
struct BubbleAppearModifier: ViewModifier {
    let isVisible: Bool
    @State private var appeared = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(appeared ? 1.0 : 0.92)
            .opacity(appeared ? 1.0 : 0)
            .onChange(of: isVisible) { _, visible in
                if visible {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
                        appeared = true
                    }
                }
            }
    }
}
```

Only add Metal shaders if you want effects that SwiftUI can't provide natively:
- Ripple emanating from touch point
- Liquid wobble/jelly physics
- Complex distortion on appear

---

## 6. Testing Approach

### Step 1: Create Shader Playground

Copy `GlassChatPreview` to a new test app:

```bash
cp -r agent-tools/GlassChatPreview agent-tools/ShaderBubblePreview
```

### Step 2: Add Metal Shader File

Create `agent-tools/ShaderBubblePreview/Sources/ShaderBubblePreview/Shaders.metal`:

```metal
#include <metal_stdlib>
using namespace metal;

// Test shaders here before moving to Ora/Shaders/
```

### Step 3: Update Package.swift

Ensure `.metal` files are included in the target.

### Step 4: Iterate and Test

```bash
cd agent-tools/ShaderBubblePreview
swift build && swift run
```

### Step 5: Migrate Working Shaders

Move validated shaders to `Ora/Shaders/` and add view modifiers to `ShaderEffects.swift`.

---

## 7. Resources

### Official Documentation
- [WWDC24: Create custom visual effects with SwiftUI](https://developer.apple.com/videos/play/wwdc2024/10151/)
- [Apple: colorEffect](https://developer.apple.com/documentation/swiftui/view/coloreffect(_:isenabled:))
- [Apple: layerEffect](https://developer.apple.com/documentation/swiftui/view/layereffect(_:maxsampleoffset:isenabled:))
- [Apple: distortionEffect](https://developer.apple.com/documentation/swiftui/view/distortioneffect(_:maxsampleoffset:isenabled:))

### Tutorials & Examples
- [Hacking with Swift: Metal shaders with layer effects](https://www.hackingwithswift.com/quick-start/swiftui/how-to-add-metal-shaders-to-swiftui-views-using-layer-effects)
- [Jacob Bartlett: Metal in SwiftUI](https://blog.jacobstechtavern.com/p/metal-in-swiftui-how-to-write-shaders)
- [Cindori: Wave Effect Tutorial](https://cindori.com/developer/swiftui-shaders-wave)
- [swiftandcurious: Metal Ripples](https://swiftandcurious.com/2025/05/01/metalripples/)

### Libraries (MIT Licensed, can copy shaders)
- [twostraws/Inferno](https://github.com/twostraws/Inferno) - Comprehensive shader collection
- [BarredEwe/LiquidGlass](https://github.com/BarredEwe/LiquidGlass) - Metal-based glass effects (iOS 14+)

---

## 8. Next Steps

1. **Decide animation style** - Subtle/professional vs. playful/bouncy
2. **Prototype in GlassChatPreview** - Test 2-3 options
3. **Gather feedback** - Show prototypes to users
4. **Implement winner** - Add to `Ora/Shaders/` with view modifier
5. **Respect accessibility** - Always check `reduceMotion` setting

---

*Created during exploration branch `explore/shader-bubble-animations`*
