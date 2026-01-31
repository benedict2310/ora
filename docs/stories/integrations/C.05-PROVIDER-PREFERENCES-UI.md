# C.05 - Provider Preferences UI

**Epic:** Cloud Integrations (C)
**Status:** To Do
**Priority:** P1
**Estimated Effort:** 1-2 days
**Dependencies:** C.01 (Keychain Credential Manager), C.02 (Cloud Provider Abstraction)
**Target:** macOS 26 (Tahoe)

---

## Objective

Add a "Providers" tab to Ora's Preferences window where users can configure cloud LLM providers: enter API keys, select the active provider, and choose which cloud model to use. The UI must make it obvious when Ora is running locally vs. using a cloud provider.

## User Story

As a **user**, I want to **configure cloud AI providers in Ora's preferences** so that I can **enter my API key, choose which provider to use, and switch between local and cloud without touching config files**.

## Architecture Context & Reuse Guidance

### MUST REUSE
- **`PreferencesWindow`** (`Ora/Preferences/PreferencesWindow.swift`) - Add new tab
- **Existing tab pattern** - Follow `ModelsPreferencesView`, `GeneralPreferencesView` structure
- **`KeychainCredentialStore`** (from C.01) - Store/retrieve API keys
- **`LLMProviderManager`** (from C.02) - Switch active provider
- **`LLMProviderType`** / **`CloudProvider`** enums - Provider identifiers

---

## Scope

### In Scope
- New "Providers" tab in Preferences window
- Provider selection picker (Local / Anthropic / OpenAI)
- API key entry fields with secure text field
- API key save/delete to Keychain
- Cloud model selection per provider
- Connection status indicator (valid key vs. no key vs. error)
- Visual indicator in main UI when using cloud provider (e.g., small badge)

### Out of Scope
- API key validation via test request (nice-to-have, not required for v1)
- Usage tracking / billing display
- Per-conversation provider selection (global setting only)
- OAuth flows

---

## Design

### Preferences Tab Layout

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

    init(...) { ... }

    func loadState() async { ... }
    func saveAnthropicKey() async { ... }
    func saveOpenAIKey() async { ... }
    func deleteAnthropicKey() async { ... }
    func deleteOpenAIKey() async { ... }
    func switchProvider(_ type: LLMProviderType) async { ... }
}
```

### Cloud Indicator

When a cloud provider is active, the overlay should show a small indicator so users always know their data is being sent externally:

```swift
// In overlay status area or menu bar
if providerType.isCloud {
    Label("Cloud", systemImage: "cloud.fill")
        .font(.caption2)
}
```

---

## File Touch List

| File | Action | Rationale |
|:-----|:-------|:----------|
| `Ora/Preferences/Tabs/ProviderPreferencesView.swift` | Create | Provider settings UI |
| `Ora/Preferences/Tabs/ProviderPreferencesViewModel.swift` | Create | View model for provider prefs |
| `Ora/Preferences/PreferencesWindow.swift` | Modify | Add Providers tab |
| `Ora/UI/Components/CloudIndicator.swift` | Create | Small badge for cloud mode |
| `OraTests/Preferences/ProviderPreferencesViewModelTests.swift` | Create | View model unit tests |

---

## Tests and Validation

### Unit Tests

- `test_loadState_detectsSavedKeys` - Reads Keychain state on load
- `test_saveKey_writesToKeychain` - Save triggers credential store write
- `test_deleteKey_removesFromKeychain` - Delete removes credential
- `test_switchProvider_updatesManager` - Selection triggers LLMProviderManager switch
- `test_switchToCloud_withoutKey_showsError` - Cannot switch without API key
- `test_selectedProvider_persisted` - Survives app restart

### Manual Verification

1. Open Preferences > Providers
2. Enter Anthropic API key, click Save → status shows "Key saved"
3. Select "Anthropic Claude" as active provider
4. Close and reopen preferences → settings persist
5. Verify cloud indicator appears in overlay
6. Switch back to Local → cloud indicator disappears
7. Delete API key → status shows "No key configured"

---

## Acceptance Criteria

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

## Risks and Open Questions

| Risk/Question | Notes |
|:--------------|:------|
| Key validation | v1 does not validate keys (no test API call). Invalid keys fail at first use with a clear error. Could add "Test Connection" button later. |
| Secure text field | SwiftUI's `SecureField` shows dots. Consider a "reveal" toggle for verification. |
| Tab ordering | Providers tab should appear after General, before Models (or after Models). TBD based on information hierarchy. |
| Model list freshness | Hardcoded model lists. Needs manual update when providers release new models. |
