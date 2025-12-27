# Foundations Epic

Core infrastructure stories that establish the Ora app shell, permissions, model management, and basic UI before any AI features are integrated.

## Overview

The Foundations epic creates a working macOS menu bar application with:
- App lifecycle and menu bar presence
- Permission management (Microphone, Accessibility, Calendar, Reminders, Contacts)
- Model download infrastructure
- First-run setup experience
- Preferences window
- Global hotkey registration

## Story Index

| Story | Title | Description | Dependencies |
|-------|-------|-------------|--------------|
| **F.00** | [Design Assets](F.00-DESIGN-ASSETS.md) | App icon, menu bar icons, asset catalog setup | None |
| **F.01** | [App Shell & Menu Bar](F.01-APP-SHELL-MENUBAR.md) | Basic macOS app with menu bar icon and quit functionality | F.00 (optional) |
| **F.02** | [Permissions Manager](F.02-PERMISSIONS-MANAGER.md) | Request and track system permissions | F.01 |
| **F.03** | [Model Manager](F.03-MODEL-MANAGER.md) | Download, verify, and manage AI models | F.01 |
| **F.04** | [First-Run Setup](F.04-FIRST-RUN-SETUP.md) | Onboarding modal with permissions and model download | F.01, F.02, F.03 |
| **F.05** | [Global Hotkey](F.05-GLOBAL-HOTKEY.md) | Register and handle ⌥Space activation | F.01, F.02 |
| **F.06** | [Preferences Window](F.06-PREFERENCES-WINDOW.md) | Settings UI for hotkey, models, and preferences | F.01, F.02, F.03 |
| **F.07** | [Overlay Window](F.07-OVERLAY-WINDOW.md) | Floating conversation UI that appears on activation | F.01, F.05 |
| **F.08** | [Persistence Layer](F.08-PERSISTENCE-LAYER.md) | SwiftData setup for sessions and audit logs | F.01 |

## Dependency Graph

```
F.00 (Design Assets) ─ optional ─┐
                                 │
F.01 (App Shell) ◄───────────────┘
  │
  ├── F.02 (Permissions)
  │     └── F.05 (Hotkey) ─────────┐
  │                                │
  ├── F.03 (Model Manager)         │
  │     └── F.04 (First-Run) ◄─────┤
  │                                │
  ├── F.06 (Preferences) ◄─────────┤
  │                                │
  ├── F.07 (Overlay) ◄─────────────┘
  │
  └── F.08 (Persistence)
```

## Suggested Implementation Order

1. **F.01** - App Shell (foundation for everything)
2. **F.08** - Persistence (used by other components)
3. **F.02** - Permissions (required for hotkey/audio)
4. **F.03** - Model Manager (required for first-run)
5. **F.04** - First-Run Setup (gates app usage)
6. **F.05** - Global Hotkey (core interaction)
7. **F.07** - Overlay Window (UI for interaction)
8. **F.06** - Preferences (can be last, lower priority)
9. **F.00** - Design Assets (can be done in parallel, integrate when ready)

## Tech Stack

- **Language:** Swift 6.0 with strict concurrency
- **UI Framework:** AppKit (menu bar) + SwiftUI (windows)
- **Persistence:** SwiftData
- **Target:** macOS 26 (Tahoe), Apple Silicon (M1+)

## Success Criteria

After completing all foundation stories:
- [ ] App launches as menu bar agent (no dock icon)
- [ ] App icon displays correctly in Finder/About
- [ ] Menu bar icons adapt to light/dark mode
- [ ] First-run setup guides user through permissions and model download
- [ ] Global hotkey (⌥Space) registered and functional
- [ ] Overlay window appears/dismisses on hotkey
- [ ] Preferences window accessible from menu bar
- [ ] All required permissions requested and tracked
- [ ] Models downloaded to `~/Library/Application Support/Ora/Models/`
- [ ] SwiftData persistence ready for sessions and audit logs
