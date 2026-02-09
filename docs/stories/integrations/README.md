# Cloud Integrations Epic

Cloud provider support for Ora with secure credential handling, provider switching, and model selection UX.

## Overview

This epic adds optional cloud inference paths while preserving Ora's local-first defaults:
- Secure credential storage in Keychain
- Provider abstraction and runtime switching
- Provider setup UX in Preferences
- OAuth support for OpenAI Codex
- Fast model/provider switching with clear availability states

## Story Index

| Story | Title | Description | Dependencies |
|-------|-------|-------------|--------------|
| **C.01** | [Keychain Credential Manager](C.01-KEYCHAIN-CREDENTIAL-MANAGER.md) | Secure API key storage and retrieval for cloud providers | F.08 |
| **C.02** | [Cloud Provider Abstraction](C.02-CLOUD-PROVIDER-ABSTRACTION.md) | Common provider interface, registration, and switching | L.01, C.01 |
| **C.03** | [Anthropic Claude Provider](C.03-ANTHROPIC-PROVIDER.md) | Anthropic streaming provider integration | C.01, C.02 |
| **C.04** | [OpenAI Provider](C.04-OPENAI-PROVIDER.md) | OpenAI streaming provider integration | C.01, C.02 |
| **C.05** | [Provider Preferences UI](C.05-PROVIDER-PREFERENCES-UI.md) | Preferences tab for provider setup, credentials, and model choices | C.01, C.02 |
| **C.06** | [OpenAI Codex OAuth Support](C.06-CODEX-SUPPORT.md) | OAuth flow for ChatGPT-backed OpenAI usage | C.04, C.05 |
| **C.07** | [Menubar Model Selection & OpenAI Model Discovery](C.07-MENUBAR-MODEL-SELECTION-OPENAI-DISCOVERY.md) | Menubar quick model selector, OpenAI discovery, and setup guidance flow | C.02, C.04, C.05 |

## Dependency Graph

```text
C.01 (Keychain Credential Manager)
  └── C.02 (Cloud Provider Abstraction)
      ├── C.03 (Anthropic Provider)
      ├── C.04 (OpenAI Provider)
      └── C.05 (Provider Preferences UI)
          ├── C.06 (Codex OAuth Support)
          └── C.07 (Menubar Model Selection & OpenAI Discovery)
```

## Success Criteria

- [ ] Users can configure cloud credentials without leaving Ora.
- [ ] Provider switching is explicit and persisted.
- [ ] Active provider/model is always visible and understandable.
- [ ] Unconfigured providers present actionable setup guidance instead of opaque failures.
