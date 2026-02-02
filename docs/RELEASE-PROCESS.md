# Ora — CI/CD & Release Process

## Overview

Ora uses GitHub Actions for continuous integration and automated releases:

| Workflow | Trigger | Secrets Required | File |
|:---------|:--------|:-----------------|:-----|
| **CI** | PR to `main`, push to `main` | None | `.github/workflows/ci.yml` |
| **Release** | Tag push (`v*`) | 7 secrets | `.github/workflows/release.yml` |

Runner: `macos-15` with Xcode 26.2 (`/Applications/Xcode_26.2.app`).

Helper script: `scripts/ci-release.sh` — consolidates signing, notarization, DMG creation, and appcast generation for CI.

---

## CI Workflow

Runs on every PR and push to `main`. No secrets required.

**Pipeline:**
1. Checkout
2. Install XcodeGen (`brew install xcodegen`)
3. Select Xcode 26.2
4. Generate `.xcodeproj`
5. Resolve SPM packages (cached)
6. Build (Release, arm64, ad-hoc signing)
7. Test (`ORA_SKIP_PERMISSION_PROMPTS=1`)
8. Parse test results (`xcresult_summary.py`)
9. Upload `.xcresult` artifact on failure

**SPM Cache:** Keyed on `project.yml` + `Vendor/kokoro-ios/Package.swift` + `Vendor/MisakiSwift/Package.swift`. Stored at `build/SourcePackages`.

---

## Release Workflow

Triggered by pushing a tag matching `v*` (e.g., `v1.1.0`).

**Pipeline:**
1. Setup (checkout, XcodeGen, Xcode selection, version extraction from tag)
2. Build with Developer ID signing and hardened runtime
3. Import .p12 certificate into temporary CI keychain
4. Deep-sign the .app bundle
5. Notarize with Apple (`notarytool submit --wait`)
6. Staple notarization ticket
7. Create DMG
8. Sign DMG with Developer ID
9. Sign DMG with Sparkle EdDSA
10. Generate `appcast.xml`
11. Create GitHub Release with DMG attached
12. Push appcast to `benedict2310/ora-updates`
13. Cleanup temporary keychain

### How Sparkle Auto-Update Works

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

The appcast URL is baked into the app via `SUFeedURL` in `Ora/Info.plist`. Changing it requires a new build.

---

## Required Secrets

Configure these in the `ora` repository: **Settings → Secrets and variables → Actions**.

| Secret | Description | How to Obtain |
|:-------|:------------|:-------------|
| `DEVELOPER_ID_P12` | Base64-encoded Developer ID .p12 certificate | See [Exporting the Certificate](#exporting-the-developer-id-certificate) |
| `DEVELOPER_ID_PASSWORD` | Password used when exporting the .p12 | The password you set during export |
| `APPLE_ID` | Apple ID email for notarization | Your Apple Developer account email |
| `APPLE_ID_APP_PASSWORD` | App-specific password | [appleid.apple.com](https://appleid.apple.com) → Sign-In and Security → App-Specific Passwords |
| `APPLE_TEAM_ID` | 10-character team identifier | [developer.apple.com/account](https://developer.apple.com/account) → Membership Details |
| `SPARKLE_PRIVATE_KEY` | EdDSA private key for Sparkle updates | See [Sparkle Key](#sparkle-eddsa-key) |
| `ORA_UPDATES_TOKEN` | Fine-grained PAT with push access to `benedict2310/ora-updates` | See [Creating the PAT](#creating-the-pat) |

### Exporting the Developer ID Certificate

1. Open **Keychain Access**
2. Find your "Developer ID Application" certificate
3. Right-click → Export Items → save as `.p12` with a password
4. Base64 encode:
   ```bash
   base64 -i DeveloperID.p12 | pbcopy
   ```
5. Set `DEVELOPER_ID_P12` to the clipboard contents
6. Set `DEVELOPER_ID_PASSWORD` to the export password

### Sparkle EdDSA Key

Keys were generated during the Sparkle integration. The public key is in `Ora/Info.plist` under `SUPublicEDKey`.

```bash
# Verify your key exists
TOOLS_DIR=$(./scripts/generate-appcast.sh --print-tools-dir)
"$TOOLS_DIR/generate_keys" -p
# Should print the public key matching SUPublicEDKey in Info.plist

# Export private key for CI
"$TOOLS_DIR/generate_keys" -x
# Copy the output → set as SPARKLE_PRIVATE_KEY secret
```

If you need to regenerate keys (new machine, lost Keychain):
```bash
"$TOOLS_DIR/generate_keys"
```
Then update `SUPublicEDKey` in `Ora/Info.plist`. All future releases must use the new key.

### Creating the PAT

1. Go to **GitHub Settings → Developer settings → Fine-grained personal access tokens**
2. Create a new token:
   - **Repository access:** Only select `benedict2310/ora-updates`
   - **Permissions:** Contents → Read and Write
3. Copy the token → set as `ORA_UPDATES_TOKEN` secret

---

## Creating a Release

```bash
# 1. Commit all changes to main
# 2. Tag the release
git tag v1.1.0
git push origin v1.1.0
```

The release workflow handles everything automatically: build, sign, notarize, package, publish.

### Pre-release Tags

Tags containing `-` (e.g., `v1.1.0-rc1`) are automatically marked as pre-release on GitHub.

### Version Numbering

The tag version (minus `v` prefix) is injected into `MARKETING_VERSION` at build time. The `CURRENT_PROJECT_VERSION` (build number) is set to the GitHub Actions run number.

---

## Manual Release (Local)

For when you need to release without CI:

### 1. Build, Sign, and Notarize

```bash
./build.sh

# Sign with Developer ID
codesign --deep --force --options runtime \
  --sign "Developer ID Application: ..." \
  build/Build/Products/Release/Ora.app

# Notarize
ditto -c -k --keepParent build/Build/Products/Release/Ora.app /tmp/Ora.zip
xcrun notarytool submit /tmp/Ora.zip \
  --apple-id "you@example.com" \
  --password "app-specific-password" \
  --team-id "TEAM_ID" \
  --wait
xcrun stapler staple build/Build/Products/Release/Ora.app
```

### 2. Create DMG

```bash
VERSION="1.1.0"
hdiutil create -volname "Ora" \
  -srcfolder build/Build/Products/Release/Ora.app \
  -ov -format UDZO \
  "updates/Ora-${VERSION}.dmg"
```

### 3. Sign and Generate Appcast

```bash
SPARKLE_DOWNLOAD_URL_PREFIX="https://github.com/benedict2310/ora/releases/download/v${VERSION}/" \
SPARKLE_RELEASE_NOTES_URL_PREFIX="https://raw.githubusercontent.com/benedict2310/ora-updates/main/notes/" \
./scripts/generate-appcast.sh updates
```

### 4. Publish

```bash
# Push appcast to ora-updates
cd /path/to/ora-updates
cp /path/to/ora/updates/appcast.xml .
git add -A && git commit -m "Release v${VERSION}" && git push

# Create GitHub Release
cd /path/to/ora
gh release create "v${VERSION}" "updates/Ora-${VERSION}.dmg" \
  --title "Ora v${VERSION}" \
  --notes "See release notes in the app's update dialog."
```

---

## Helper Script (`scripts/ci-release.sh`)

Consolidates release-specific steps for CI. Can also be used locally for testing:

```bash
./scripts/ci-release.sh

# Commands:
#   setup-keychain <base64-p12> <password>       Import signing certificate
#   teardown-keychain                            Remove temporary keychain
#   codesign <app-path>                          Deep-sign app bundle
#   codesign-dmg <dmg-path>                      Sign DMG file
#   notarize <app> <id> <pw> <team>              Notarize with Apple
#   create-dmg <app-path> <dmg-path>             Create DMG from app
#   sparkle-sign <dmg> <tools> <key>             Sign with Sparkle EdDSA
#   generate-appcast <dmg> <tools> <ver> <key>   Generate appcast.xml
```

---

## Info.plist Sparkle Configuration

These keys are set in `Ora/Info.plist`:

| Key | Value | Purpose |
|:----|:------|:--------|
| `SUFeedURL` | `https://raw.githubusercontent.com/benedict2310/ora-updates/main/appcast.xml` | Where Sparkle checks for updates |
| `SUPublicEDKey` | `raLB6FKlwAeAOyXHvePhCwGo1nJCiwiV5jcls0mg18E=` | Public key to verify update signatures |
| `SUEnableAutomaticChecks` | `true` | Check for updates on launch |

---

## Troubleshooting

| Issue | Solution |
|:------|:---------|
| CI fails at "Select Xcode 26.2" | Xcode 26.2 may not be on the runner. Check [GitHub runner images](https://github.com/actions/runner-images). |
| SPM resolution fails | Clear the cache in GitHub Actions settings, or change the cache key. |
| MLX/Metal tests fail on CI | CI runners may lack GPU. Skip GPU-dependent tests with `-skip-testing:OraTests/SpecificTest`. |
| Notarization fails | Verify `APPLE_ID`, `APPLE_ID_APP_PASSWORD`, and `APPLE_TEAM_ID`. Check [Apple system status](https://developer.apple.com/system-status/). |
| Code signing fails | Verify the .p12 was exported correctly and password matches. Run `security find-identity -v -p codesigning` locally. |
| Appcast not updating | Check `ORA_UPDATES_TOKEN` has write access to `benedict2310/ora-updates`. |
| Signature verification failed | DMG was signed with a different key than `SUPublicEDKey`. Re-sign with the correct key. |
| "Up to date" when update exists | `CFBundleShortVersionString` in the running app >= appcast version. |
| DMG download fails | Ensure `<enclosure url="...">` in appcast matches the exact GitHub Release asset URL. |

## Environment Variables (Local Scripts)

| Variable | Purpose | Default |
|:---------|:--------|:--------|
| `SPARKLE_TOOLS_DIR` | Path to Sparkle `bin/` tools directory | Auto-discovered from build or DerivedData |
| `SPARKLE_KEYCHAIN_ACCOUNT` | Keychain account for EdDSA key | Sparkle default |
| `SPARKLE_DOWNLOAD_URL_PREFIX` | URL prefix for DMG download links in appcast | Not set (relative paths) |
| `SPARKLE_RELEASE_NOTES_URL_PREFIX` | URL prefix for release notes links in appcast | Not set (relative paths) |

---

## File Index

| File | Purpose |
|:-----|:--------|
| `.github/workflows/ci.yml` | CI build + test workflow |
| `.github/workflows/release.yml` | Full release pipeline |
| `scripts/ci-release.sh` | Helper for signing, notarization, DMG, appcast |
| `scripts/generate-appcast.sh` | Standalone appcast generation (local use) |
| `scripts/xcresult_summary.py` | Test result parser for CI output |
| `Ora/Info.plist` | Contains Sparkle configuration keys |
