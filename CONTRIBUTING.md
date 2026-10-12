Note: By submitting a contribution to this repository, you agree that
your contribution is licensed under the same source-available terms as this
project, and that Benedict Evert / Futurelab Studio retains full rights to
use, relicense, and commercialize your contribution.

# Contributing to Ora

> **Note:** By submitting a contribution to this repository, you agree that your contribution is made under the same source-available license as this project, and that Futurelab Studio retains full rights to use, license, and commercialize your contribution.

Thank you for your interest in contributing to Ora! This document provides guidelines for contributing to the project.

## Code of Conduct

Be respectful, constructive, and collaborative. We're all here to build something awesome together.

## How to Contribute

### Reporting Bugs

1. Check if the bug has already been reported in [Issues](https://github.com/benedict2310/ora/issues)
2. If not, create a new issue with:
   - Clear title and description
   - Steps to reproduce
   - Expected vs actual behavior
   - macOS version, chip type, and RAM
   - Relevant logs (use `./build.sh logs`)

### Suggesting Features

1. Open an issue with the `enhancement` label
2. Describe the feature and its use case
3. Explain how it aligns with Ora's privacy-first philosophy

### Pull Requests

Follow the standard GitHub flow: fork, branch, commit, push, PR.

## Development Setup

See [README.md](README.md#for-developers) for build instructions.

### Dependency Resolution

The root [`Package.resolved`](Package.resolved) records the complete reviewed dependency graph. Local builds, all test modes, signing builds, and CI copy it into the generated Xcode workspace and use `-onlyUsePackageVersionsFromResolvedFile`; a missing or incompatible lock fails rather than silently refreshing versions. Generated project locks remain ignored. See [ADR-0004](docs/architecture/adrs/0004-track-validated-package-resolution.md).

For an owner-approved graph refresh, regenerate the project and explicitly resolve packages without the locked-version flag, then copy `Ora.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved` back to the root. Review every changed version/revision and update the snapshot checksum contract in `BuildScriptTests.swift`. Run `./build.sh` and `./build.sh test` in a fresh worktree before committing the complete lock with any relevant manifest changes. Do not rely on a preexisting build cache or patch upstream checkouts.

### Optional Local CI

Hosted GitHub Actions remains the default. A trusted repository owner may opt one same-repository pull request into the ephemeral local `Build & Test` runner by temporarily setting `ORA_LOCAL_CI_PR` to its exact decimal PR number (for example, `211`, not `0211`). The workflow requires the `pull_request` event, the PR head repository to equal `benedict2310/ora`, and a formatted PR-number match; forks, pushes, empty values, and other PRs stay hosted. Labels are `self-hosted`, `macOS`, `ARM64`, and `ora-local-ci`.

The runner executes as the current developer user: ephemeral is not an OS sandbox. Before registration, require approval for `all_external_contributors`, inspect queued/running jobs, and never approve untrusted or public-fork code while the runner exists; PR-modified workflows can bypass source guards. Only the reviewed owner PR may execute. Keep that approval policy until the runner is stopped and unregistered, then remove `ORA_LOCAL_CI_PR` (or restore its previous value) and restore the prior approval policy. Do not install a service or leave a runner registered.

Local CI requires existing `xcodegen` and Xcode at least 26.0.1, used through `DEVELOPER_DIR` without global selection or installation. Hosted CI retains Xcode 26.2; the routes are intentionally non-parity even with the same locked dependency graph.

## License

By contributing, you agree that your contribution is licensed under the same source-available terms as this project, and that Benedict Evert / Futurelab Studio retains full rights to use, relicense, and commercialize your contribution.
