# BUG-007: Microphone Permission Entry Missing in System Settings

**Status:** Fixed (Pending QA)
**Priority:** P1
**Created:** 2026-02-13
**Last Updated:** 2026-02-13

---

## 1. Summary

Some users cannot grant microphone access because Ora does not appear as a toggleable app entry in macOS Privacy settings, while Ora itself reports microphone permission as denied.

---

## 2. User Impact

- Ora cannot start voice capture.
- Preferences shows microphone as not granted.
- "Open Settings" opens the correct pane, but Ora is not listed for enablement.

---

## 3. Root Cause

Ora requested microphone authorization with `NSMicrophoneUsageDescription` present, but the app target was not configured with the macOS audio-input hardened runtime entitlement.

Apple's macOS media capture guidance requires:
- Usage description key in `Info.plist`.
- Appropriate macOS entitlement for capture access.

Without the entitlement, authorization behavior can be inconsistent and may not produce a usable privacy toggle entry for the app.

---

## 4. Fix Implemented

1. Added app entitlements file:
   - `Ora/Ora.entitlements`
   - `com.apple.security.device.audio-input = true`
2. Wired entitlements into app target build settings:
   - `CODE_SIGN_ENTITLEMENTS = Ora/Ora.entitlements`
3. Preserved entitlements during release re-sign:
   - `scripts/ci-release.sh` now uses `--preserve-metadata=entitlements`
   - Prevents distribution signing from stripping `com.apple.security.device.audio-input`
4. Kept local dev builds launchable:
   - Do not force hardened runtime in local `xcodebuild` project settings.
   - Distribution signing still applies hardened runtime in `scripts/ci-release.sh` (`--options runtime`).

---

## 5. Verification Plan

1. Build and run Ora.
2. Reset microphone permission:
   - `tccutil reset Microphone com.ora.app`
3. Trigger microphone request from setup or hotkey flow.
4. Confirm:
   - System permission prompt appears.
   - Ora appears in Privacy > Microphone.
   - Ora can record audio after permission is granted.

---

## 6. Temporary Workaround

If a user is already in a bad TCC state:

```bash
tccutil reset Microphone com.ora.app
```

Then relaunch Ora and re-trigger the microphone request flow.
