# PDR-0001: Ora v2 product scope

- Status: Accepted
- Date: 2026-07-02
- Supersedes: legacy v1 PRD in `docs/legacy/v1/stories/PRD.md`

## Context

Ora's v1 direction emphasized privacy-first local assistance and fast, reliable, auditable actions. Over time, the product expanded into memory, skills/scripts, background tasks, mail, messages, notes, research, cloud providers, vision, and broad Mac automation.

That expansion made the app feel less maintainable and less usable. v2 needs a smaller product promise that can be made excellent.

## Decision

Ora v2 is a private, local-first macOS voice assistant for fast personal productivity actions.

The v2 core product supports only:

1. push-to-talk voice interaction with compact overlay feedback,
2. local ASR/LLM/TTS path,
3. calendar schedule/query/find/create/update/delete,
4. reminders list/create/update/complete/delete,
5. contacts lookup and invitee resolution,
6. minimal system actions: open app, open URL/search, open settings,
7. permission recovery,
8. local audit history for mutations.

## User impact

Users should experience Ora as narrower but more dependable. The assistant should be easier to explain, faster to use, and less surprising.

## Consequences

- Calendar becomes the flagship workflow.
- Reminders and contacts support the same productivity loop.
- Product decisions should be evaluated by whether they improve this narrow promise.
- Features outside this scope are removed, disabled, or treated as future experiments.

## Success measures

- A supported request reliably produces an understandable response/proposal.
- Mutations are never executed without confirmation.
- Unsupported requests fail clearly.
- The visible product surface fits in a small preferences/UI model.
- Core interactions feel faster because the prompt and tool surface are smaller.
