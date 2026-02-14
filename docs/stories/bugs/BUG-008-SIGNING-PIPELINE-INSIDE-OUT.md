# BUG-008: Replace `codesign --deep` with Inside-Out Signing

**Status:** Open
**Priority:** P2
**Created:** 2026-02-14
**Last Updated:** 2026-02-14

---

## 1. Summary

`scripts/ci-release.sh` currently signs the app using `codesign --deep`. This works for current payloads, but is fragile if any nested framework/helper ships with its own entitlements.

---

## 2. Risk

- `--deep` recursively re-signs nested code objects.
- Entitlement preservation behavior can be surprising for nested binaries.
- Future dependencies with required embedded entitlements could break silently during distribution signing.

---

## 3. Current State

- Release signing command:
  - `codesign --deep --force --options runtime --preserve-metadata=entitlements ...`
- Microphone entitlement fix is in place and preserved for current app bundle.
- Notarization flow currently succeeds.

---

## 4. Proposed Fix

Migrate to explicit inside-out signing:

1. Sign all nested frameworks/libraries/helpers/XPCs first.
2. Sign nested apps (if any).
3. Sign the outer `Ora.app` bundle last with hardened runtime options.
4. Verify signatures and entitlements for both nested and outer binaries before notarization.

---

## 5. App Sandbox Note

Ora is intentionally non-sandboxed today (Developer ID distribution, outside Mac App Store). This ticket does **not** propose enabling App Sandbox. It is only about making signing deterministic and entitlement-safe for nested code.

---

## 6. Acceptance Criteria

- `scripts/ci-release.sh codesign` no longer relies on `--deep`.
- Release artifact launches and passes `codesign --verify --deep --strict`.
- Release artifact notarizes successfully.
- Critical entitlements remain present after signing.

