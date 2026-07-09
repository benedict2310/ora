# App Icon Setup Checklist for macOS

This checklist ensures your app icon displays correctly everywhere in macOS:
- Finder (file browser, Applications folder)
- Dock
- App Switcher (Cmd+Tab)
- Launchpad
- Spotlight search results
- System Settings → Privacy & Security (permissions lists)
- About This Mac → More Info → Applications
- Activity Monitor
- Mission Control

---

## ✅ Required Files & Structure

### 1. Asset Catalog Setup

```
YourApp/
└── Assets.xcassets/
    ├── Contents.json
    └── AppIcon.appiconset/
        ├── Contents.json
        ├── icon_16x16.png      (16×16 px)
        ├── icon_16x16@2x.png   (32×32 px)
        ├── icon_32x32.png      (32×32 px)
        ├── icon_32x32@2x.png   (64×64 px)
        ├── icon_128x128.png    (128×128 px)
        ├── icon_128x128@2x.png (256×256 px)
        ├── icon_256x256.png    (256×256 px)
        ├── icon_256x256@2x.png (512×512 px)
        ├── icon_512x512.png    (512×512 px)
        └── icon_512x512@2x.png (1024×1024 px)
```

### 2. Contents.json for Asset Catalog Root

```json
{
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
```

### 3. Contents.json for AppIcon.appiconset

```json
{
  "images" : [
    {
      "filename" : "icon_16x16.png",
      "idiom" : "mac",
      "scale" : "1x",
      "size" : "16x16"
    },
    {
      "filename" : "icon_16x16@2x.png",
      "idiom" : "mac",
      "scale" : "2x",
      "size" : "16x16"
    },
    {
      "filename" : "icon_32x32.png",
      "idiom" : "mac",
      "scale" : "1x",
      "size" : "32x32"
    },
    {
      "filename" : "icon_32x32@2x.png",
      "idiom" : "mac",
      "scale" : "2x",
      "size" : "32x32"
    },
    {
      "filename" : "icon_128x128.png",
      "idiom" : "mac",
      "scale" : "1x",
      "size" : "128x128"
    },
    {
      "filename" : "icon_128x128@2x.png",
      "idiom" : "mac",
      "scale" : "2x",
      "size" : "128x128"
    },
    {
      "filename" : "icon_256x256.png",
      "idiom" : "mac",
      "scale" : "1x",
      "size" : "256x256"
    },
    {
      "filename" : "icon_256x256@2x.png",
      "idiom" : "mac",
      "scale" : "2x",
      "size" : "256x256"
    },
    {
      "filename" : "icon_512x512.png",
      "idiom" : "mac",
      "scale" : "1x",
      "size" : "512x512"
    },
    {
      "filename" : "icon_512x512@2x.png",
      "idiom" : "mac",
      "scale" : "2x",
      "size" : "512x512"
    }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
```

---

## ✅ Build Configuration

### For XcodeGen (project.yml)

Add this to your target settings:

```yaml
settings:
  ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon
```

### For Manual Xcode Project

1. Select your target → Build Settings
2. Search for "Asset Catalog Compiler - Options"
3. Set **Primary App Icon Set Name** to `AppIcon`

---

## ✅ Icon Size Reference

| Size | Scale | Pixels | Used For |
|------|-------|--------|----------|
| 16×16 | 1x | 16 | Finder sidebar, Spotlight |
| 16×16 | 2x | 32 | Finder sidebar @2x |
| 32×32 | 1x | 32 | Finder list view |
| 32×32 | 2x | 64 | Finder list view @2x |
| 128×128 | 1x | 128 | Finder icon view |
| 128×128 | 2x | 256 | Finder icon view @2x |
| 256×256 | 1x | 256 | Finder preview |
| 256×256 | 2x | 512 | Finder preview @2x |
| 512×512 | 1x | 512 | App Store, large previews |
| 512×512 | 2x | 1024 | App Store @2x, maximum size |

---

## ✅ Design Guidelines

### macOS Icon Requirements

- [ ] **Rounded rectangle shape** - macOS applies the rounded rect mask automatically, but design with ~18% corner radius in mind
- [ ] **No transparency for main icon** - Use a solid or gradient background
- [ ] **High contrast** - Icon should be recognizable at 16×16
- [ ] **Consistent style** - Match macOS Big Sur+ design language (depth, shadows, gradients)

### PNG Requirements

- [ ] **Format**: PNG with RGB color
- [ ] **Bit depth**: 8-bit per channel (24-bit color)
- [ ] **No alpha for app icon** - Background should be opaque
- [ ] **sRGB color space** recommended

---

## ✅ Menu Bar Icons (Optional)

If your app has a menu bar presence, create separate template images:

```
Assets.xcassets/
└── MenuBarIcon.imageset/
    ├── Contents.json
    ├── menubar_icon.png      (18×18 px)
    └── menubar_icon@2x.png   (36×36 px)
```

### Menu Bar Icon Contents.json

```json
{
  "images" : [
    {
      "filename" : "menubar_icon.png",
      "idiom" : "mac",
      "scale" : "1x"
    },
    {
      "filename" : "menubar_icon@2x.png",
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

### Menu Bar Icon Requirements

- [ ] **Black strokes/fills only** - System applies color for light/dark mode
- [ ] **Transparent background** - Required for template rendering
- [ ] **18pt height** - Standard menu bar icon size
- [ ] **Set as template** - `image.isTemplate = true` in code

---

## ✅ Verification Checklist

After building, verify your icon appears correctly in:

### Finder & System
- [ ] **Finder → Applications folder** - Icon visible
- [ ] **Finder → Get Info (Cmd+I)** - Large icon in top-left
- [ ] **Dock** - Icon visible when app is running
- [ ] **App Switcher (Cmd+Tab)** - Icon visible
- [ ] **Launchpad** - Icon visible
- [ ] **Spotlight (Cmd+Space)** - Icon in search results

### System Settings
- [ ] **Privacy & Security → Microphone** - Icon next to app name
- [ ] **Privacy & Security → Screen Recording** - Icon next to app name
- [ ] **Privacy & Security → Accessibility** - Icon next to app name
- [ ] **Login Items** - Icon visible if app is a login item

### App Bundle Verification
```bash
# Check that AppIcon.icns was generated
ls -la "YourApp.app/Contents/Resources/AppIcon.icns"

# Check asset catalog was compiled
ls -la "YourApp.app/Contents/Resources/Assets.car"
```

---

## ✅ Troubleshooting

### Icon not showing in System Settings

1. **Rebuild the app** - `./build.sh clean && ./build.sh`
2. **Clear icon cache**:
   ```bash
   sudo rm -rf /Library/Caches/com.apple.iconservices.store
   sudo find /private/var/folders -name "com.apple.iconservices*" -exec rm -rf {} \; 2>/dev/null
   killall Finder
   killall Dock
   ```
3. **Restart your Mac** - Some caches only clear on reboot

### Icon shows generic app icon

- Verify `ASSETCATALOG_COMPILER_APPICON_NAME` is set correctly
- Ensure all 10 PNG sizes are present
- Check that `Contents.json` filenames match actual files
- Regenerate Xcode project: `xcodegen generate`

### Menu bar icon not adapting to dark mode

- Ensure `template-rendering-intent: template` in Contents.json
- Set `image.isTemplate = true` in Swift code
- Use only black color in the PNG (no grays)

---

## ✅ Quick Commands

### Generate icons from SVG (requires librsvg)

```bash
brew install librsvg

# Generate all sizes from a 1024x1024 source SVG
for size in 16 32 64 128 256 512 1024; do
  rsvg-convert -w $size -h $size icon.svg > "icon_${size}x${size}.png"
done
```

### Verify icon in app bundle

```bash
# List all icon-related files
find "YourApp.app" -name "*.icns" -o -name "*.car" | xargs ls -la
```

---

## References

- [Apple: Configuring your app icon](https://developer.apple.com/documentation/xcode/configuring-your-app-icon)
- [Apple Human Interface Guidelines: App Icons](https://developer.apple.com/design/human-interface-guidelines/app-icons)
- [Asset Catalog Format Reference](https://developer.apple.com/library/archive/documentation/Xcode/Reference/xcode_ref-Asset_Catalog_Format/)

---

*Last updated: December 2024*
