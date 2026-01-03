# S.04 - Skills Marketplace

**Epic:** Skills
**Status:** Future
**Priority:** P3 (Low)
**Estimated Effort:** 5 days
**Dependencies:** S.01 (Skills Runtime), S.03 (Skill Scripts) - partial
**Target:** macOS 26 (Tahoe)
**Design Reference:** None

---

## 1. Objective

Create an online skills marketplace where users can discover, download, and install community-created skills, enabling an ecosystem of shared automation workflows.

## 2. User Story

As a user, I want to browse and install skills created by others, so that I can quickly add new capabilities to Ora without writing my own skills.

## 3. Scope

### In Scope

- Skills marketplace backend (API or static index)
- Skills browser UI in Preferences
- Skill download and installation flow
- Skill update checking
- Skill ratings/popularity (optional)
- Publisher verification (optional)

### Out of Scope

- User-generated content moderation at scale
- Payment/monetization
- Skill creation/publishing from within Ora
- Running untrusted scripts without consent

## 4. Architecture Alignment

### High-Level Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    Skills Marketplace                        │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│  ┌─────────────┐    ┌─────────────┐    ┌─────────────┐      │
│  │  Ora App    │    │  Index API  │    │  GitHub/CDN │      │
│  │  (Client)   │◄──►│  (Catalog)  │◄──►│  (Source)   │      │
│  └─────────────┘    └─────────────┘    └─────────────┘      │
│        │                                     ▲               │
│        │                                     │               │
│        ▼                                     │               │
│  ┌─────────────┐                      ┌─────────────┐       │
│  │   ~/Library/│◄─────────────────────│   Download  │       │
│  │   .../Skills│    Install           │   Skill     │       │
│  └─────────────┘                      └─────────────┘       │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

### Index Format

```json
{
  "version": "1.0",
  "skills": [
    {
      "id": "meeting-scheduler",
      "name": "Meeting Scheduler",
      "description": "Schedule meetings with smart slot finding",
      "author": "Ora Team",
      "version": "1.2.0",
      "download_url": "https://...",
      "checksum": "sha256:...",
      "has_scripts": false,
      "verified": true
    }
  ]
}
```

### Security Considerations

- Downloaded skills are untrusted by default
- Skills with scripts require explicit consent
- Checksum verification before installation
- Option to only allow verified publishers

## 5. Implementation Plan (Draft)

### 5.1 Files to Create

| File | Purpose |
|:-----|:--------|
| `Ora/Skills/SkillsMarketplace.swift` | Marketplace client (fetch index, download) |
| `Ora/Skills/SkillInstaller.swift` | Install/update/uninstall skills |
| `Ora/Preferences/Tabs/SkillsMarketplaceView.swift` | Browse/install UI |

### 5.2 Files to Modify

| File | Change |
|:-----|:-------|
| `Ora/Preferences/Tabs/SkillsPreferencesView.swift` | Add "Browse Marketplace" button |
| `Ora/Skills/SkillStore.swift` | Support installed skill versioning |

### 5.3 Tests to Add

| File | Coverage |
|:-----|:---------|
| `OraTests/Skills/SkillsMarketplaceTests.swift` | Index fetch, download, checksum verification |
| `OraTests/Skills/SkillInstallerTests.swift` | Install, update, uninstall flows |

### 5.4 Dependencies/Config

- HTTPS for marketplace index and downloads
- Checksum verification library (built-in CryptoKit)

## 6. Acceptance Criteria

- [ ] AC-1: Marketplace index fetched from configurable URL
- [ ] AC-2: Skills browser shows available skills with name, description, author
- [ ] AC-3: User can install a skill with one click
- [ ] AC-4: Installed skills appear in skill list after install
- [ ] AC-5: Skills with scripts show warning before install
- [ ] AC-6: Checksum verified before installation
- [ ] AC-7: Update available indicator for installed skills
- [ ] AC-8: Uninstall button for user-installed skills

## 7. Verification Plan

### Automated Tests

- [ ] Unit tests for index parsing and validation
- [ ] Unit tests for checksum verification
- [ ] Unit tests for install/update/uninstall flows
- [ ] Integration test with mock marketplace server

### Manual Tests

- [ ] Browse marketplace, verify skills display correctly
- [ ] Install a skill, verify it appears in skill list
- [ ] Update a skill, verify new version replaces old
- [ ] Uninstall a skill, verify it's removed

## 8. Performance / Reliability Considerations

- Cache marketplace index locally (TTL: 1 hour)
- Background download with progress indicator
- Retry logic for failed downloads

## 9. Risks & Mitigations

| Risk | Mitigation |
|:-----|:-----------|
| Malicious skills | Checksum verification, verified publishers, script consent |
| Index availability | Cache index locally, fallback to bundled |
| Version conflicts | Clear upgrade/downgrade UX |
| Privacy concerns | Skills fetched over HTTPS, minimal tracking |

## 10. Open Questions

- Self-hosted index vs. GitHub-based index?
- How to handle skill updates (auto-update vs. manual)?
- Publisher verification process?
- Content policy for marketplace?
- Should bundled skills be updatable via marketplace?

---

## Notes

Consider starting with a simpler approach:
- GitHub repository as skill source
- Manual "Add from URL" before full marketplace
- Focus on curation over scale initially

---

## Implementation Summary

(TBD after implementation.)

## Code Review Findings

(TBD by review agent.)

## Completion Status

(TBD after merge.)
