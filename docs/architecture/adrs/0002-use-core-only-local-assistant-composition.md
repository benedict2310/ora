# ADR-0002: Use a core-only local assistant composition

- Status: Accepted
- Date: 2026-07-02
- Related: `docs/product/pdrs/0001-ora-v2-product-scope.md`

## Context

Ora's most valuable and defensible product promise is a private, predictable macOS assistant that performs a few personal productivity actions reliably. The existing architecture exposes too many tool domains and preferences, which increases prompt size, app surface area, test burden, and maintenance cost.

## Decision

Ora v2 will compose the app around one core local assistant path:

```text
Activation UI → Audio/Text Input → Assistant Session → Local LLM → Tool Host → Confirmation/Audit → Overlay/TTS
```

The default tool surface is limited to:

- Calendar tools.
- Reminder tools.
- Contacts search.
- Minimal system actions: open app, open URL/search, open settings.

The default provider surface is local-only. Cloud provider abstractions, skills, scripts, memory, research/background tasks, mail, messages, notes, vision, broad file search, and broad system automation are out of the v2 core composition.

## Consequences

- Prompt construction can be much smaller and more deterministic.
- Feature ownership becomes clearer: each supported use case maps to one core tool family.
- Preferences can shrink to permissions, hotkey/private mode, model status, and audit/history.
- Removed feature families should also be removed from default tests and prompt/tool registration.

## Rejected alternatives

### Plugin-first architecture

Rejected for v2. Plugin boundaries may be useful later, but making extensibility the foundation would recreate the platform complexity that v2 is meant to escape.

### Keep all tools but hide them in UI

Rejected because hidden tools still affect prompt size, tests, security review, and maintenance.
