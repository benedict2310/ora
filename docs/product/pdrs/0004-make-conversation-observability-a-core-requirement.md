# PDR-0004: Make conversation observability a core requirement

- Status: Accepted
- Date: 2026-07-04
- Related: `docs/architecture/v2-telemetry-and-debuggability-plan.md`

## Context

Ora v2 succeeds only if conversation behavior can be measured and debugged end to end. The most important regressions will happen at boundaries: input capture, ASR/STT, LLM structured output, action proposal/execution, TTS synthesis/playback, cancellation, and barge-in.

Without a shared telemetry contract, each phase can appear correct in isolation while the real product remains hard to diagnose. Developers should not need to guess whether latency came from audio capture, ASR warmup, LLM first-token delay, action execution, TTS synthesis, playback, or cancellation propagation.

macOS unified logging also redacts interpolated dynamic values by default. Ora needs debugging fields to be visible when they are not sensitive, while still protecting transcripts, contact data, calendar/reminder content, prompts, and raw tool payloads.

## Decision

Conversation observability is a v2 product requirement, not a later hardening task.

Every v2 feature phase must define telemetry acceptance criteria before implementation. Every TDD slice that changes user-flow behavior must include tests for telemetry event order, required fields, and privacy classification.

Ora v2 telemetry is local-first:

- no cloud analytics,
- no remote collection by default,
- no transcript, prompt, audio, contact, calendar, reminder, URL, or free-form user payload content in production logs,
- visible/public logging for non-sensitive debugging fields such as event names, sequence numbers, turn IDs, phase names, durations, counts, result categories, cancellation reasons, and action names.

## User impact

Users get a more reliable assistant because performance and flow regressions become measurable. Privacy is preserved because telemetry is designed around timings, states, counts, and categories instead of content.

Developers get enough visibility to answer “what happened in this turn?” without adding temporary print statements or exposing private user data.

## Consequences

- A telemetry spine must be implemented before the text-first assistant loop becomes the foundation for later phases.
- Each story/todo must include a telemetry acceptance section.
- Default tests should use deterministic in-memory telemetry sinks and test clocks, not live OSLog scraping.
- OSLog/Logger output must mark non-sensitive debug fields with public visibility so local debugging is useful.
- Sensitive fields must be omitted or explicitly private; user content must never become visible by default.
- MetricKit can be used later for app-level daily diagnostics, but it is not a substitute for per-turn local traces and signposts.

## Supersedes / superseded-by

- Supersedes: none.
- Superseded by: none.
