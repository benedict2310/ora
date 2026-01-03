# Skills Epic (S)

Optional orchestration playbooks that layer on top of Ora's native tools.

## Overview

Skills are **not tools**. Tools are the executable layer (calendar, reminders, contacts, system actions). Skills are orchestration instructions that tell the LLM how to combine tools for specific workflows (e.g., "Meeting Scheduler" skill guides the agent through finding slots, drafting invites, and creating events).

Skills follow the [Anthropic Skills Standard](https://docs.anthropic.com/en/docs/agents-and-tools/skills):
- `SKILL.md` with YAML frontmatter (name, description)
- Progressive disclosure (metadata in prompt, load content on demand)
- Optional `references/` and `assets/` folders
- Optional `scripts/` folder (future)

## Stories

| ID | Title | Status |
|:---|:------|:-------|
| S.01 | [Skills Runtime](S.01-SKILLS-RUNTIME.md) | 🚧 Not Started |
| S.02 | [Skills Evaluation](S.02-SKILLS-EVALUATION.md) | 🚧 Not Started |
| S.03 | [Skill Scripts](S.03-SKILL-SCRIPTS.md) | 📋 Future |
| S.04 | [Skills Marketplace](S.04-SKILLS-MARKETPLACE.md) | 📋 Future |
| S.05 | [Embedding Retrieval](S.05-EMBEDDING-RETRIEVAL.md) | 📋 Future |

## Dependencies

```
O.02 Agent Loop (✅ Complete)
         │
         ▼
    S.01 Skills Runtime ──────┐
         │                    │
         ▼                    ▼
    S.02 Skills Evaluation   S.03 Skill Scripts
                              │
                              ▼
                         S.04 Marketplace
                              │
                              ▼
                         S.05 Embedding Retrieval
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
4. **Voice-first activation**: User says "use the meeting scheduler skill"
5. **Safety**: Skills never bypass confirmation gates for mutating tools
