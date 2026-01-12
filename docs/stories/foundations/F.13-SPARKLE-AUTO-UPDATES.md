# F.13 - Sparkle Auto-Updates

**Epic:** Foundations
**Status:** Not Started
**Priority:** P2 (Medium)
**Estimated Effort:** 3 days
**Dependencies:** F.01 (App Shell), F.06 (Preferences Window)
**Target:** macOS 26 (Tahoe)
**Design Reference:** [Sparkle Documentation](https://sparkle-project.org/documentation/)

---

## 1. Objective

Enable automatic software updates for Ora using the Sparkle framework. Users should be notified when new versions are available and be able to update with a single click, without needing to manually download from GitHub.

This is critical for:
- **User experience:** Seamless updates without manual intervention
- **Security:** Ensuring users run the latest, most secure version
- **Distribution:** Enabling GitHub Releases as the primary distribution channel

## 2. User Story

As a user, I want Ora to automatically check for updates and notify me when a new version is available so that I can easily stay up-to-date without visiting GitHub.

## 3. Scope

### In Scope

- Add Sparkle 2.8+ as a Swift Package Manager dependency
- Generate and securely store EdDSA signing keys
- Configure Info.plist with required Sparkle keys (SUFeedURL, SUPublicEDKey)
- Implement programmatic Sparkle updater for SwiftUI integration
- Add "Check for Updates..." menu item in app menu
- Create GitHub-hosted appcast.xml for update feed
- Add update preferences UI (automatic check toggle, check interval)
- Create release automation script for signing updates
- Document the release process

### Out of Scope

- Delta updates (optimization for later)
- Custom update UI (use Sparkle's standard UI)
- Multiple update channels (beta/stable)
- Rollback functionality
- In-app changelog display beyond Sparkle's release notes window

## 4. Architecture Alignment

### Component Integration

- **Preferences:** Add "Updates" section to General preferences tab
- **Menu Bar:** Add "Check for Updates..." to app menu
- **App Delegate:** Initialize Sparkle updater on launch

### Concurrency Model

- Sparkle handles its own threading internally
- UI interactions with updater must be on MainActor
- Update checks run asynchronously without blocking UI

### Security Requirements

- EdDSA (ed25519) signatures for all update packages
- Private key stored in macOS Keychain (never committed to repo)
- Public key embedded in Info.plist
- HTTPS-only for appcast and downloads
- Code signing + notarization required for distributed builds

### Relevant Architecture References

- PRD Section 6: UX Principles (predictability, transparency)
- CLAUDE.md: Build, Test, Run section (distribution requirements)

## 5. Implementation Plan (Draft)

### 5.1 Files to Create

- `Ora/Updates/UpdateController.swift` - Sparkle wrapper with ObservableObject for SwiftUI
- `Ora/Updates/UpdatePreferencesView.swift` - SwiftUI view for update settings
- `scripts/sign-update.sh` - Script to sign release archives with EdDSA
- `scripts/generate-appcast.sh` - Script to generate/update appcast.xml
- `docs/RELEASE-PROCESS.md` - Documentation for creating releases
- `.github/workflows/release.yml` - GitHub Actions workflow for automated releases (future)

### 5.2 Files to Modify

- `project.yml` - Add Sparkle SPM dependency
- `Ora/Info.plist` - Add SUFeedURL, SUPublicEDKey, SUEnableAutomaticChecks
- `Ora/AppDelegate.swift` - Initialize UpdateController on launch
- `Ora/UI/StatusBarController.swift` - Add "Check for Updates..." menu item
- `Ora/Preferences/Tabs/GeneralPreferencesView.swift` - Add updates section

### 5.3 Tests to Add

- `OraTests/Updates/UpdateControllerTests.swift` - Test updater initialization and state
- Manual test checklist for update flow

### 5.4 Dependencies/Config

- `project.yml` - Add package:
  ```yaml
  packages:
    Sparkle:
      url: https://github.com/sparkle-project/Sparkle
      from: "2.8.0"
  ```

## 6. Acceptance Criteria

- [ ] AC-1: Sparkle 2.8+ integrated via Swift Package Manager
- [ ] AC-2: EdDSA keypair generated and public key in Info.plist
- [ ] AC-3: "Check for Updates..." menu item triggers Sparkle update check
- [ ] AC-4: Sparkle update window displays correctly when update available
- [ ] AC-5: Updates download and install successfully (verified with test release)
- [ ] AC-6: Preferences UI shows automatic update toggle and last check time
- [ ] AC-7: Appcast.xml hosted on GitHub (Pages or raw file in releases repo)
- [ ] AC-8: Release signing script works with generate_appcast tool
- [ ] AC-9: Release process documented in docs/RELEASE-PROCESS.md

## 7. Verification Plan

### Automated Tests

- [ ] UpdateController initializes without errors
- [ ] UpdateController correctly reports canCheckForUpdates state
- [ ] Menu item enabled/disabled state matches updater state

### Manual Tests

- [ ] Fresh install finds and installs test update
- [ ] "Check for Updates..." shows "up to date" when current
- [ ] "Check for Updates..." shows update dialog when new version available
- [ ] Update download completes and app relaunches with new version
- [ ] Automatic check preference persists across app restarts
- [ ] Update works on both macOS 26 and macOS 15 (if supporting older versions)

## 8. Performance / Reliability Considerations

- **Startup impact:** Sparkle initialization is lightweight; update checks are async
- **Network:** Appcast fetch should timeout gracefully (Sparkle handles this)
- **Failure modes:**
  - Network unavailable: Silently skip, retry on next launch
  - Appcast parse error: Log warning, don't show error to user
  - Download failure: Sparkle shows retry option
  - Signature verification failure: Sparkle rejects update, logs error

## 9. Risks & Mitigations

| Risk | Mitigation |
|:-----|:-----------|
| Private key exposure | Store only in Keychain, never in repo; document secure handling |
| Broken update bricks app | Test update flow thoroughly; keep direct download link available |
| GitHub rate limiting | Appcast is small; cache on GitHub Pages if needed |
| User on old macOS | Sparkle 2.8+ requires macOS 10.13+; Ora requires 26, so not an issue |
| Notarization required | Document notarization in release process; updates fail gracefully without it |

## 10. Open Questions

- [ ] Should we host appcast.xml on GitHub Pages (separate repo) or as a raw file in the main repo?
  - **Recommendation:** Separate repo (e.g., `ora-updates`) with GitHub Pages for cleaner separation
- [ ] Should we implement a "Check for Updates on Launch" preference, or always check?
  - **Recommendation:** Default to automatic checks; add preference toggle
- [ ] What update check interval? (Sparkle default is 24 hours)
  - **Recommendation:** Use Sparkle default (24 hours) with user preference for manual-only

---

## Technical Reference

### Sparkle Version

- **Target:** Sparkle 2.8.1+ (latest stable as of November 2024)
- **Features:** EdDSA signing, macOS Tahoe compatibility, refreshed UI
- **Source:** https://github.com/sparkle-project/Sparkle

### Key Generation

```bash
# One-time setup (run from Sparkle tools directory)
./bin/generate_keys
# Outputs public key for Info.plist, stores private in Keychain
```

### Info.plist Configuration

```xml
<key>SUFeedURL</key>
<string>https://raw.githubusercontent.com/OWNER/ora-updates/main/appcast.xml</string>

<key>SUPublicEDKey</key>
<string>BASE64_PUBLIC_KEY_HERE</string>

<key>SUEnableAutomaticChecks</key>
<true/>
```

### Appcast.xml Format

```xml
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Ora Updates</title>
    <link>https://github.com/OWNER/ora</link>
    <description>Most recent updates to Ora</description>
    <language>en</language>
    <item>
      <title>Version 1.1.0</title>
      <sparkle:version>1.1.0</sparkle:version>
      <sparkle:shortVersionString>1.1.0</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>26.0</sparkle:minimumSystemVersion>
      <pubDate>Mon, 01 Jan 2026 12:00:00 +0000</pubDate>
      <sparkle:releaseNotesLink>
        https://raw.githubusercontent.com/OWNER/ora-updates/main/notes/1.1.0.html
      </sparkle:releaseNotesLink>
      <enclosure
        url="https://github.com/OWNER/ora/releases/download/v1.1.0/Ora-1.1.0.dmg"
        sparkle:edSignature="EDDSA_SIGNATURE_HERE"
        length="12345678"
        type="application/octet-stream" />
    </item>
  </channel>
</rss>
```

### SwiftUI Integration Pattern

```swift
import Sparkle

@MainActor
final class UpdateController: ObservableObject {
    private let updaterController: SPUStandardUpdaterController

    @Published var canCheckForUpdates = false
    @Published var lastUpdateCheck: Date?

    init() {
        self.updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )

        // Observe canCheckForUpdates
        updaterController.updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)

        // Observe last update check
        updaterController.updater.publisher(for: \.lastUpdateCheckDate)
            .assign(to: &$lastUpdateCheck)
    }

    func checkForUpdates() {
        updaterController.checkForUpdates(nil)
    }

    var automaticallyChecksForUpdates: Bool {
        get { updaterController.updater.automaticallyChecksForUpdates }
        set { updaterController.updater.automaticallyChecksForUpdates = newValue }
    }
}
```

### Release Signing Script

```bash
#!/bin/bash
# scripts/sign-update.sh

set -e

VERSION=$1
ARCHIVE_PATH=$2

if [ -z "$VERSION" ] || [ -z "$ARCHIVE_PATH" ]; then
    echo "Usage: ./sign-update.sh <version> <archive-path>"
    exit 1
fi

# Path to Sparkle tools (adjust based on SPM location)
SPARKLE_TOOLS="${BUILD_DIR}/../../SourcePackages/artifacts/sparkle/Sparkle/bin"

# Generate appcast with signature
"${SPARKLE_TOOLS}/generate_appcast" ./updates/

echo "Appcast updated for version $VERSION"
```

---

## Implementation Summary

(TBD after implementation.)

## Code Review Findings

(TBD by review agent.)

## Completion Status

(TBD after merge.)
