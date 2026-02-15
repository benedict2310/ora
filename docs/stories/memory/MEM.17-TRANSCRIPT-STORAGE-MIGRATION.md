# MEM.17 - Transcript Storage Migration

**Epic:** Memory System
**Status:** Not Started
**Priority:** P3 (Low / Future)
**Estimated Effort:** 2 days
**Dependencies:** MEM.01
**Target:** macOS 26 (Tahoe)
**Design Reference:** None

---

## 1. Objective

If message volume per session grows large, migrate from the current `messagesData` JSON blob to a proper SwiftData relationship model (`MessageModel @Model`). This improves query performance and enables per-message operations (search, delete, edit) without full-blob decode.

## 2. User Story

As a power user with long conversations, I want Ora to remain fast even with hundreds of messages per session.

## 3. Scope

### In Scope

- Create `MessageModel` as a SwiftData `@Model` with a relationship to `Session`
- Implement SwiftData migration from blob-based storage to relationship model
- Maintain backward compatibility: read old sessions from `messagesData`, write new sessions as relationships
- Provide migration path that runs on first launch after upgrade

### Out of Scope

- Changing the API surface (`Session.messages` should still work)
- Removing `messagesData` field (keep for backward compat during migration window)

## 4. Architecture Alignment

- **Component:** `Ora/Persistence/Models/Session.swift`, new `Ora/Persistence/Models/MessageModel.swift`
- **SwiftData migration:** Use `VersionedSchema` and `SchemaMigrationPlan` for safe schema evolution
- **Performance:** Relationship model enables lazy loading and per-message queries without decoding entire blob

## 5. Implementation Plan (Draft)

### 5.1 Files to Create

- `Ora/Persistence/Models/MessageModel.swift` — Per-message SwiftData model
- `Ora/Persistence/Migrations/` — Schema migration definitions

### 5.2 Files to Modify

- `Ora/Persistence/Models/Session.swift` — Add `@Relationship` to `[MessageModel]`, keep `messagesData` for migration
- `Ora/Persistence/PersistenceManager.swift` — Use relationship model for new writes

### 5.3 Tests to Add

- `OraTests/TranscriptMigrationTests.swift` — Test migration from blob to relationship
- Test backward compatibility (old sessions still readable)

### 5.4 Dependencies/Config

- SwiftData schema versioning in `project.yml` or model container configuration

## 6. Acceptance Criteria

- [ ] AC-1: New messages are stored as `MessageModel` relationships (not blob)
- [ ] AC-2: Old sessions with `messagesData` are readable and migratable
- [ ] AC-3: Migration runs automatically on first launch after upgrade
- [ ] AC-4: `Session.messages` API remains unchanged for consumers

## 7. Verification Plan

### Automated Tests

- [ ] Unit test: create session with old blob format, verify migration produces MessageModel instances
- [ ] Unit test: new writes use relationship model
- [ ] Unit test: `Session.messages` returns correct data from both storage formats

### Manual Tests

- [ ] Upgrade from pre-migration build, verify old conversations accessible

## 8. Performance / Reliability Considerations

- Migration should be non-blocking (background) for large databases
- Lazy loading of messages reduces memory for sessions with many messages

## 9. Risks & Mitigations

- **Risk:** SwiftData migration fails on corrupt data → **Mitigation:** Keep `messagesData` as fallback; migrate best-effort
- **Risk:** Dual storage increases complexity → **Mitigation:** Time-bound migration window; remove blob path after N releases

## 10. Open Questions

- What's the threshold message count where blob storage becomes a bottleneck? (MEM.05 instrumentation will answer)

---

## Implementation Summary

(TBD after implementation.)

## Code Review Findings

(TBD by review agent.)

## Completion Status

(TBD after merge.)
