# Ora Skills Manifest

Skills are optional orchestration playbooks that guide the assistant through multi-step workflows.

## Folder format

Each skill must live in its own folder and include a `SKILL.md` file:

```text
Skills/
  your-skill-id/
    SKILL.md
    references/   # optional
    assets/       # optional
```

## Required `SKILL.md` frontmatter

Every `SKILL.md` must begin with YAML frontmatter:

```yaml
---
name: Human-readable Skill Name
description: One sentence describing what the skill does.
version: 1.0.0   # optional
---
```

Required keys:
- `name`
- `description`

## Discovery roots

Ora scans these locations at startup and when you click **Rescan Skills**:
- Bundled skills: app resource folder `Resources/Skills/`
- User skills: `~/Library/Application Support/Ora/Skills/`

## Safety rules

- Skills are guidance only; they do not execute code.
- Mutating tools still require explicit confirmation.
- `skills.read` can only read from `references/` and `assets/` within a skill folder.
