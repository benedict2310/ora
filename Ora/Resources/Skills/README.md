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
    scripts/      # optional
      manifest.json   # optional
      helper.py
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
- `skills.run_script` can execute files from `scripts/` only.
- User-installed scripts are untrusted by default and require approval before execution.
- Trust is stored per skill and revoked automatically if a script hash changes.
- Script execution runs with a filtered environment and a 30s default timeout.

## Optional `scripts/manifest.json`

Scripts can declare metadata in `scripts/manifest.json`:

```json
{
  "scripts": {
    "helper.py": {
      "description": "Example helper",
      "arguments": [
        {"name": "input", "type": "string", "required": true}
      ],
      "output": "json",
      "timeout": 10,
      "capabilities": ["network"]
    }
  }
}
```

If no manifest is present, Ora uses defaults:
- output type: `text`
- timeout: `30` seconds
- per-run authorization still applies for user-installed skills
