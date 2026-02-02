# Ora Release Process (Sparkle)

How Sparkle auto-updates work and how to set up the release pipeline.

## How It Works

Sparkle checks a remote XML file (the **appcast**) to see if a newer version exists. If it does, it downloads the update archive, verifies its EdDSA signature, and installs it.

```
App launches
  → Sparkle fetches appcast.xml (SUFeedURL in Info.plist)
  → Compares CFBundleShortVersionString with <sparkle:shortVersionString>
  → If newer: shows update dialog, downloads DMG from <enclosure url="...">
  → Verifies EdDSA signature against SUPublicEDKey in Info.plist
  → Installs and relaunches
```

### URL Layout

| Purpose | URL | Hosted On |
|:--------|:----|:----------|
| Appcast feed | `https://raw.githubusercontent.com/benedict2310/ora-updates/main/appcast.xml` | `ora-updates` repo (raw) |
| Release notes | `https://raw.githubusercontent.com/benedict2310/ora-updates/main/notes/<version>.html` | `ora-updates` repo (raw) |
| DMG download | `https://github.com/benedict2310/ora/releases/download/v<version>/Ora-<version>.dmg` | GitHub Releases on `ora` repo |

The appcast URL is baked into the app via `SUFeedURL` in `Ora/Info.plist`. Changing it requires a new build — existing users on older versions will keep checking the old URL.

## One-Time Setup

### 1. EdDSA Signing Keys

Keys were already generated during the F.13 implementation. The public key is in `Ora/Info.plist` under `SUPublicEDKey`. The private key is stored in your macOS Keychain (Sparkle manages this automatically).

**To verify your key exists:**
```bash
SPARKLE_TOOLS_DIR=$(./scripts/generate-appcast.sh --print-tools-dir)
"$SPARKLE_TOOLS_DIR/generate_keys" -p
# Should print the public key matching SUPublicEDKey in Info.plist
```

**If you need to regenerate** (e.g., new machine, lost Keychain):
```bash
"$SPARKLE_TOOLS_DIR/generate_keys"
```
Then update `SUPublicEDKey` in `Ora/Info.plist` with the new public key. All future releases must use the new key — users on old versions will fail to verify updates signed with a different key, so you'd need to ship one transitional release signed with the old key that embeds the new public key.

### 2. Create the `ora-updates` Repo

This repo hosts only the appcast and release notes. Keeping it separate from the main repo avoids bloating `ora` with release artifacts.

```bash
# On GitHub, create: https://github.com/benedict2310/ora-updates
# Then clone it locally:
git clone https://github.com/benedict2310/ora-updates.git
cd ora-updates

# Create the structure
mkdir -p notes
# Copy the template appcast as a starting point
cp /path/to/ora/updates/appcast.xml .
cp -r /path/to/ora/updates/notes/ notes/

git add -A
git commit -m "Initial appcast and release notes"
git push origin main
```

**Verify the feed URL is reachable:**
```bash
curl -sI https://raw.githubusercontent.com/benedict2310/ora-updates/main/appcast.xml
# Should return HTTP 200
```

> **Alternative: GitHub Pages.** If you enable Pages on `ora-updates`, the URL becomes `https://benedict2310.github.io/ora-updates/appcast.xml`. Update `SUFeedURL` in Info.plist accordingly. Pages gives you a proper domain and CDN caching, but raw URLs work fine for low traffic.

### 3. Verify Info.plist Configuration

These keys should already be set:

| Key | Value | Purpose |
|:----|:------|:--------|
| `SUFeedURL` | `https://raw.githubusercontent.com/benedict2310/ora-updates/main/appcast.xml` | Where Sparkle checks for updates |
| `SUPublicEDKey` | `raLB6FKlwAeAOyXHvePhCwGo1nJCiwiV5jcls0mg18E=` | Public key to verify update signatures |
| `SUEnableAutomaticChecks` | `true` | Check for updates on launch (user can override in Preferences) |

## Release Steps

### 1. Bump the Version

Update both version strings in `Ora/Info.plist`:

```xml
<key>CFBundleShortVersionString</key>
<string>1.1.0</string>          <!-- User-visible version -->
<key>CFBundleVersion</key>
<string>2</string>              <!-- Monotonically increasing build number -->
```

Sparkle compares `CFBundleShortVersionString` with `<sparkle:shortVersionString>` in the appcast to determine if an update is available.

### 2. Build, Sign, and Notarize

```bash
# Build release
./build.sh

# For distribution, you'll need a Developer ID certificate:
# codesign --deep --force --options runtime --sign "Developer ID Application: ..." build/Build/Products/Release/Ora.app
# Then notarize with: xcrun notarytool submit ...
```

### 3. Create the DMG

```bash
VERSION="1.1.0"

# Create a DMG from the built app
hdiutil create -volname "Ora" \
  -srcfolder build/Build/Products/Release/Ora.app \
  -ov -format UDZO \
  "updates/Ora-${VERSION}.dmg"
```

### 4. Sign the DMG with Sparkle

```bash
./scripts/sign-update.sh "$VERSION" "updates/Ora-${VERSION}.dmg"
```

This prints the EdDSA signature and file length. You'll need these for the appcast entry (or use `generate_appcast` to do it automatically).

### 5. Generate the Appcast

```bash
# Set URL prefixes so the appcast points to the right places
SPARKLE_DOWNLOAD_URL_PREFIX="https://github.com/benedict2310/ora/releases/download/v${VERSION}/" \
SPARKLE_RELEASE_NOTES_URL_PREFIX="https://raw.githubusercontent.com/benedict2310/ora-updates/main/notes/" \
./scripts/generate-appcast.sh updates
```

This reads signed DMGs from `updates/`, generates `updates/appcast.xml` with correct signatures, lengths, and URLs.

### 6. Write Release Notes

Create `updates/notes/<version>.html`:

```html
<html>
<body>
<h2>What's New in Ora 1.1.0</h2>
<ul>
  <li>New feature: ...</li>
  <li>Bug fix: ...</li>
</ul>
</body>
</html>
```

Sparkle shows this HTML in the update dialog.

### 7. Push to `ora-updates` Repo

```bash
cd /path/to/ora-updates
cp /path/to/ora/updates/appcast.xml .
cp /path/to/ora/updates/notes/*.html notes/

git add -A
git commit -m "Release v${VERSION}"
git push origin main
```

### 8. Create GitHub Release on `ora` Repo

```bash
cd /path/to/ora
gh release create "v${VERSION}" \
  "updates/Ora-${VERSION}.dmg" \
  --title "Ora v${VERSION}" \
  --notes "See release notes in the app's update dialog."
```

The DMG download URL in the appcast (`https://github.com/benedict2310/ora/releases/download/v1.1.0/Ora-1.1.0.dmg`) must match this release asset.

### 9. Verify

```bash
# Check the appcast is live
curl -s https://raw.githubusercontent.com/benedict2310/ora-updates/main/appcast.xml | head -20

# Check the DMG is downloadable
curl -sI "https://github.com/benedict2310/ora/releases/download/v${VERSION}/Ora-${VERSION}.dmg" | head -5

# Test in the app: menu bar → "Check for Updates..."
```

## Troubleshooting

| Issue | Cause | Fix |
|:------|:------|:----|
| "Up to date" when update exists | `CFBundleShortVersionString` in the running app >= appcast version | Ensure appcast `<sparkle:shortVersionString>` is higher than the installed version |
| Signature verification failed | DMG was signed with a different key than `SUPublicEDKey` | Re-sign with the correct key, or update Info.plist if the key changed |
| Appcast 404 | `ora-updates` repo doesn't exist or file path is wrong | Verify `SUFeedURL` matches the actual raw URL |
| DMG download fails | GitHub Release asset missing or wrong filename | Ensure `<enclosure url="...">` matches the exact release asset URL |
| Update dialog doesn't appear | App is not code-signed, or Sparkle can't verify the bundle | Sparkle requires a valid code signature; check Console.app for Sparkle logs |
| "Check for Updates..." greyed out | Sparkle hasn't finished initializing | Wait a moment after launch; check `canCheckForUpdates` state in logs |

## Environment Variables

The release scripts support these overrides:

| Variable | Purpose | Default |
|:---------|:--------|:--------|
| `SPARKLE_TOOLS_DIR` | Path to Sparkle `bin/` tools directory | Auto-discovered from build or DerivedData |
| `SPARKLE_KEYCHAIN_ACCOUNT` | Keychain account for EdDSA key | Sparkle default |
| `SPARKLE_PRIVATE_KEY_FILE` | Path to EdDSA private key file (instead of Keychain) | Not set (uses Keychain) |
| `SPARKLE_DOWNLOAD_URL_PREFIX` | URL prefix for DMG download links in appcast | Not set (uses relative paths) |
| `SPARKLE_RELEASE_NOTES_URL_PREFIX` | URL prefix for release notes links in appcast | Not set (uses relative paths) |
