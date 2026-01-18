# Swift 6 + Liquid Glass Resources

> **Summary:** Curated resources for implementing Apple's Liquid Glass design language in Swift/SwiftUI for macOS 26 (Tahoe) and iOS 26.

---

## 🏆 Best Overall Resources

| Repository | Stars | Description | Best For |
|------------|-------|-------------|----------|
| **[conorluddy/LiquidGlassReference](https://github.com/conorluddy/LiquidGlassReference)** | 91 | **Comprehensive reference document** - covers everything from basics to advanced: API reference, morphing, containers, accessibility, UIKit integration, known issues, best practices | 📖 **Complete learning resource** |
| **[GonzaloFuentes28/LiquidGlassCheatsheet](https://github.com/GonzaloFuentes28/LiquidGlassCheatsheet)** | 145 | Clean cheatsheet with visual examples and code snippets | 🚀 Quick reference |
| **[GetStream/awesome-liquid-glass](https://github.com/GetStream/awesome-liquid-glass)** | 202 | Animated examples (slider, tab bar, menu, floating buttons) with SwiftUI code | 🎨 Animation patterns |

## 📦 Swift Packages

| Repository | Stars | Description | Platform |
|------------|-------|-------------|----------|
| **[rryam/LiquidGlasKit](https://github.com/rryam/LiquidGlasKit)** | 98 | Swift package with `.glassCard()`, `.applyGlassEffect()` modifiers | iOS 26+, fallbacks for iOS 16+ |
| **[BarredEwe/LiquidGlass](https://github.com/BarredEwe/LiquidGlass)** | 176 | Metal-powered frosted glass for **iOS 14+** - works WITHOUT iOS 26! Real-time blur with custom Metal shaders | iOS 14+ (backward compatible) |

## 🔬 Experimental / Advanced

| Repository | Stars | Description |
|------------|-------|-------------|
| **[JulianWindeck/liquid-glass](https://github.com/JulianWindeck/liquid-glass)** | 126 | Access ALL 20 private liquid glass variants via runtime tricks (macOS) - explore `NSGlassEffectView` |
| **[CruzCortes/Pixelux-Glass](https://github.com/CruzCortes/Pixelux-Glass)** | 24 | Liquid Glass for ARKit applications |
| **[zhangqifan/Insights](https://github.com/zhangqifan/Insights)** | NEW | Demo project from Grow app adaptation - UIKit+SwiftUI hybrid, glass text effects via Core Text |

## 📝 Articles & Case Studies

| Resource | Description |
|----------|-------------|
| **[Grow on iOS 26](https://fatbobman.com/en/posts/grow-on-ios26/)** | Real-world adaptation case study: hybrid UIKit+SwiftUI architecture, scroll edge effects, morph control, custom glass text via `CTFontCreatePathForGlyph` |
| **[createwithswift.com - Morphing glass effect](https://www.createwithswift.com/morphing-glass-effect-elements-into-one-another-with-glasseffectid/)** | Deep dive on `glassEffectID` for smooth morphing transitions |

---

## Key Implementation Guidelines

### Core APIs

```swift
// Basic glass effect
.glassEffect()                              // Default: .regular variant, .capsule shape
.glassEffect(.regular, in: .capsule)        // Explicit
.glassEffect(.clear, in: .circle)           // Clear variant for media-rich backgrounds

// Glass type modifiers
.glassEffect(.regular.tint(.blue))          // Add color tint
.glassEffect(.regular.interactive())        // Enable touch/hover response (iOS only)

// Button styles (preferred over manual .glassEffect() on buttons)
.buttonStyle(.glass)                        // Translucent, see-through
.buttonStyle(.glassProminent)               // Opaque, primary actions
```

### Critical Rules

1. **Glass is for navigation layer only** - NOT content (lists, tables, media)
2. **Always use `GlassEffectContainer`** for multiple glass elements:
   ```swift
   // ✅ GOOD - Efficient rendering, enables morphing
   GlassEffectContainer {
       HStack {
           Button("Edit") { }.glassEffect()
           Button("Delete") { }.glassEffect()
       }
   }
   
   // ❌ BAD - Inefficient, glass can't sample other glass
   HStack {
       Button("Edit") { }.glassEffect()
       Button("Delete") { }.glassEffect()
   }
   ```

3. **Glass cannot sample other glass** - Container provides shared sampling region

4. **Use `.buttonStyle(.glass)` for buttons** instead of manual `.glassEffect()`:
   ```swift
   // ✅ Preferred
   Button("Action") { }
       .buttonStyle(.glass)
   
   // ❌ May have issues
   Button("Action") { }
       .glassEffect(.regular.interactive())
   ```

5. **Use `.tint()` sparingly** - for primary actions only, not decoration

### Morphing Transitions

```swift
@State private var isExpanded = false
@Namespace private var namespace

GlassEffectContainer(spacing: 30) {
    Button("Toggle") {
        withAnimation(.bouncy) { isExpanded.toggle() }
    }
    .glassEffect()
    .glassEffectID("toggle", in: namespace)
    
    if isExpanded {
        Button("Action") { }
            .glassEffect()
            .glassEffectID("action", in: namespace)
    }
}
```

### glassEffectUnion - Shared Glass Region (KEY API)

Use `glassEffectUnion(id:in:)` to have **multiple views share a single glass shape** without creating separate glass regions. This is the solution for "glass cannot sample glass" artifacts:

```swift
@Namespace private var unionNamespace

GlassEffectContainer {
    VStack {
        // These two buttons share ONE glass region
        Button("Option A") { }
            .buttonStyle(.glassProminent)
            .glassEffectUnion(id: "options", in: unionNamespace)
        
        Button("Option B") { }
            .buttonStyle(.glassProminent)
            .glassEffectUnion(id: "options", in: unionNamespace)
    }
    .tint(.white.opacity(0.8))
}
```

**Requirements for glassEffectUnion:**
- Elements must have the **same id** to be grouped
- The **glass effect style must be identical** for all elements  
- All components must be **tinted the same way**
- Elements must be in the same `GlassEffectContainer`

**Reference:** [Donny Wals - Grouping Liquid Glass with glassEffectUnion](https://www.donnywals.com/grouping-liquid-glass-components-using-glasseffectunion-on-ios-26/)

### Layering Philosophy

1. **Content layer** (bottom) - No glass
2. **Navigation layer** (middle) - Liquid Glass
3. **Overlay layer** (top) - Vibrancy and fills on glass

---

## 🎨 Advanced Techniques (From GitHub Research)

### 1. Private Glass Variants (macOS - JulianWindeck/liquid-glass)

Access all 20 hidden `NSGlassEffectView` variants via runtime:

```swift
// GlassVariant enum (0-19) with different visual styles
public enum GlassVariant: Int, CaseIterable {
    case v0 = 0, v1 = 1, v2 = 2, ... v19 = 19
}

// v11 is reportedly "visually super pleasing" for general use
LiquidGlassBackground(variant: .v11, cornerRadius: 12) {
    YourContent()
}
```

**Use case:** Experiment to find the best variant for your overlay aesthetic.

### 2. Metal-Based Glass (BarredEwe/LiquidGlass)

For backward compatibility or custom blur control:

```swift
import LiquidGlass

// SwiftUI - works on iOS 14+
Button("Glass Button") { }
    .liquidGlassBackground(
        cornerRadius: 60,
        updateMode: .continuous(interval: 0.1),  // For animated backgrounds
        blurScale: 0.5,                          // Blur intensity 0.0-1.0
        tintColor: .white.withAlphaComponent(0.1)
    )

// Update modes:
// .continuous(interval:) - For animated backgrounds
// .once                  - For static dialogs (battery efficient)
// .manual                - Call invalidateBackground() yourself
```

**Use case:** Custom Metal shaders for unique blur/refraction effects not possible with native API.

### 3. Control Center Style Glass (Stack Overflow)

Achieving more translucency and luminosity on corners like macOS Control Center:

```swift
struct LiquidGlassButtonStyle: ButtonStyle {
    @State private var backgroundLuminosity: Double = 1.0
    
    private var adaptiveGlassTint: Color? {
        if backgroundLuminosity > 0.7 { return Color.black.opacity(0.2) }
        if backgroundLuminosity < 0.4 { return Color.white.opacity(0.5) }
        return nil
    }
    
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding()
            .background(adaptiveGlassTint)
            .glassEffect()
            .mask(Circle())
            .saturation(1.5)
            .brightness(0.05)
            .overlay(
                // Angular gradient stroke for edge luminosity
                Circle().stroke(
                    AngularGradient(
                        gradient: Gradient(colors: [.white, .white.opacity(0.2), .white, .white.opacity(0.2), .white]),
                        center: .center
                    ),
                    lineWidth: 0.6
                )
                .rotationEffect(.degrees(45))
                .opacity(0.7)
            )
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .animation(.bouncy, value: configuration.isPressed)
    }
}
```

### 4. Glass Text Effect (Grow App - Core Text)

Convert text glyphs to `CGPath` for glass-filled text:

```swift
// Use CTFontCreatePathForGlyph to convert glyphs to CGPath
// Combine into a custom Shape
// Pass to .glassEffect(_:in:) for glass-filled text
```

**Reference:** [zhangqifan/Insights](https://github.com/zhangqifan/Insights) demo project

### 5. Scroll Edge Effect Control

Control when glass blur activates on scroll:

```swift
// ACTIVATE scroll edge blur effect
ToolbarItem(placement: .bottomBar) { ... }

// DISABLE scroll edge blur effect  
.safeAreaInset(edge: .bottom) { ... }
```

### 6. Preventing Morph Artifacts in Navigation

When pushing view controllers, default morph can cause visual artifacts:

```swift
// Problem: leftBarButtonItem morphs awkwardly
navigationItem.leftBarButtonItem = customBarItem  // ❌

// Solution: Use titleView instead, no morph occurs
navigationItem.titleView = hostingController.view  // ✅

// Set content hugging for proper sizing
hostingController.view.setContentHuggingPriority(.fittingSizeLevel, for: .horizontal)
```

### 7. Hide Glass Background on Bar Items

```swift
barButtonItem.hidesSharedBackground = true  // Remove glass from bar item
```

---

## Known Issues (Beta)

| Issue | Workaround |
|-------|------------|
| `.glassEffect(.regular.interactive(), in: RoundedRectangle())` responds with Capsule shape | Use `.buttonStyle(.glass)` instead |
| `.glassProminent` with `.circle` has rendering artifacts | Add `.clipShape(Circle())` |
| Widgets show black background in Standard/Dark modes | Use Tinted or Transparent modes with `Color.clear` |
| Navigation bar push creates unwanted morph effects | Use `navigationItem.titleView` instead of `leftBarButtonItem` |
| Glass cannot sample other glass → black outline artifacts | Wrap in `GlassEffectContainer` |
| ToolbarItem animation is disorienting | Use stable ID: `ToolbarItem(id: "constantID")` |

---

## Accessibility (Automatic)

SwiftUI handles these automatically - **no code changes required**:

- **Reduced Transparency**: Increases frosting for clarity
- **Increased Contrast**: Stark colors and borders
- **Reduced Motion**: Tones down animations and elastic effects
- **iOS 26.1+ Tinted Mode**: User-controlled opacity (Settings → Display & Brightness → Liquid Glass)

```swift
// Only override if absolutely necessary
@Environment(\.accessibilityReduceTransparency) var reduceTransparency

.glassEffect(reduceTransparency ? .identity : .regular)
```

---

## Official Apple Resources

**WWDC 2025 Sessions:**
- Session 219: Meet Liquid Glass
- Session 323: Build a SwiftUI app with the new design
- Session 356: Get to know the new design system

**Documentation:**
- https://developer.apple.com/documentation/TechnologyOverviews/liquid-glass
- https://developer.apple.com/documentation/TechnologyOverviews/adopting-liquid-glass
- https://developer.apple.com/documentation/swiftui/view/glasseffect(_:in:)
- https://developer.apple.com/documentation/swiftui/glasseffectcontainer
- https://developer.apple.com/design/human-interface-guidelines/materials

**YouTube Tutorials (Kavsoft):**
- [Custom Liquid Morphing Menu Effect](https://www.youtube.com/watch?v=Qutp-v-g2Iw)
- [iOS 26 Custom Menu Using SwiftUI](https://www.youtube.com/watch?v=RwPsJhrPP9g)

---

*Last updated: 2026-01-11*
