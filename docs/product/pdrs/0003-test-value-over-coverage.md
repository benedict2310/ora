# PDR-0003: Prefer test value over coverage volume

- Status: Accepted
- Date: 2026-07-02
- Related: `docs/architecture/adrs/0003-rebuild-tests-around-high-signal-contracts.md`

## Context

The v1 test suite became slow and noisy as Ora expanded. The project previously emphasized high coverage, but the resulting suite mixed valuable contracts with brittle integration tests and tests for features that are no longer part of v2.

## Decision

Ora v2 will optimize tests for product confidence per minute, not coverage percentage.

The default PR gate should protect the core user promises:

- Ora understands and formats structured tool output correctly.
- Ora does not mutate user data without confirmation.
- Ora records mutations in an audit trail.
- Ora handles ASR-imperfect names and reminder text.
- Ora's core pipeline has predictable state transitions.
- Ora validates core tool arguments and reports errors clearly.

Coverage percentage is not a v2 product goal.

## User impact

Users benefit from faster iteration on the supported product and fewer regressions in the workflows that matter. They do not benefit from a large suite that slows development while protecting deprecated surfaces.

## Consequences

- Tests for deprecated product areas should be deleted or quarantined.
- Real model/audio/permission/UI tests should not be part of the default PR gate unless they are fast and deterministic.
- Contract tests are preferred over implementation-detail tests.
- A small number of high-value tests is better than broad low-signal coverage.

## Default gate target

The default test gate should aim for under 60 seconds on the development machine. If a test cannot reliably fit that gate, it needs a separate named command or should be removed.
