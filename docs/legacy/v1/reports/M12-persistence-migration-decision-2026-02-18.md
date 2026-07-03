# M.12 Persistence Migration Decision (2026-02-18)

## Scope
Story: `M.12 - Architectural Improvements (Phase 2 & 3)`

## Decision
Selected **Option B: Remove Dead Code**.

## Why
- Current production behavior stores conversation messages in `Session.messagesData` (JSON blob).
- Relationship-based `MessageModel` storage was not wired into active write/read paths.
- Keeping partial migration paths increased maintenance and recovery complexity without providing active user value.

## Implementation
- Removed `MessageModel` from the codebase.
- Removed `migrateSessionsToRelationshipStorage()` and related migration-only paths from `PersistenceManager`.
- Simplified `Session` to blob-only message persistence.
- Updated persistence tests to validate blob-path behavior.

## Validation
- `./build.sh` passed.
- `./build.sh test` passed (`1411/1411`).

## Follow-up
If relationship-level querying becomes a product requirement, reintroduce it as a fully wired migration with explicit rollout and backfill testing.
