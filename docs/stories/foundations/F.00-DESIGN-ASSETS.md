# F.00 - Design Assets

**Epic:** Foundations
**Status:** Not Started
**Priority:** P1 (Important)
**Estimated Effort:** 0.5 days (asset creation) + integration
**Dependencies:** None
**Target:** macOS 26 (Tahoe)

---

## 1. Objective

Define and create all visual assets required for Ora, including the app icon, menu bar icons, and any other graphic resources.

---

## 2. Required Assets

### 2.1 App Icon

The main application icon shown in Finder, Spotlight, and About window.

**Format Requirements:**

| Asset | Size | Format | Notes |
|:------|:-----|:-------|:------|
| `AppIcon.icns` | Multi-resolution | `.icns` | macOS app icon bundle |

**Required Sizes in `.icns`:**

| Size | Scale | Filename (in iconset) | Pixels |
|:-----|:------|:---------------------|:-------|
| 16x16 | 1x | `icon_16x16.png` | 16×16 |
| 16x16 | 2x | `icon_16x16@2x.png` | 32×32 |
| 32x32 | 1x | `icon_32x32.png` | 32×32 |
| 32x32 | 2x | `icon_32x32@2x.png` | 64×64 |
| 128x128 | 1x | `icon_128x128.png` | 128×128 |
| 128x128 | 2x | `icon_128x128@2x.png` | 256×256 |
| 256x256 | 1x | `icon_256x256.png` | 256×256 |
| 256x256 | 2x | `icon_256x256@2x.png` | 512×512 |
| 512x512 | 1x | `icon_512x512.png` | 512×512 |
| 512x512 | 2x | `icon_512x512@2x.png` | 1024×1024 |

**Creation Process:**

```bash
# 1. Create an iconset folder
mkdir Ora.iconset

# 2. Add all PNG sizes (see table above)
# 3. Convert to .icns
iconutil -c icns Ora.iconset -o AppIcon.icns
```

**Design Guidelines:**
- Follow [Apple Human Interface Guidelines for App Icons](https://developer.apple.com/design/human-interface-guidelines/app-icons)
- Use rounded square shape (macOS applies mask automatically)
- Design at 1024×1024, scale down
- Avoid small text or fine details
- Consider dark/light mode appearance

---

### 2.2 Menu Bar Icons

Icons displayed in the macOS menu bar. Must be **template images** for proper light/dark mode support.

**Format Requirements:**

| Asset | Size | Format | Notes |
|:------|:-----|:-------|:------|
| `MenuBarIcon` | 18×18 pt | `.png` (template) | 1x and 2x versions |
| `MenuBarIcon@2x` | 36×36 px | `.png` (template) | Retina |

**All Menu Bar Icon States:**

| Icon Name | Purpose | Symbol Suggestion |
|:----------|:--------|:------------------|
| `menubar-idle` | Ready, waiting | Circle outline |
| `menubar-listening` | Recording speech | Filled circle / waveform |
| `menubar-thinking` | Processing | Dotted circle / spinner |
| `menubar-speaking` | TTS playback | Speaker waves |
| `menubar-error` | Error state | Warning triangle |
| `menubar-setup` | Setup required | Download arrow |

**Required Files (per icon):**

```
Assets.xcassets/
└── MenuBarIcons/
    ├── menubar-idle.imageset/
    │   ├── Contents.json
    │   ├── menubar-idle.png        (18×18 px, 1x)
    │   └── menubar-idle@2x.png     (36×36 px, 2x)
    ├── menubar-listening.imageset/
    │   ├── Contents.json
    │   ├── menubar-listening.png
    │   └── menubar-listening@2x.png
    └── ... (other states)
```

**Contents.json Template:**

```json
{
  "images" : [
    {
      "filename" : "menubar-idle.png",
      "idiom" : "mac",
      "scale" : "1x"
    },
    {
      "filename" : "menubar-idle@2x.png",
      "idiom" : "mac",
      "scale" : "2x"
    }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  },
  "properties" : {
    "template-rendering-intent" : "template"
  }
}
```

**Design Guidelines:**
- **Template images only**: Single color (black), transparency for background
- macOS automatically adapts to light/dark mode
- **Line weight**: 1.5-2pt stroke for clarity at small sizes
- **Padding**: 1-2pt padding within the 18×18pt frame
- **Simplicity**: Recognizable at a glance
- Test in both light and dark menu bar

---

### 2.3 Overlay Window Assets (Optional)

Assets used within the overlay conversation window.

| Asset | Size | Format | Notes |
|:------|:-----|:-------|:------|
| Status indicators | 8×8 pt | SF Symbol or custom | Listening, thinking, etc. |
| Tool icons | 16×16 pt | SF Symbol or custom | Calendar, contacts, etc. |

**Recommendation:** Use SF Symbols for consistency with macOS. Custom icons only if SF Symbols are insufficient.

---

## 3. Asset Catalog Structure

```
Ora/
└── Assets.xcassets/
    ├── Contents.json
    ├── AppIcon.appiconset/
    │   ├── Contents.json
    │   ├── icon_16x16.png
    │   ├── icon_16x16@2x.png
    │   ├── icon_32x32.png
    │   ├── icon_32x32@2x.png
    │   ├── icon_128x128.png
    │   ├── icon_128x128@2x.png
    │   ├── icon_256x256.png
    │   ├── icon_256x256@2x.png
    │   ├── icon_512x512.png
    │   └── icon_512x512@2x.png
    ├── MenuBarIcons/
    │   ├── menubar-idle.imageset/
    │   ├── menubar-listening.imageset/
    │   ├── menubar-thinking.imageset/
    │   ├── menubar-speaking.imageset/
    │   ├── menubar-error.imageset/
    │   └── menubar-setup.imageset/
    └── AccentColor.colorset/
        └── Contents.json
```

---

## 4. Placeholder Implementation

Until custom icons are created, use SF Symbols:

**StatusBarController.swift (placeholder):**

```swift
private func iconForState(_ state: State) -> NSImage? {
    let symbolName: String
    switch state {
    case .idle:
        symbolName = "circle"
    case .listening:
        symbolName = "circle.fill"
    case .thinking:
        symbolName = "circle.dotted"
    case .speaking:
        symbolName = "speaker.wave.2.fill"
    case .error:
        symbolName = "exclamationmark.triangle"
    case .setupRequired:
        symbolName = "arrow.down.circle"
    }
    
    let config = NSImage.SymbolConfiguration(pointSize: 16, weight: .regular)
    let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "Ora")?
        .withSymbolConfiguration(config)
    image?.isTemplate = true
    return image
}
```

**With Custom Icons:**

```swift
private func iconForState(_ state: State) -> NSImage? {
    let imageName: String
    switch state {
    case .idle: imageName = "menubar-idle"
    case .listening: imageName = "menubar-listening"
    case .thinking: imageName = "menubar-thinking"
    case .speaking: imageName = "menubar-speaking"
    case .error: imageName = "menubar-error"
    case .setupRequired: imageName = "menubar-setup"
    }
    
    let image = NSImage(named: imageName)
    image?.isTemplate = true
    return image
}
```

---

## 5. App Icon Design Brief

**Concept Suggestions:**

| Concept | Description |
|:--------|:------------|
| **Waveform Circle** | Circular icon with stylized audio waveform, suggesting voice |
| **Speech Bubble** | Modern speech bubble with subtle waveform or "O" |
| **Abstract "O"** | Stylized letter "O" with audio/voice element |
| **Microphone** | Minimalist microphone icon with distinctive style |

**Color Palette:**
- Primary: System accent color compatible (blue-ish works well)
- Consider gradient for depth
- Should look good on light and dark backgrounds

**Style:**
- Modern, clean, minimal
- Consistent with macOS Sonoma+ design language
- Avoid photorealistic elements
- Single focal point

---

## 6. Acceptance Criteria

### App Icon
- [ ] **AC-1:** `.icns` file with all 10 required sizes
- [ ] **AC-2:** Added to `Assets.xcassets/AppIcon.appiconset`
- [ ] **AC-3:** Displays correctly in Finder and About window
- [ ] **AC-4:** Looks good at all sizes (16px to 1024px)

### Menu Bar Icons
- [ ] **AC-5:** All 6 states created (idle, listening, thinking, speaking, error, setup)
- [ ] **AC-6:** Template images (single color, transparency)
- [ ] **AC-7:** 1x and 2x versions for each state
- [ ] **AC-8:** Displays correctly in light and dark menu bar
- [ ] **AC-9:** Added to `Assets.xcassets/MenuBarIcons/`

### Integration
- [ ] **AC-10:** `StatusBarController` updated to use custom icons
- [ ] **AC-11:** App icon appears in build product

---

## 7. Implementation Checklist

- [ ] Design app icon at 1024×1024
- [ ] Export all required app icon sizes
- [ ] Create `.iconset` folder with all PNGs
- [ ] Convert to `.icns` using `iconutil`
- [ ] Design menu bar icons (all 6 states)
- [ ] Export menu bar icons at 1x and 2x
- [ ] Create Asset Catalog structure
- [ ] Add `Contents.json` for each imageset
- [ ] Update `StatusBarController` to use custom icons
- [ ] Test in light and dark mode
- [ ] Test on Retina and non-Retina displays

---

## 8. Resources

- [Apple HIG: App Icons](https://developer.apple.com/design/human-interface-guidelines/app-icons)
- [Apple HIG: Menu Bar Icons](https://developer.apple.com/design/human-interface-guidelines/components/system-experiences/the-menu-bar)
- [SF Symbols App](https://developer.apple.com/sf-symbols/) - Reference for icon style
- [iconutil man page](x-man-page://1/iconutil) - CLI tool for icns creation

---

## 9. Notes

### Template Images

Menu bar icons **must** be template images for proper appearance:
- Single color (typically black)
- Use alpha channel for transparency
- macOS automatically inverts for dark menu bar
- Set `isTemplate = true` in code or via Asset Catalog

### Testing Checklist

Before finalizing icons:
- [ ] Light menu bar (light mode)
- [ ] Dark menu bar (dark mode)
- [ ] Retina display
- [ ] Non-Retina display (if available)
- [ ] Various accent colors
- [ ] Finder icon sizes (16, 32, 64, 128, 256, 512)
- [ ] Spotlight search results
