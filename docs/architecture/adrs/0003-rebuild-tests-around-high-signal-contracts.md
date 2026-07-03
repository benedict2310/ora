# ADR-0003: Rebuild tests around high-signal contracts

- Status: Accepted
- Date: 2026-07-02
- Related: `docs/product/pdrs/0003-test-value-over-coverage.md`

## Context

The v1 test suite grew with the product surface. It mixed unit tests, integration tests, hardware/model tests, permission tests, timer/file-watcher tests, network/provider tests, and feature tests for subsystems that are outside the v2 product scope.

The result is a large, slow, noisy default gate that gives poor day-to-day signal. Coverage percentage became a goal in itself instead of a proxy for product confidence.

## Decision

Ora v2 will rebuild the default test suite around high-signal contracts. The default PR gate should be small, deterministic, and fast.

Default-gate tests should cover:

- structured output parsing and bounded retry behavior,
- tool argument validation,
- confirmation requirements for mutations,
- audit persistence contract for executed mutations,
- fuzzy lookup behavior for ASR-imperfect names/text,
- core pipeline state transitions,
- one happy path and one failure path per core tool family,
- prompt size/output-format contract.

The following tests should be opt-in, nightly, manual, or deleted with their feature:

- real ASR/TTS/model tests,
- audio hardware tests,
- permission prompt tests,
- disk persistence stress/performance tests,
- file watcher and timer tests,
- network/provider tests,
- UI/status-bar smoke tests,
- tests for memory, skills/scripts, research/background tasks, mail, messages, notes, vision, and broad automation.

## Consequences

- Default test runtime becomes a product velocity constraint, not an afterthought.
- The project stops treating high coverage as inherently valuable.
- Deleted features should not leave behind default-gate tests.
- A smaller suite requires stronger discipline around choosing durable contracts instead of implementation-detail tests.

## Target

The default gate should aim for under 60 seconds on the development machine, with a preference for much faster. Slower checks must be explicitly named and run separately.
