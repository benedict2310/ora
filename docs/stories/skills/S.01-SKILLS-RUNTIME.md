# S.01 - Skills Runtime

**Epic:** Skills
**Status:** Not Started
**Priority:** P1 (High)
**Estimated Effort:** 5 days
**Dependencies:** O.02 (Agent Loop), L.04 (System Prompt)
**Target:** macOS 26 (Tahoe)
**Design Reference:** [Anthropic Skills Standard](https://docs.anthropic.com/en/docs/agents-and-tools/skills)

---

## 1. Objective

Implement Skills as a first-class feature following the Anthropic Skills Standard, enabling Ora to discover, load, and use orchestration playbooks that guide the agent through complex workflows.

Skills are **not tools**. Tools remain the executable layer (calendar, reminders, contacts). Skills are optional orchestration instructions that tell the LLM how to combine tools for specific tasks (e.g., "Meeting Scheduler" guides through finding slots, drafting invites, creating events).

## 2. User Story

As a user, I want Ora to support optional skills that provide specialized workflows, so that I can say "use the meeting scheduler skill" and get guided assistance for complex multi-step tasks.

## 3. Scope

### In Scope

- Skill folder format validation (`SKILL.md` with YAML frontmatter)
- Skill discovery and indexing (bundled + user-installed)
- Tool-based integration: `skills.list`, `skills.load`, `skills.read`
- Progressive disclosure (metadata only in prompt, content loaded on demand)
- Voice-first activation ("use the X skill")
- Overlay UI showing available skills
- Skills preferences tab (enable/disable, list skills, rescan, open folder)
- System prompt adaptation for skills metadata block
- Audit logging of skill operations
- One bundled example skill (user will provide)
- Skills README/manifest for adding new skills

### Out of Scope

- Running skill scripts (`scripts/` folder execution) — see S.03
- Online marketplace / downloading skills — see S.04
- Embedding-based skill retrieval — see S.05
- Skills that create new tools (tools remain native)
- Skill version management / updates

## 4. Architecture Alignment

### Component Boundaries

```
┌─────────────────────────────────────────────────────────────┐
│                     Skills Layer                            │
├─────────────────────────────────────────────────────────────┤
│  SkillStore (actor)                                         │
│  ├── Discovery & Indexing                                   │
│  ├── Metadata parsing (YAML frontmatter only at startup)    │
│  └── Content loading (on demand via tools)                  │
├─────────────────────────────────────────────────────────────┤
│  Skills Tools                                               │
│  ├── SkillsListTool (read) — returns metadata array         │
│  ├── SkillsLoadTool (read) — returns full SKILL.md          │
│  └── SkillsReadTool (read) — reads references/assets files  │
├─────────────────────────────────────────────────────────────┤
│  Path Sandbox                                               │
│  └── Validates paths stay within skill root                 │
├─────────────────────────────────────────────────────────────┤
│  UI Integration                                             │
│  ├── OverlayView — shows available skills hint              │
│  └── SkillsPreferencesView — settings tab                   │
└─────────────────────────────────────────────────────────────┘
```

### Concurrency Model

- `SkillStore` is an `actor` for thread-safe index access
- Skill discovery runs at app startup (background task)
- Tool execution is async, integrates with existing `ToolHost`
- UI updates on `@MainActor`

### Guardrails & Safety

- Skills are untrusted text — they recommend tool usage but cannot bypass confirmation gates
- Mutating tools (`calendar.create_event`, etc.) still require explicit user confirmation
- `skills.read` is sandboxed to `references/` and `assets/` folders only
- Path traversal (`..`) is rejected

### Audit Logging

All skill operations are logged:
- `skill_list` — when skills are enumerated
- `skill_load` — when a skill's content is loaded (includes `skillId`)
- `skill_read` — when a reference/asset file is read (includes `skillId`, `path`)

### PRD/Architecture References

- Pipeline boundaries: Skills integrate at the LLM/Tools layer
- Streaming: Skills don't affect streaming (they're just instructions)
- Confirmation flow: Skills must respect existing O.04 patterns

## 5. Implementation Plan (Draft)

### 5.1 Files to Create

#### Skills Core (`Ora/Skills/`)

| File | Purpose |
|:-----|:--------|
| `SkillMetadata.swift` | `SkillMetadata` struct with id, name, description, source, rootURL, version |
| `SkillDocument.swift` | `SkillDocument` struct (metadata + markdown content) |
| `SkillError.swift` | `SkillError` enum (notFound, invalidFrontmatter, invalidPath) |
| `SkillFrontmatterParser.swift` | YAML frontmatter extraction and validation |
| `SkillPathSandbox.swift` | Path validation (references/assets prefix, no traversal) |
| `SkillStore.swift` | Actor managing skill index, discovery, loading |

#### Skills Tools (`Ora/Tools/Skills/`)

| File | Purpose |
|:-----|:--------|
| `SkillsListTool.swift` | Returns metadata array for all valid skills |
| `SkillsLoadTool.swift` | Loads full SKILL.md content by id |
| `SkillsReadTool.swift` | Reads file from references/ or assets/ |

#### UI (`Ora/Preferences/Tabs/`)

| File | Purpose |
|:-----|:--------|
| `SkillsPreferencesView.swift` | Skills settings tab |

#### Resources

| File | Purpose |
|:-----|:--------|
| `Ora/Resources/Skills/README.md` | Skills manifest and authoring guide |
| `Ora/Resources/Skills/example-skill/SKILL.md` | One bundled example skill |

### 5.2 Files to Modify

| File | Change |
|:-----|:-------|
| `Ora/Tools/ToolRegistry.swift` | Register skills tools |
| `Ora/LLM/SystemPromptBuilder.swift` | Add `{{available_skills}}` variable and rendering |
| `Ora/Resources/system-prompt.txt` | Add `{{available_skills}}` placeholder |
| `Ora/Persistence/AuditLogEntry.swift` | Add `skill_list`, `skill_load`, `skill_read` types |
| `Ora/Preferences/PreferencesWindow.swift` | Add Skills tab |
| `Ora/Overlay/OverlayView.swift` | Add skills hint text |
| `Ora/AppDelegate.swift` | Initialize SkillStore at startup |
| `project.yml` | Add Skills folder to sources |

### 5.3 Tests to Add

| File | Coverage |
|:-----|:---------|
| `OraTests/Skills/SkillFrontmatterParserTests.swift` | YAML parsing, validation, edge cases |
| `OraTests/Skills/SkillPathSandboxTests.swift` | Path validation, traversal rejection |
| `OraTests/Skills/SkillStoreTests.swift` | Discovery, indexing, loading |
| `OraTests/Skills/SkillsToolsTests.swift` | Tool execution, error handling |

### 5.4 Dependencies/Config

- `project.yml` — Add `Ora/Skills` source folder
- No new package dependencies (uses existing `Foundation` for YAML-like parsing)

## 6. Acceptance Criteria

### Discovery & Validation

- [ ] AC-1: App scans bundled (`Resources/Skills/`) and user (`~/Library/Application Support/Ora/Skills/`) roots at startup
- [ ] AC-2: Skills without `SKILL.md` or missing frontmatter `name`/`description` are ignored (logged as warning)
- [ ] AC-3: Startup indexing parses frontmatter only (no full SKILL.md content load)
- [ ] AC-4: Rescan button in preferences rebuilds the skill index

### Skills Tools

- [ ] AC-5: `skills.list` returns `[{id, name, description, source}]` for all valid skills
- [ ] AC-6: `skills.load` returns full SKILL.md markdown for a requested id
- [ ] AC-7: `skills.read` reads files from `references/` or `assets/` only
- [ ] AC-8: `skills.read` rejects paths with `..` or outside allowed prefixes

### Prompt Integration

- [ ] AC-9: System prompt includes available_skills XML metadata block each turn
- [ ] AC-10: Block contains only id, name, description (no full content)
- [ ] AC-11: Agent can call `skills.load` to get full instructions when needed

### Voice Activation

- [ ] AC-12: User can say "use the X skill" and the agent loads that skill
- [ ] AC-13: Overlay shows hint text: "Available skills: X, Y, Z — say 'use X skill' to activate"

### Settings UI

- [ ] AC-14: New "Skills" tab in Preferences window
- [ ] AC-15: Toggle to enable/disable skills feature
- [ ] AC-16: List showing installed skills (bundled/user, name, description)
- [ ] AC-17: "Rescan Skills" button to refresh index
- [ ] AC-18: "Open Skills Folder" button opens user skills directory in Finder

### Safety & Audit

- [ ] AC-19: Skill usage never bypasses confirmation gates for mutating tools
- [ ] AC-20: `skill_list`, `skill_load`, `skill_read` operations recorded in audit log
- [ ] AC-21: Audit entries include skillId, path (for read), timestamp

### Bundled Content

- [ ] AC-22: One example skill is bundled in `Resources/Skills/`
- [ ] AC-23: Skills README/manifest explains how to add new skills

## 7. Verification Plan

### Automated Tests

- [ ] Unit tests for YAML frontmatter parsing (valid, invalid, missing fields)
- [ ] Unit tests for path sandboxing (valid paths, traversal attempts, prefix enforcement)
- [ ] Unit tests for SkillStore (discovery, indexing, loading, error cases)
- [ ] Unit tests for skills tools (list, load, read with mocked store)
- [ ] Integration test: full flow from discovery to tool call

### Manual Tests

- [ ] Build app, verify skills are discovered at startup (check logs)
- [ ] Add a skill to user folder, rescan, verify it appears
- [ ] Say "use the example skill" and verify agent loads and follows it
- [ ] Test invalid skill folder (no SKILL.md) — should be ignored
- [ ] Test path traversal in skills.read — should fail
- [ ] Verify mutating tool still requires confirmation when used via skill
- [ ] Check Skills preferences tab renders correctly
- [ ] Verify audit log contains skill operations

## 8. Performance / Reliability Considerations

### Targets

| Metric | Target |
|:-------|:-------|
| Skill discovery (10 skills) | < 100ms |
| `skills.list` response | < 10ms |
| `skills.load` (avg SKILL.md) | < 50ms |
| Prompt metadata injection | negligible overhead |

### Failure Modes

| Failure | Handling |
|:--------|:---------|
| Invalid skill folder | Log warning, skip during indexing |
| Missing SKILL.md | Log warning, skip skill |
| Invalid frontmatter | Log warning, skip skill |
| Path traversal attempt | Return error from `skills.read` |
| Skill folder permissions | Log error, skip skill |

## 9. Risks & Mitigations

| Risk | Mitigation |
|:-----|:-----------|
| YAML parsing edge cases | Use simple key-value extraction from frontmatter, not full YAML parser |
| Large skill files slowing load | Enforce reasonable size limits (e.g., 100KB max for SKILL.md) |
| Skill instructions conflicting with tools | Document that skills are guidance only; tools have final authority |
| User confusion about skills vs tools | Clear UI labeling and documentation |

## 10. Open Questions

- ~~Where should manual activation UI live?~~ Voice-only, with overlay hint text
- ~~How detailed should the eval harness be?~~ Separate story (S.02)
- Should skills have a priority/ordering mechanism? (Defer to future)

---

## Implementation Details

### Data Structures

```swift
public struct SkillMetadata: Sendable, Codable, Hashable {
    public enum Source: String, Codable, Sendable { case bundled, user }

    public let id: String           // slug derived from folder name
    public let name: String         // from frontmatter
    public let description: String  // from frontmatter
    public let source: Source
    public let rootURL: URL
    public let version: String?     // optional from frontmatter
}

public struct SkillDocument: Sendable {
    public let meta: SkillMetadata
    public let markdown: String     // full SKILL.md content
}

public enum SkillError: Error {
    case notFound
    case invalidFrontmatter(String)
    case invalidPath(String)
    case fileTooLarge
}
```

### SkillStore Actor

```swift
public actor SkillStore {
    public struct Roots {
        public let bundled: URL   // Resources/Skills/
        public let user: URL      // ~/Library/Application Support/Ora/Skills/
    }

    private let roots: Roots
    private var index: [String: SkillMetadata] = [:]

    public func rebuildIndex() async { /* scan roots */ }
    public func list() -> [SkillMetadata] { /* return sorted */ }
    public func load(id: String) throws -> SkillDocument { /* read full SKILL.md */ }
    public func readFile(id: String, relativePath: String) throws -> Data { /* sandboxed read */ }
}
```

### Path Sandbox

```swift
public enum SkillPathSandbox {
    public static func resolve(root: URL, relativePath: String) throws -> URL {
        // 1. Validate prefix (references/ or assets/)
        // 2. Reject path traversal (..)
        // 3. Canonicalize and verify inside root
    }
}
```

### System Prompt Integration

Add to `system-prompt.txt`:

```
{{available_skills}}
```

Rendered as (XML block injected into prompt):

```xml
<available_skills>
  <skill id="meeting-scheduler" name="Meeting Scheduler">
    <description>Helps schedule meetings by finding slots and drafting invites.</description>
  </skill>
</available_skills>
```

### Activation Rule

Add to system prompt:
```
If you use a skill, you MUST call skills.load(id) first to get its full instructions before following its procedure.
```

---

## Implementation Summary

(TBD after implementation.)

## Code Review Findings

(TBD by review agent.)

## Completion Status

(TBD after merge.)
