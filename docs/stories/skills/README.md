# Skills Epic (S)

Optional orchestration playbooks that layer on top of Ora's native tools.

## Overview

Skills are **not tools**. Tools are the executable layer (calendar, reminders, contacts, system actions). Skills are orchestration instructions that tell the LLM how to combine tools for specific workflows (e.g., "Meeting Scheduler" skill guides the agent through finding slots, drafting invites, and creating events).

Skills follow the [Anthropic Skills Standard](https://docs.anthropic.com/en/docs/agents-and-tools/skills):
- `SKILL.md` with YAML frontmatter (name, description)
- Progressive disclosure (metadata in prompt, load content on demand)
- Optional `references/` and `assets/` folders
- Optional `scripts/` folder (see S.03)

## Stories

| ID | Title | Status | Priority |
|:---|:------|:-------|:---------|
| S.00 | [Context Budget](S.00-CONTEXT-BUDGET.md) | 🚧 Not Started | P0 |
| S.01 | [Skills Runtime](S.01-SKILLS-RUNTIME.md) | 🚧 Not Started | P1 |
| S.02 | [Skills Evaluation](S.02-SKILLS-EVALUATION.md) | 🚧 Not Started | P2 |
| S.03 | [Skill Scripts](S.03-SKILL-SCRIPTS.md) | 🚧 Not Started | P1 |
| S.04 | [Skills Marketplace](S.04-SKILLS-MARKETPLACE.md) | 📋 Distant Future | P3 |
| S.05 | [Agent Skill Authoring](S.05-AGENT-SKILL-AUTHORING.md) | 🚧 Not Started | P1 |

> **Embedding-based skill retrieval (removed):** At current skill counts, BM25/keyword ranking via the existing `Memory/HybridScorer.swift` is sufficient. Revisit if retrieval quality becomes a measurable problem at scale.
>
> **S.04 (Marketplace) vs S.05 (Agent Authoring):** S.05 covers the primary use case — personalized, locally-authored skills with no third-party trust concerns. S.04 is only worth pursuing if community skill sharing becomes a clear user demand.

## Dependencies

```
O.02 Agent Loop (✅ Complete)
         │
         ▼
    S.00 Context Budget (prerequisite)
         │
         ▼
    S.01 Skills Runtime ──────────────┐
         │                            │
         ├── S.02 Skills Evaluation   ├── S.05 Agent Skill Authoring
         │                            │
         └── S.03 Skill Scripts ◄─────┘ (BG.02 alignment is future refactor, not a hard dep)
              │
              └── S.04 Marketplace (distant future)
```

## Storage Locations

| Type | Path |
|:-----|:-----|
| Bundled skills | `Ora.app/Contents/Resources/Skills/<SkillName>/SKILL.md` |
| User skills | `~/Library/Application Support/Ora/Skills/<SkillName>/SKILL.md` |

## Key Design Decisions

1. **Tool-based integration**: Skills are accessed via `skills.list`, `skills.load`, `skills.read` tools
2. **Progressive disclosure**: Only skill metadata in system prompt; full content loaded on demand
3. **Path sandboxing**: `skills.read` restricted to `references/` and `assets/` folders
4. **Voice-first activation**: User says "use the meeting scheduler skill"; fuzzy matching (Jaro-Winkler) handles ASR errors
5. **Safety**: Skills never bypass confirmation gates for mutating tools
6. **Script execution via standalone actor**: Skill scripts (S.03) run via `SkillScriptWorker`, a standalone `actor` using `Foundation.Process`. It is intentionally NOT tied to `BackgroundWorker` (BG.02) now — that refactor happens later to gain XPC/Container isolation without changing call sites
7. **Agent authoring over marketplace**: Skills are created by Ora's own LLM on user request (S.05), avoiding third-party trust issues entirely. The marketplace (S.04) is only a distant-future concern.
8. **Source hierarchy**: `bundled` > `user` > `agent` — agent tools can only mutate `agent`-sourced skills
