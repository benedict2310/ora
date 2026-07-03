# Architecture

This directory is the current architecture source of truth for Ora v2.

## Current architecture

- [Overview](overview.md) — v2 system boundaries, data flow, and component responsibilities.
- [Shape and migration plan](v2-shape-and-migration-plan.md) — target source layout, migration phases, test suite shape, and definition of done.

## Architecture decision records

- [ADR-0001: Adopt a subtractive v2 architecture reset](adrs/0001-adopt-subtractive-v2-architecture-reset.md)
- [ADR-0002: Use a core-only local assistant composition](adrs/0002-use-core-only-local-assistant-composition.md)
- [ADR-0003: Rebuild tests around high-signal contracts](adrs/0003-rebuild-tests-around-high-signal-contracts.md)

## Rules

- ADRs are append-only after acceptance. Supersede with a new ADR instead of rewriting history.
- Architecture overview files describe the current intended shape, not every legacy implementation detail.
- If implementation diverges from these docs, either update the architecture docs or create a new ADR explaining the divergence.
