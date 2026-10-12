# ADR-0004: Track the validated package resolution

- Status: Accepted
- Date: 2026-10-12
- Related: [ADR-0003](0003-rebuild-tests-around-high-signal-contracts.md), [Contributor guide](../../../CONTRIBUTING.md#dependency-resolution)

## Context

An unlocked fresh Release build under Xcode 26.0.1 selected swift-distributed-tracing 1.6.0, whose added `ServiceContext` alias makes AsyncHTTPClient's unqualified `ServiceContext.current` ambiguous. AsyncHTTPClient 1.35.0 and 1.36.2 contain the same reference, so pinning that package alone is insufficient. The owner approved preserving the complete previously validated graph, including AsyncHTTPClient 1.35.0, swift-distributed-tracing 1.4.1, and containerization 0.37.0, without upgrades or upstream patches.

## Decision

- Track the complete root `Package.resolved`; keep generated and nested locks ignored.
- After XcodeGen, copy that required lock into `Ora.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`, including when the project already exists.
- Local build, test, signing-build, and CI resolution/build commands use `-onlyUsePackageVersionsFromResolvedFile`. Missing or incompatible resolution fails; no automatic fallback to another graph.
- Intentional graph refreshes require owner approval, review of all changed pins, an updated snapshot checksum contract, and a fresh Release build plus core tests before committing the full snapshot with relevant manifest changes.

## Consequences

Builds use reviewed versions and revisions rather than silently drifting with remote releases or depending on a developer's cached graph. The lock is an input, not proof that a graph compiles: fresh resolution and compilation remain required. Deliberate refreshes are explicit work instead of incidental build side effects.

Dependency reproducibility does not imply toolchain parity. Hosted CI retains Xcode 26.2; the trusted local route uses existing Xcode at least 26.0.1. This decision does not change package manifests, app behavior, or runner isolation.
