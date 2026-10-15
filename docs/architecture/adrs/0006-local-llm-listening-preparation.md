# ADR-0006: Local LLM preparation during voice listening

- Status: Accepted
- Date: 2026-10-15

## Decision

Accepted voice listening, voice follow-up, and voice re-enablement start a
nonblocking, best-effort local preparation. Text input does not start it. The
controller owns a cancellable speculative waiter, checks its captured turn before
launch, and makes no UI updates when it completes. Cancelling that waiter does
not cancel `LLMService`'s independent shared load. Foreground provider preflight
and preparation remain authoritative; an early failure does not abort ASR or
prevent a foreground retry.

`LLMService.prepare()` rechecks lifecycle, readiness, and the in-flight key after
awaiting the model source. Callers for the same model and lifecycle join one
physical load. Each flight also has a unique ID so a superseded failure cannot
clear a newer flight in the same lifecycle. Publication checks the lifecycle,
selected model, and flight ID after loading and after the model-source round
trip. The generation runtime owns its container: the complete bundle is published
atomically, with no separate stale container assignment.

`ModelManager` publishes `primaryLLM` and all existing LLM `isPrimary` metadata
flags together before awaiting invalidation. An older setter resuming after a
newer selection can save the current coherent state, but cannot rewrite its
primary flags. Selection tests use isolated metadata files and a controlled
invalidator; the test initializer defaults to no invalidation or persistence.

Unload and model selection invalidate synchronously before awaiting resource
retirement. Unready loads are not cancelled or awaited by invalidation; their
stale results are retired instead of published. Published runtime ownership is
transferred into retirement and released under the Metal gate, with no state
mutation after that gate hop. A prepare replacing an already-ready model checks
that only its own invalidation advanced the epoch before retrying; a concurrent
unload or provider switch cannot restart that obsolete request. Production loading and allocator configuration also
run under the gate. Existing physical-memory checks and the 512 MiB cache cap are
retained. Request-local KV ownership, producer joining, and generation cleanup
remain unchanged; no prefix reuse or token warmup is introduced.

`LLMProviderManager` owns speculative eligibility. Provider-transition suppression
prevents new speculative local requests during switching. Captured manager
epoch/eligibility is checked again from inside the service actor, whose own epoch
is captured before that callback. This covers an early request queued before a
switch but entering the service after unload. Provider selection, credential
resolution, publication ordering, and foreground cloud preflight are not moved
into the early path. Early preparation performs no credential lookup, cloud
preflight, model download, or generation.

## Consequences

Model loading can overlap ASR rather than beginning only after transcription.
Obsolete loads may finish in the background, but cannot publish readiness.
Preparation events expose safe flight/model IDs, categorical phases, and elapsed
milliseconds from an injectable monotonic system-uptime clock. Requested/joined
and early/foreground events distinguish shifted load cost from foreground wait;
no latency reduction is claimed without the separate live benchmark.

Controllable model-source, loader, eligibility-entry, and cleanup barriers test
real service/manager/controller behavior without model files or GPU operations.
Explicit test provider selection and persistence injection avoid application
preference writes and credential access. The controller test factory defaults
early preparation and agent-session lifecycle to no-ops and microphone status to
authorized; production defaults remain the real services. Tests opt into the
preparation route with controlled fakes and do not require microphone capture,
OS speech, or cloud access.
