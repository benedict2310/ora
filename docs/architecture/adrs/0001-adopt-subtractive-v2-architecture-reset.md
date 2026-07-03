# ADR-0001: Adopt a subtractive v2 architecture reset

- Status: Accepted
- Date: 2026-07-02
- Supersedes: legacy v1 story/report architecture in `docs/legacy/v1/`

## Context

Ora grew from a private voice assistant into a broad local-agent platform. The codebase now contains many feature families: memory, skills/scripts, background tasks, research, mail, messages, notes, cloud providers, vision, broad model management, and many system tools.

This breadth made the product harder to understand, maintain, test, and use. It also scattered product and architecture history across story files and reports instead of preserving explicit decision records.

## Decision

Ora v2 will use a subtractive architecture reset.

The current source of truth is now:

- `docs/architecture/` for current architecture overviews and indexes.
- `docs/architecture/adrs/` for architecture decisions.
- `docs/product/` for current product overviews and indexes.
- `docs/product/pdrs/` for product decisions.

Legacy documentation is archived under `docs/legacy/v1/` and is not current unless revived by a new ADR/PDR.

v2 implementation should remove, disable, or avoid reintroducing non-core subsystems unless a future ADR/PDR explicitly expands scope.

## Consequences

- The new architecture optimizes for clarity and maintainability over feature breadth.
- Existing code can be reused only when it fits the v2 boundaries.
- Legacy docs remain available for historical reference but no longer drive implementation.
- Future scope expansion requires an explicit decision record.

## Rejected alternatives

### Keep improving v1 incrementally

Rejected because the current architecture and docs already encode too many broad feature assumptions. Incremental cleanup would still leave unclear product boundaries.

### Rewrite everything from scratch

Rejected as too risky. Proven internals can be ported if they fit the v2 architecture.
