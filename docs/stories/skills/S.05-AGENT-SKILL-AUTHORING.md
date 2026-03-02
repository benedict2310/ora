# S.05 - Agent Skill Authoring

**Epic:** Skills
**Status:** Not Started
**Priority:** P1 (High)
**Estimated Effort:** 3 days
**Dependencies:** S.01 (Skills Runtime), S.06 (Dynamic Tool Discovery)
**Target:** macOS 26 (Tahoe)
**Design Reference:** None

---

## 1. Objective

Let Ora's agent create, update, and delete skills through conversation. The user describes a workflow, the agent generates a SKILL.md, and the user confirms before it's saved. This replaces the need for a third-party skill marketplace — skills are authored locally by the agent, tailored to the user's own calendar, contacts, and habits.

## 2. User Story

As a user, I want to tell Ora "create a skill for my Monday planning routine" and have it save that workflow for future use, so that I can invoke complex multi-step workflows by name without re-explaining them every time.

## 3. Scope

### In Scope

- `skills.create` tool — agent generates and saves a new SKILL.md
- `skills.update` tool — agent rewrites an existing agent-created skill
- `skills.delete` tool — agent removes an agent-created skill
- `SkillMetadata.Source.agent` new source type
- Dedicated modal confirmation dialog with scrollable SKILL.md content preview
- "Created by Ora" badge in Skills Preferences list
- Slug generation and collision handling
- Audit logging for all authoring operations
- Compatibility with S.06 deferred-tool flow (`skills.create|update|delete` are discoverable through `tools.discover`)

### Out of Scope

- Proactive skill suggestions after workflows (explicit user request only)
- Creating skills with `scripts/` folders (requires S.03)
- Rich in-app skill editor UI (users edit files directly or ask agent to update)
- Agent modifying bundled or user-installed skills (read-only to agent)
- Skill versioning / history

## 4. Architecture Alignment

### Source Hierarchy

```swift
public enum Source: String, Codable, Sendable {
    case bundled   // Ora.app/Contents/Resources/Skills/ — read-only to agent
    case user      // ~/Library/…/Ora/Skills/           — read-only to agent
    case agent     // ~/Library/…/Ora/AgentSkills/      — agent CRUD allowed
}
```

Agent tools can only mutate `source == .agent` skills. Bundled and user skills are immutable to the agent — attempting to update or delete them returns an error.

### Storage Layout (Decision)

- User-authored skills stay under `~/Library/Application Support/Ora/Skills/`
- Agent-authored skills are isolated under `~/Library/Application Support/Ora/AgentSkills/`
- `SkillStore` scans bundled + user + agent roots, but `skills.create` must reject IDs that already exist in any source to prevent ambiguous shadowing

### New Tools

Under S.06, these tools should keep default `loadPolicy = .deferred` (not core). The agent should discover them via `tools.discover` in fresh sessions when needed.

#### `skills.create`

| Property | Value |
|:---------|:------|
| Kind | `.mutate` (confirmation required) |
| Parameters | `name` (string), `description` (string), `content` (string — full SKILL.md markdown) |
| Returns | `{id, name, source: "agent"}` on success |
| Confirmation | Shows full proposed SKILL.md content in a scrollable preview dialog |

**Flow:**
1. Agent generates SKILL.md content based on conversation context
2. Tool validates: name non-empty, content has frontmatter, slug not reserved
3. Confirmation dialog shows proposed content — user approves or cancels
4. On approval: write to `~/Library/…/Ora/AgentSkills/<slug>/SKILL.md`, trigger `SkillStore.rebuildIndex()`
5. Skill immediately available in subsequent turns

#### `skills.update`

| Property | Value |
|:---------|:------|
| Kind | `.mutate` (confirmation required) |
| Parameters | `id` (string — must match an existing agent-created skill), `content` (string — new full SKILL.md markdown) |
| Returns | `{id, name}` on success |
| Confirmation | Shows new content preview |
| Restriction | Rejects if `source != .agent` — bundled/user skills are immutable |

`id` matching is exact only for mutating operations. No fuzzy matching for `skills.update`.

#### `skills.delete`

| Property | Value |
|:---------|:------|
| Kind | `.mutate` (confirmation required) |
| Parameters | `id` (string — must match an existing agent-created skill) |
| Returns | `{id, deleted: true}` on success |
| Confirmation | Shows skill name and description before deletion |
| Restriction | Rejects if `source != .agent` |

`id` matching is exact only for mutating operations. No fuzzy matching for `skills.delete`.

### Slug Generation

```
name: "Monday Planning Routine"
slug: "monday-planning-routine"     // lowercase, hyphens, max 40 chars
path: ~/Library/…/Ora/AgentSkills/monday-planning-routine/SKILL.md
```

Collision handling: if `monday-planning-routine` already exists in the **agent** root, try `monday-planning-routine-2`, `-3`, etc. (up to `-9`, then error). If the base slug already exists in bundled/user roots, reject create with an explicit conflict error (do not shadow another source).

### SKILL.md Format Written by Agent

The agent writes a standard SKILL.md that `SkillFrontmatterParser` already understands:

```markdown
---
name: Monday Planning Routine
description: Reviews the week's calendar, open reminders, and flags scheduling conflicts.
version: 1.0
---

# Monday Planning Routine

## When to use this skill
Use when the user asks about their week, Monday planning, or weekly review.

## Procedure
1. Call `calendar.query` for the current week (today through Sunday)
2. Call `reminders.list` to surface any overdue or due-this-week reminders
3. Identify back-to-back meetings or gaps that could be used for focus work
4. Summarize findings in a concise spoken format: events today, key conflicts, reminders due
```

The agent is responsible for generating well-structured content. No schema validation beyond frontmatter parsing — if the frontmatter is valid, it saves.

### Confirmation Dialog — `skills.create` / `skills.update`

Use a dedicated modal sheet/dialog for this flow (not the inline overlay proposal bubble), because the payload is multi-line markdown that requires full review.

```
┌──────────────────────────────────────────────────────────┐
│  Save Skill: "Monday Planning Routine"                   │
├──────────────────────────────────────────────────────────┤
│                                                          │
│  This skill will be saved and available in all future   │
│  conversations.                                          │
│                                                          │
│  ┌────────────────────────────────────────────────────┐  │
│  │ ---                                                │  │
│  │ name: Monday Planning Routine                      │  │
│  │ description: Reviews the week's calendar...        │  │
│  │ ---                                                │  │
│  │                                                    │  │
│  │ # Monday Planning Routine                         │  │
│  │ ...                                                │  │
│  └─────────────────────── scroll ───────────────────┘  │
│                                                          │
│               [ Cancel ]      [ Save Skill ]            │
│                                                          │
└──────────────────────────────────────────────────────────┘
```

### Content Sanitization

Agent-generated content is treated as trusted (it came from Ora's own LLM), but `ContentSanitizer` is still applied before writing as defense-in-depth: strips control characters, normalizes whitespace. The 5000-char context injection limit applies at load time (via `skills.load`), not at write time — skills longer than 5000 chars can be saved, they'll just be truncated when loaded.

### Audit Logging

All authoring operations are logged with new `AuditCategory` cases:

| Event | Category | Fields |
|:------|:---------|:-------|
| Skill created | `.skillCreate` | skillId, name, contentHash, userConfirmed |
| Skill updated | `.skillUpdate` | skillId, name, contentHash, userConfirmed |
| Skill deleted | `.skillDelete` | skillId, name, userConfirmed |

`contentHash` is SHA-256 of the written content — allows detecting if a skill was manually edited after agent creation.

## 5. Implementation Plan (Draft)

### 5.1 Files to Create

| File | Purpose |
|:-----|:--------|
| `Ora/Tools/Skills/SkillsCreateTool.swift` | `skills.create` tool implementation |
| `Ora/Tools/Skills/SkillsUpdateTool.swift` | `skills.update` tool implementation |
| `Ora/Tools/Skills/SkillsDeleteTool.swift` | `skills.delete` tool implementation |
| `Ora/Skills/SkillSlugGenerator.swift` | Slug derivation and collision resolution |

### 5.2 Files to Modify

| File | Change |
|:-----|:-------|
| `Ora/Skills/SkillMetadata.swift` | Add `.agent` case to `Source` enum |
| `Ora/Models/ModelPaths.swift` | Add `agentSkillsRoot` path helper |
| `Ora/Skills/SkillStore.swift` | Add `Roots.agent`, scan third root, add `create(name:content:)`, `update(id:content:)`, `delete(id:)`, enforce exact-ID source restriction on mutating operations |
| `Ora/Tools/ToolRegistry.swift` | Register `skills.create`, `skills.update`, `skills.delete` |
| `Ora/Persistence/AuditLogEntry.swift` | Add `.skillCreate`, `.skillUpdate`, `.skillDelete` cases to `AuditCategory` |
| `Ora/Preferences/Tabs/SkillsPreferencesView.swift` | Show source badge (Bundled / User / Created by Ora) per skill |
| `Ora/UI/` (new modal view) | Add dedicated scrollable skill content confirmation modal for create/update/delete |
| `OraTests/Tools/ToolDiscoveryTests.swift` | Verify `tools.discover` can surface `skills.create|update|delete` |

### 5.3 Tests to Add

| File | Coverage |
|:-----|:---------|
| `OraTests/Skills/SkillSlugGeneratorTests.swift` | Slug generation, sanitization, collision handling |
| `OraTests/Skills/SkillAuthoringToolsTests.swift` | Create, update, delete flows; source restriction enforcement; error cases |

### 5.4 Dependencies/Config

- No new package dependencies
- `CryptoKit` for SHA-256 content hash (already available)

## 6. Acceptance Criteria

### Create

- [ ] AC-1: `skills.create` writes a valid SKILL.md to `~/Library/…/Ora/AgentSkills/<slug>/SKILL.md`
- [ ] AC-2: Created skill is immediately discoverable after `rebuildIndex()` completes
- [ ] AC-3: Confirmation dialog shows full proposed SKILL.md content (scrollable)
- [ ] AC-4: Slug is derived from name: lowercase, hyphens, max 40 chars
- [ ] AC-5: Slug collision resolved by appending `-2`…`-9`; error returned if all taken

### Update

- [ ] AC-6: `skills.update` overwrites content of an existing agent-created skill
- [ ] AC-7: `skills.update` returns error if skill `source != .agent`
- [ ] AC-8: `skills.update` requires confirmation showing new content
- [ ] AC-9: `skills.update` matches `id` exactly only; fuzzy matching is not allowed for mutating operations

### Delete

- [ ] AC-10: `skills.delete` removes the skill folder and triggers `rebuildIndex()`
- [ ] AC-11: `skills.delete` returns error if skill `source != .agent`
- [ ] AC-12: `skills.delete` requires confirmation showing skill name and description
- [ ] AC-13: `skills.delete` matches `id` exactly only; fuzzy matching is not allowed for mutating operations

### Safety

- [ ] AC-14: Agent cannot create, update, or delete bundled skills
- [ ] AC-15: Agent cannot create, update, or delete user-installed skills
- [ ] AC-16: `skills.create` rejects IDs/slugs that conflict with bundled/user skills (no cross-source shadowing)
- [ ] AC-17: All three tools respect existing tool confirmation gate (kind = `.mutate`)
- [ ] AC-18: Content sanitized via `ContentSanitizer` before write (control chars stripped)

### UI & Audit

- [ ] AC-19: Skills Preferences list shows source badge: "Bundled", "User-installed", or "Created by Ora"
- [ ] AC-20: `skills.create`/`skills.update` use a dedicated scrollable modal confirmation UI (not inline overlay proposal)
- [ ] AC-21: `.skillCreate`, `.skillUpdate`, `.skillDelete` events recorded in audit log with `contentHash`
- [ ] AC-22: `skills.create`, `skills.update`, and `skills.delete` remain deferred tools and are discoverable via `tools.discover` in fresh sessions

## 7. Verification Plan

### Automated Tests

- [ ] Slug generation: normal name, special characters, unicode, very long name, empty string
- [ ] Collision: existing slug → appends `-2`; all `-2`…`-9` taken → error
- [ ] `skills.create`: writes file, index updated, returns correct metadata
- [ ] `skills.update`: overwrites file, index updated; rejects non-agent skill; rejects fuzzy/non-exact id lookups
- [ ] `skills.delete`: removes folder, index updated; rejects non-agent skill; rejects fuzzy/non-exact id lookups
- [ ] Source restriction: attempt to update bundled skill → descriptive error
- [ ] Collision policy: create fails when slug conflicts with bundled/user skill id
- [ ] Tool discovery: `tools.discover("create skill")` / `("update skill")` / `("delete skill")` surfaces the corresponding skills authoring tool
- [ ] Audit entries: correct category, skillId, contentHash for each operation

### Manual Tests

- [ ] Say "create a skill for my weekly planning" → agent drafts skill → confirm → skill appears in list
- [ ] Say "update the weekly planning skill to also check email" → agent revises → confirm → content changes
- [ ] Say "delete the weekly planning skill" → confirm → skill gone from list
- [ ] Say "update the daily briefing skill" → agent returns error (bundled, immutable)
- [ ] Open Preferences → Skills → verify "Created by Ora" badge visible on agent-created skill
- [ ] Verify audit log contains `skillCreate` entry with contentHash

## 8. Performance / Reliability Considerations

- File write is synchronous and fast (~1ms); no performance concerns
- `rebuildIndex()` re-scans all skill folders (~100ms for 10 skills); acceptable after mutating operations
- SHA-256 hash of content is computed once at write time

## 9. Risks & Mitigations

| Risk | Mitigation |
|:-----|:-----------|
| Agent generates low-quality skill content | User reviews full content in confirmation dialog before saving; can cancel |
| Agent writes instructions that reference non-existent tools | Skills are guidance only; LLM will fail gracefully when tool isn't found |
| Skill accumulation over time clutters the list | Preferences UI shows all agent-created skills; user can delete individually |
| User tricks agent into writing a self-bypassing skill | Skills cannot execute tools directly; all tool calls still require confirmation |

## 10. Open Questions

- Should agent-created skills appear in the `{{available_skills}}` prompt block immediately, or only after the current turn completes? (Proposed: next turn — rebuildIndex runs async after confirmation)
- Should the user be able to promote an agent-created skill to "user" source (making it immutable to the agent)? (Defer — can be done via Preferences if needed)

---

## Implementation Summary

**Date:** 2026-03-02
**Branch:** `feat/S05-agent-skill-authoring`
**Commits:** 4
**Implemented by:** codex (complexity score: 10/10)
**Reviewed by:** Claude Code orchestrator (1 iteration, 3 issues fixed)

### Files Changed
- `Ora/Tools/Skills/SkillsCreateTool.swift` — Created: `skills.create` tool
- `Ora/Tools/Skills/SkillsUpdateTool.swift` — Created: `skills.update` tool
- `Ora/Tools/Skills/SkillsDeleteTool.swift` — Created: `skills.delete` tool
- `Ora/Tools/Skills/SkillAuthoringToolSupport.swift` — Created: shared support (sanitization, contentHash, validation)
- `Ora/Skills/SkillSlugGenerator.swift` — Created: slug derivation, collision resolution
- `Ora/Skills/SkillStore.swift` — Modified: added agent root, create/update/delete methods, size validation
- `Ora/Skills/SkillMetadata.swift` — Modified: added `.agent` source case
- `Ora/Skills/SkillError.swift` — Modified: added `immutableSource`, `slugExhausted`, `contentTooLarge`, etc.
- `Ora/Models/ModelPaths.swift` — Modified: added `agentSkillsRoot`
- `Ora/Overlay/SkillAuthoringConfirmationSheet.swift` — Created: dedicated modal confirmation UI
- `Ora/Overlay/OverlayState.swift` — Modified: added modal proposal state
- `Ora/Overlay/OverlayView.swift` — Modified: sheet presentation for skill authoring
- `Ora/Persistence/AuditLogEntry.swift` — Modified: added `.skillCreate/.skillUpdate/.skillDelete` categories
- `Ora/Persistence/Models/AuditLogEntryModel.swift` — Modified: updated audit storage
- `Ora/Preferences/Tabs/SkillsPreferencesView.swift` — Modified: source badge display
- `Ora/Tools/ToolRegistry.swift` — Modified: registered three new tools
- `Ora/Tools/ToolProtocol.swift` — Modified: added `skillDocumentPreview`/`skillDeletion` presentation modes
- `Ora/Tools/ToolHost.swift` — Modified: modal confirmation routing
- `Ora/Orchestration/AgentLoop.swift` — Modified: modal confirmation handling
- `OraTests/Skills/SkillSlugGeneratorTests.swift` — Created: 10 slug generation tests
- `OraTests/Skills/SkillAuthoringToolsTests.swift` — Created: 18 authoring tool tests
- `OraTests/Skills/SkillStoreTests.swift` — Modified: added 3 size validation tests
- `OraTests/Tools/ToolDiscoveryTests.swift` — Modified: added 3 discovery tests

## Code Review Findings

**Reviewed by:** Claude Code (orchestrator) — 2026-03-02
**Build:** ✅ | **Tests:** ✅ | **ACs covered:** 22/22

### Issues Found

**[P1-1] Missing `contentHash` in `skills.delete` auditPayload**
- Location: `Ora/Tools/Skills/SkillsDeleteTool.execute()` — the `auditPayload` dict does not include `contentHash`
- Both `SkillsCreateTool` and `SkillsUpdateTool` compute and include `contentHash` in their `auditPayload`
- Story AC-21 requires contentHash on all three audit events
- Fix: read skill content before deleting, compute SHA-256 hash via `SkillAuthoringToolSupport.contentHash(for:)`, include `"contentHash": .string(contentHash)` in the success `auditPayload`

**[P1-2] `SkillsDeleteTool` is missing `auditParameters()` override**
- Location: `Ora/Tools/Skills/SkillsDeleteTool.swift` — no `auditParameters()` implementation
- Both `SkillsCreateTool` and `SkillsUpdateTool` override `auditParameters()` to redact the `content` field
- Delete doesn't have a content field, but it should still override to redact nothing explicitly and maintain consistency with the other two tools
- Fix: add `func auditParameters(args: [String: JSONValue]) -> [String: JSONValue] { args }` or equivalent explicit override

**[P2-4] No write-time file size validation for `skills.create` / `skills.update`**
- Location: `Ora/Skills/SkillStore.swift` — `maxSkillFileBytes` (100KB) is only enforced in `readFile()`, not during `writeNewAgentSkill()` or the update write path
- A very large `content` argument could be written to disk and then silently fail to load (truncated at 5000 chars or rejected by `readFile()`)
- Fix: before writing in `writeNewAgentSkill()` and the update write path, check `sanitized.utf8.count <= maxSkillFileBytes`; throw `SkillError.contentTooLarge` (new error case) if exceeded

- [x] P1-1 fixed — `contentHash` added to delete auditPayload (reads content before deletion)
- [x] P1-2 fixed — explicit `auditParameters()` override added to `SkillsDeleteTool`
- [x] P2-4 fixed — `validateWritableContentSize()` added to both create and update write paths
- [x] Ready for merge (iteration 1)

**Round 2 — Codex automated review (PR #167)**

**[P1-A] Content trimming inconsistency in `skills.create`**
- `SkillAuthoringToolSupport.validateMutationArguments` trims content before frontmatter validation, but `authorizationPlan` and `execute` pass the original untrimmed string to `SkillFrontmatterParser`
- LLM-generated markdown commonly starts with a blank line, causing `SkillFrontmatterParser` to fail (requires `---` on the first line)
- Fix: trim the `content` string in `authorizationPlan` and `execute` before passing to `SkillFrontmatterParser`, or strip leading whitespace once in the sanitization step

**[P2-A] Orphaned skill directory on failed write**
- `writeNewAgentSkill()` creates the directory before writing `SKILL.md`; if the write throws (disk full, I/O error), the empty `<slug>/` folder is left behind
- Indexing skips it (no `SKILL.md`), but slug collision resolution will fail with "file exists" on the next create attempt with the same slug
- Fix: in the catch block after write failure, attempt `FileManager.default.removeItem(at: skillRoot)` to clean up the orphaned directory

- [ ] P1-A fixed
- [ ] P2-A fixed
- [ ] Ready for merge (iteration 2)

## Completion Status

(TBD after merge.)
