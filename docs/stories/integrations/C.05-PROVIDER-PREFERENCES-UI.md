# C.05 - Provider Preferences UI

**Epic:** Cloud Integrations (C)
**Status:** To Do
**Priority:** P1
**Estimated Effort:** 1-2 days
**Dependencies:** C.01 (Keychain Credential Manager), C.02 (Cloud Provider Abstraction)
**Target:** macOS 26 (Tahoe)

---

## 1. Objective

Add a "Providers" tab to Ora's Preferences window where users can configure cloud LLM providers: enter API keys, select the active provider, and choose which cloud model to use. The UI must make it obvious when Ora is running locally vs. using a cloud provider.

## 2. User Story

As a **user**, I want to **configure cloud AI providers in Ora's preferences** so that I can **enter my API key, choose which provider to use, and switch between local and cloud without touching config files**.

## 3. Scope

### In Scope
- New "Providers" tab in Preferences window
- Provider selection picker (Local / Anthropic / OpenAI)
- API key entry fields with secure text field
- API key save/delete to Keychain via `KeychainCredentialStore`
- Cloud model selection per provider
- Connection status indicator (valid key vs. no key vs. error)
- Visual indicator in main UI when using cloud provider (small badge)

### Out of Scope
- API key validation via test request (nice-to-have, not required for v1)
- Usage tracking / billing display
- Per-conversation provider selection (global setting only)
- OAuth flows

---

## 4. Architecture Alignment

This story builds on the Cloud Provider Abstraction (C.02) and Keychain Credential Manager (C.01). It adds a SwiftUI preferences tab that wires the existing `LLMProviderManager` and `KeychainCredentialStore` into a user-facing configuration surface.

### MUST REUSE
- **`PreferencesWindow`** (`Ora/Preferences/PreferencesWindow.swift`) - Add new tab via `PreferencesTab` enum
- **`PreferencesCoordinator`** (`Ora/Preferences/PreferencesCoordinator.swift`) - Add `.providers` case to `PreferencesTab`
- **Existing tab pattern** - Follow `ModelsPreferencesView`, `GeneralPreferencesView` structure (`Form` with `.formStyle(.grouped)`)
- **`KeychainCredentialStore`** (from C.01) - Store/retrieve/delete API keys via `CredentialStore` protocol
- **`LLMProviderManager`** (from C.02) - Switch active provider via `switchProvider(to:)`, read state via `getSelectedProviderType()`
- **`LLMProviderType`** enum - Provider identifiers (`.local`, `.anthropic`, `.openai`) with `displayName` and `isCloud`
- **`CloudProvider`** enum - Maps to keychain operations (`.anthropic`, `.openai`)
- **`AnthropicModel`** / **`OpenAIModel`** enums - Existing model enums with `displayName` and `CaseIterable`

### UI Reference

```
┌─────────────────────────────────────────────────┐
│  Providers                                       │
├─────────────────────────────────────────────────┤
│                                                  │
│  Active Provider                                 │
│  ┌──────────────────────────────────┐            │
│  │ ○ Local (On-Device)    Qwen 3 4B│            │
│  │ ○ Anthropic Claude     ●        │            │
│  │ ○ OpenAI               ○        │            │
│  └──────────────────────────────────┘            │
│                                                  │
│  ─── Anthropic ───────────────────────           │
│  API Key:  [••••••••••••••••••] [Save]           │
│  Model:    [Claude Sonnet 4      ▾]              │
│  Status:   ✓ Key saved                           │
│                                                  │
│  ─── OpenAI ──────────────────────────           │
│  API Key:  [                    ] [Save]         │
│  Model:    [GPT-4o               ▾]              │
│  Status:   No key configured                     │
│                                                  │
│  ⓘ Cloud providers send your prompts to          │
│    external servers. Local mode keeps             │
│    everything on-device.                          │
│                                                  │
└─────────────────────────────────────────────────┘
```

## 5. Implementation Plan (Draft)

### 5.1 Files to Create

| File | Purpose |
|:-----|:--------|
| `Ora/Preferences/Tabs/ProviderPreferencesView.swift` | Provider settings UI (SwiftUI Form with grouped style) |
| `Ora/Preferences/Tabs/ProviderPreferencesViewModel.swift` | View model: loads keychain state, saves/deletes keys, switches provider |
| `Ora/UI/Components/CloudIndicator.swift` | Small badge shown in overlay when cloud provider is active |
| `OraTests/Preferences/ProviderPreferencesViewModelTests.swift` | View model unit tests |

### 5.2 Files to Modify

| File | Change |
|:-----|:-------|
| `Ora/Preferences/PreferencesCoordinator.swift` | Add `.providers` case to `PreferencesTab` enum with title and icon |
| `Ora/Preferences/PreferencesWindow.swift` | Add `case .providers: ProviderPreferencesView()` to tab switch |
| `Ora/Overlay/OverlayView.swift` | Add `CloudIndicator` when `LLMProviderType.isCloud` is true |

### 5.3 Tests to Add

- `test_loadState_detectsSavedKeys` - Reads Keychain state on load, sets status to `.saved` when key exists
- `test_loadState_noKeys_showsNoKey` - Sets status to `.noKey` when no key in Keychain
- `test_saveKey_writesToKeychain` - Save triggers `CredentialStore.save()` and updates status
- `test_deleteKey_removesFromKeychain` - Delete calls `CredentialStore.delete()` and clears status
- `test_switchProvider_updatesManager` - Selection triggers `LLMProviderManager.switchProvider(to:)`
- `test_switchToCloud_withoutKey_showsError` - Cannot switch to cloud provider without saved API key
- `test_selectedProvider_persistedViaUserDefaults` - Provider selection persists via `UserDefaults.selectedLLMProvider`

## Design Details

### View Model

```swift
@MainActor
@Observable
class ProviderPreferencesViewModel {

    var selectedProvider: LLMProviderType
    var anthropicKeyInput: String = ""
    var openAIKeyInput: String = ""
    var anthropicModel: AnthropicModel = .sonnet
    var openAIModel: OpenAIModel = .gpt4o

    var anthropicKeyStatus: KeyStatus = .checking
    var openAIKeyStatus: KeyStatus = .checking

    enum KeyStatus {
        case noKey
        case saved
        case checking
        case error(String)
    }

    private let credentialStore: CredentialStore
    private let providerManager: LLMProviderManager

    func loadState() async { ... }
    func saveAnthropicKey() async { ... }
    func saveOpenAIKey() async { ... }
    func deleteAnthropicKey() async { ... }
    func deleteOpenAIKey() async { ... }
    func switchProvider(_ type: LLMProviderType) async { ... }
}
```

### Cloud Indicator

When a cloud provider is active, the overlay shows a small indicator so users always know their data is being sent externally:

```swift
// In overlay status area
if providerType.isCloud {
    Label("Cloud", systemImage: "cloud.fill")
        .font(.caption2)
}
```

---

## 6. Acceptance Criteria

- [ ] **AC-1:** "Providers" tab appears in Preferences window
- [ ] **AC-2:** Provider selection picker with Local/Anthropic/OpenAI options
- [ ] **AC-3:** Secure text fields for API key entry
- [ ] **AC-4:** Save/Delete buttons for each provider's API key
- [ ] **AC-5:** Key status indicator (saved / no key / error)
- [ ] **AC-6:** Model selection dropdown per provider
- [ ] **AC-7:** Privacy disclaimer visible ("Cloud providers send prompts to external servers")
- [ ] **AC-8:** Cloud indicator shown in main UI when cloud provider active
- [ ] **AC-9:** Settings persist across app restarts

---

## 7. Verification Plan

### Automated Tests

- `test_loadState_detectsSavedKeys` - Reads Keychain state on load, sets status correctly
- `test_loadState_noKeys_showsNoKey` - Sets status to `.noKey` when no key exists
- `test_saveKey_writesToKeychain` - Save triggers credential store write
- `test_deleteKey_removesFromKeychain` - Delete removes credential
- `test_switchProvider_updatesManager` - Selection triggers LLMProviderManager switch
- `test_switchToCloud_withoutKey_showsError` - Cannot switch without API key
- `test_selectedProvider_persistedViaUserDefaults` - Survives app restart

### Manual Tests

1. Open Preferences, verify "Providers" tab appears in segmented picker
2. Enter Anthropic API key, click Save, verify status shows "Key saved"
3. Select "Anthropic Claude" as active provider
4. Close and reopen preferences, verify settings persist
5. Verify cloud indicator appears in overlay
6. Switch back to Local, verify cloud indicator disappears
7. Delete API key, verify status shows "No key configured"

---

## Risks and Open Questions

| Risk/Question | Notes |
|:--------------|:------|
| Key validation | v1 does not validate keys via API call. Invalid keys fail at first use with a clear error. Could add "Test Connection" button later. |
| Secure text field | SwiftUI's `SecureField` shows dots. Consider a "reveal" toggle for verification. |
| Tab ordering | Providers tab should appear after General, before or after Models. Follow information hierarchy. |
| Model list freshness | Hardcoded model lists via `AnthropicModel` / `OpenAIModel` enums. Needs manual update when providers release new models. |

---

## Code Review Findings

**Reviewer:** Pi Subagent
**Date:** 2026-02-08T22:58:00Z
**Commit reviewed:** 54f2bd2
**Iteration:** 1

### Summary
- Files reviewed: 13
- Build status: Pass

### Issues Found

#### P0 - Critical (Must fix)
- [x] None

#### P1 - Major (Should fix)
- [x] None

#### P2 - Minor (Can defer)
- [x] None

### Future Considerations (Out of Scope)
- None

### Approval Status
- [x] All P0 issues resolved
- [x] All P1 issues resolved
- [x] Ready for merge

---

## Implementation Summary
**Date:** 2026-02-08
**Branch:** `feat/C.05-provider-preferences-ui`
**Commits:** 5
**Implemented by:** codex (complexity score: 9/10)
**Reviewed by:** pi (1 iteration)

### Files Changed
- `Ora/Preferences/Tabs/ProviderPreferencesView.swift` - Created: Provider settings UI with radio group, secure fields, model pickers
- `Ora/Preferences/Tabs/ProviderPreferencesViewModel.swift` - Created: View model for keychain state, provider switching, model persistence
- `Ora/UI/Components/CloudIndicator.swift` - Created: Badge shown in overlay when cloud provider active
- `Ora/Preferences/PreferencesCoordinator.swift` - Modified: Added `.providers` case to `PreferencesTab` enum
- `Ora/Preferences/PreferencesWindow.swift` - Modified: Added `ProviderPreferencesView` to tab switch
- `Ora/Overlay/OverlayView.swift` - Modified: Added `CloudIndicator` when cloud provider active
- `Ora/Cloud/LLMProviderManager.swift` - Modified: Added model selection persistence via UserDefaults
- `Ora/AppDelegate.swift` - Modified: Register provider factories on launch
- `OraTests/Preferences/ProviderPreferencesViewModelTests.swift` - Created: 7 tests covering load, save, delete, switch, persistence
- `OraTests/Cloud/LLMProviderManagerTests.swift` - Modified: Updated for new initializer
- `OraTests/OverlayViewsTests.swift` - Modified: Added cloud indicator test
- `OraTests/PreferencesTests.swift` - Modified: Updated for providers tab
