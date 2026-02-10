# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased] - 2026-02-10

### Added
- Added `./build.sh test-onboarding --keep-models` to reset onboarding state without deleting local model files.
- Added `FluidAudioStrategy` fallback progress estimation from on-disk Parakeet download growth when SDK progress callbacks are sparse.
- Added tests for FluidAudio progress mapping and estimated progress clamping in `OraTests/Models/FluidAudioStrategyTests.swift`.

### Changed
- Updated onboarding copy across Welcome, Permissions, Model Setup, Download, and Ready steps to better explain required permissions and model preparation behavior.
- Updated setup CTA copy from `Download Now` to `Prepare Models` and `Maybe Later` to `Skip for Now`.
- Updated README build command docs for the new onboarding test mode.

### Fixed
- Fixed Parakeet bootstrap/model path alignment with FluidAudio model cache directory.
- Improved model download coordination to avoid duplicate/concurrent download races.
- Improved setup download UX so pre-existing models are validated and reused correctly.
