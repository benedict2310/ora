# M.01 - Test Coverage Improvements

**Epic:** Maintenance
**Status:** In Progress
**Priority:** P1 (High)
**Estimated Effort:** 2-3 days
**Dependencies:** None
**Target:** macOS 26 (Tahoe)
**Design Reference:** None

---

## Active Branches

- `test/m01-coverage-setup-preferences-v2` (Setup + Preferences coverage)

## Progress Updates

- 2026-01-05: Added Setup/Preferences view coverage and helper extraction; `Ora.app` coverage now 68.71% (9477/13793) from `agent-tools/test-results-coverage-2.xcresult`.

## 1. Objective

Raise `Ora.app` line coverage to **>= 85%** (app-only target) without adding new dependencies, by adding focused unit tests and extracting testable logic from UI views.

## 2. User Story

As a maintainer, I want higher automated coverage of core UI and orchestration logic so regressions are caught before release.

## 3. Scope

### In Scope

- Add unit tests for low-coverage files in `Ora/Setup`, `Ora/Overlay`, `Ora/Preferences`, `Ora/Tools/Calendar`, `Ora/Permissions`, and `Ora/LLM`.
- Extract small formatting/decision helpers out of SwiftUI views where needed to make logic testable.
- Expand existing test helpers for permissions/setup to avoid AppKit UI dependency.

### Out of Scope

- Vendor packages (FluidAudio, MLX, Transformers) coverage.
- UI snapshots or external testing dependencies.
- End-to-end audio/ASR hardware tests.

## 4. Architecture Alignment

- Keep UI logic in view models/helpers; avoid tying tests to AppKit rendering.
- Prefer pure functions or simple structs for view-specific decisions.
- Reuse existing test patterns in `OraTests` (no new frameworks).

## 5. Implementation Plan

### Focus Areas (lowest coverage)

- `Ora/Overlay/ChatBubbleView.swift`
- `Ora/Overlay/ToolStateView.swift`
- `Ora/Setup/SetupWindow.swift`
- `Ora/Setup/Steps/WelcomeStepView.swift`
- `Ora/Setup/Steps/PermissionsStepView.swift`
- `Ora/Setup/Steps/DownloadStepView.swift`
- `Ora/Setup/Steps/ReadyStepView.swift`
- `Ora/Preferences/Tabs/PermissionsPreferencesView.swift`
- `Ora/Preferences/Tabs/AboutPreferencesView.swift`
- `Ora/Utilities/AppIcon.swift`
- `Ora/LLM/Types.swift`
- `Ora/LLM/LLMOutput.swift`
- `Ora/Tools/Calendar/CalendarFindSlotsTool.swift`
- `Ora/Tools/Calendar/CalendarCreateEventTool.swift`
- `Ora/Tools/Calendar/EventStoreProvider.swift`
- `Ora/Permissions/EventKitPermission.swift`
- `Ora/Persistence/AuditLogger.swift`
- `Ora/Orchestration/SimplePipelineController.swift`
- `Ora/Models/Strategies/FluidAudioStrategy.swift`

### Tests to Add

- `OraTests/SetupViewsTests.swift` - instantiate step views and verify helper outputs (titles, button labels, gating flags).
- `OraTests/PreferencesViewTests.swift` - validate tab content helper outputs (links, version strings, action labels).
- `OraTests/OverlayViewsTests.swift` - verify chat bubble and tool-state rendering inputs via extracted helpers (role -> style, state -> label/icon).
- `OraTests/CalendarToolsTests.swift` - add more slot-find and create-event scenarios.
- `OraTests/PermissionsTests.swift` - expand EventKit permission mapping coverage.
- `OraTests/LLMTypesTests.swift` - validate output formatting and enums.

### File Touch Strategy

- Add small, testable helpers (e.g., `static func labelText(for:)`) in view files or companion helper types.
- Avoid new dependencies; keep helpers in `Utilities/` if shared.

## 6. Acceptance Criteria

- [ ] AC-1: `Ora.app` coverage is **>= 85%** in `xcrun xccov view --report --only-targets`.
- [ ] AC-2: No new third-party dependencies added.
- [ ] AC-3: New tests added for the focus areas above, with failures reproducible in CI.
- [ ] AC-4: `docs/stories/README.md` updated to mark M.01 complete when done.

## 7. Verification Plan

### Automated Tests

- [x] `xcodebuild test -project Ora.xcodeproj -scheme Ora -enableCodeCoverage YES -resultBundlePath agent-tools/test-results-coverage-2.xcresult`
- [x] `xcrun xccov view --report --only-targets agent-tools/test-results-coverage-2.xcresult`

### Manual Tests

- [ ] None required (unit coverage focus).

## 8. Risks & Mitigations

- SwiftUI view logic may be hard to unit-test directly; mitigate by extracting deterministic helpers.
- Coverage gains may plateau; prioritize high-impact files first.

## 9. Open Questions

- Should we accept a lower threshold for UI-heavy modules if 85% is impractical?
- Are there UI tests already planned that can cover setup/overlay views instead?
