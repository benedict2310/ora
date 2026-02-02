# Ora Release Process (Sparkle)

This document describes the manual release flow for Sparkle auto-updates.

## Prerequisites

- Sparkle tools available via Swift Package Manager (build once to download).
- A Sparkle EdDSA keypair generated with the private key stored in Keychain.
- A separate updates repo (recommended: `ora-updates`) to host `appcast.xml` and release notes.

## One-Time Setup

1. Build the app once to download Sparkle tools:
   ```bash
   ./build.sh
   ```

2. Generate Sparkle signing keys:
   ```bash
   # Find Sparkle tools with the helper script
   SPARKLE_TOOLS_DIR=$(./scripts/generate-appcast.sh --print-tools-dir)
   "$SPARKLE_TOOLS_DIR/generate_keys"
   ```

3. Copy the public key into `Ora/Info.plist` under `SUPublicEDKey`.

4. Create an updates repo (recommended):
   - `https://github.com/<OWNER>/ora-updates`
   - Enable GitHub Pages or use raw GitHub URLs.
   - Host `appcast.xml` and `notes/*.html` in that repo.

5. Confirm `SUFeedURL` in `Ora/Info.plist` matches your hosted appcast URL.

## Release Steps

1. Build, sign, and notarize the app as usual.

2. Create a release archive (DMG or ZIP) and place it in `updates/`:
   ```bash
   mkdir -p updates
   cp path/to/Ora-1.0.0.dmg updates/
   ```

3. Sign the archive:
   ```bash
   ./scripts/sign-update.sh 1.0.0 updates/Ora-1.0.0.dmg
   ```

4. Generate or refresh the appcast:
   ```bash
   SPARKLE_DOWNLOAD_URL_PREFIX="https://<host>/ora-updates/" \\
   SPARKLE_RELEASE_NOTES_URL_PREFIX="https://<host>/ora-updates/notes/" \\
   ./scripts/generate-appcast.sh updates
   ```

5. Update release notes in `updates/notes/` (HTML files).

6. Push `updates/appcast.xml` and `updates/notes/` to the updates repo.

7. Create a GitHub release in the main repo and upload the signed DMG.

## Notes

- Sparkle rejects unsigned or mismatched updates; make sure the app bundle is properly signed and notarized.
- `SUPublicEDKey` must match the private key stored in your Keychain.
- The Sparkle tools location can be overridden by setting `SPARKLE_TOOLS_DIR`.
