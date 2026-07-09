# Ora v2 Telemetry and Debuggability Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `subagent-driven-development` for implementation. Every task below must be executed with red/green TDD and must include telemetry acceptance criteria in the worker prompt.

**Goal:** Make every Ora v2 conversation turn measurable end to end without logging private user content.

**Architecture:** Add a small, local-first telemetry spine before the text-first assistant loop. Use deterministic in-memory telemetry for tests, unified logging for live debugging, and signposts for interval timing in Instruments. Treat telemetry event order, durations, and privacy classification as product contracts.

**Tech Stack:** Swift 6, `OS.Logger`, `OS.OSSignposter`, optional future MetricKit diagnostics, deterministic test clocks, in-memory test sinks, existing `./build.sh logs` helpers.

---

## 1. Apple platform guidance

Apple's OS framework gives Ora the right primitives:

- `Logger` writes structured messages to the unified logging system. Apple documents that interpolated strings and custom objects are redacted by default; non-sensitive values must be marked public when local debugging requires visibility.
- `OSSignposter` records points of interest and intervals using the same subsystem/category model as unified logging. Instruments can render signpost intervals on a timeline.
- MetricKit can provide app-level daily reports and immediate diagnostics on macOS, including signpost/custom metrics, crashes, hangs, CPU, memory, GPU, and disk metrics. MetricKit is useful later, but it does not replace per-turn local traces because it is delayed and aggregate-oriented.

Ora v2 should therefore combine:

1. **Typed telemetry events** for tests and deterministic trace reconstruction.
2. **Unified logs** for day-to-day local debugging.
3. **Signpost intervals** for timeline and performance work in Instruments.
4. **Optional MetricKit ingestion later** for app-level health, not conversation control flow.

## 2. Non-negotiable telemetry principles

1. **Local-first only:** no cloud analytics and no remote export by default.
2. **Debuggable by default:** non-sensitive fields must be visible in logs, not hidden as `<private>`.
3. **Private by design:** transcript text, prompts, raw model output, audio samples, contact fields, calendar/reminder titles/details, URLs/search queries, and raw tool payloads are omitted or private by default.
4. **Every turn has a correlation ID:** every event in a conversation turn includes `turnID` and monotonically increasing `sequence`.
5. **Every interval has a start/end/failure/cancel path:** spans must close even when the turn is interrupted or errors.
6. **Telemetry is testable without OSLog:** default tests use an in-memory sink and test clock.
7. **Telemetry is part of acceptance criteria:** no v2 feature is done unless its observable behavior is specified and tested.

## 3. Required event model

Create a small typed model before Phase 2 production flow work:

```swift
struct TelemetryEvent: Equatable, Sendable {
    let name: TelemetryEventName
    let turnID: TurnID?
    let sequence: Int
    let time: TelemetryTime
    let level: TelemetryLevel
    let fields: [TelemetryField]
}

enum TelemetryVisibility: Equatable, Sendable {
    case publicDebug
    case privateSensitive
    case omitted
}

struct TelemetryField: Equatable, Sendable {
    let key: String
    let value: TelemetryValue
    let visibility: TelemetryVisibility
}
```

The implementation can adjust exact names, but it must preserve these semantics:

- event name is typed or centrally registered,
- fields carry privacy classification,
- tests can assert public vs private/omitted fields,
- OSLog rendering uses `.public` only for `publicDebug` fields.

## 4. Core event vocabulary

### Turn and input

- `turn.started`
- `turn.completed`
- `turn.failed`
- `turn.cancelled`
- `input.text.received`
- `input.ptt.pressed`
- `input.ptt.released`
- `input.ptt.cancelled`

### Audio capture and ASR/STT

- `audio.capture.started`
- `audio.capture.stopped`
- `audio.preroll.buffered`
- `asr.prepare.started`
- `asr.prepare.completed`
- `asr.prepare.failed`
- `asr.streaming.started`
- `asr.partial.received`
- `asr.final.received`
- `asr.streaming.failed`

### LLM and structured output

- `llm.request.started`
- `llm.first_token.received`
- `llm.output.completed`
- `llm.output.cancelled`
- `llm.output.failed`
- `structured_output.parsed`
- `structured_output.rejected`
- `structured_output.retry_scheduled`

### Actions, proposals, and audit

- `action.lookup.started`
- `action.lookup.failed`
- `action.proposal.created`
- `action.proposal.approved`
- `action.proposal.rejected`
- `action.execution.started`
- `action.execution.completed`
- `action.execution.failed`
- `audit.entry.recorded`

### TTS, playback, and barge-in

- `tts.synthesis.started`
- `tts.first_audio.ready`
- `tts.synthesis.completed`
- `tts.synthesis.failed`
- `tts.playback.started`
- `tts.playback.completed`
- `tts.playback.stopped`
- `barge.monitoring.started`
- `barge.detected`
- `barge.confirmed`
- `barge.rejected`
- `barge.cancelled_turn`

### Permissions and recovery

- `permission.status.checked`
- `permission.request.started`
- `permission.request.completed`
- `permission.recovery.opened`

## 5. Public vs private field policy

### Public/debug-visible fields

These fields should be visible in local logs when present:

- `turnID`, `sessionID`, `sequence`, `spanID`, `parentSpanID`
- event name, phase, source, state, transition name
- duration in milliseconds, queue/wait time, first-token latency, first-audio latency
- sample rate, frame count, buffer duration, chunk count, audio route category
- token count, prompt character count, output character count, retry count
- action domain, action name, action kind, confirmation required/approved booleans
- permission type, status category, recovery action category
- result category, error category, cancellation reason
- model family/name when it is not user-provided secret material

### Private or omitted fields

These fields must not be visible by default:

- transcript text and partial/final ASR text,
- raw audio samples or file paths to captured audio,
- prompts, raw model output, tool JSON payloads,
- contact names, emails, phone numbers, addresses,
- calendar titles, notes, locations, attendees,
- reminder titles, notes, list names when user-created,
- URLs, search queries, document names, clipboard contents,
- stack traces that contain user paths unless explicitly sanitized.

For sensitive content, prefer omission over private logging. Private logging still records the shape of the message and can tempt future debugging to reveal it; omission is safer.

## 6. Required test pattern

Every v2 TDD slice that changes conversation behavior must include at least one telemetry assertion.

Use this pattern:

1. Arrange a `TestTelemetrySink` and `TestClock`.
2. Run the smallest behavior under test.
3. Assert the exact event names in order.
4. Assert required public fields are present and classified `publicDebug`.
5. Assert sensitive fields are absent or classified `privateSensitive`/`omitted`.
6. Assert interval start/end/failure/cancel balance when the slice creates a span.

Example contract:

```swift
XCTAssertEqual(
    sink.events.map(\.name),
    [.turnStarted, .inputTextReceived, .actionProposalCreated, .turnCompleted]
)

XCTAssertTrue(sink.event(.inputTextReceived).hasPublicField("characterCount"))
XCTAssertFalse(sink.event(.inputTextReceived).hasField("text"))
```

Default tests must not scrape `log show`, wait on real timers, load models, use microphone/speaker hardware, or depend on permission prompts.

## 7. Phase integration

### Phase 1.5: Telemetry spine before Phase 2

Add this phase between v2 contracts and the text-first assistant loop.

Outputs:

- `Ora/Telemetry/TelemetryEvent.swift`
- `Ora/Telemetry/TelemetryRecorder.swift`
- `Ora/Telemetry/TelemetrySink.swift`
- `Ora/Telemetry/TelemetryClock.swift`
- `Ora/Telemetry/OSTelemetrySink.swift`
- `OraCoreTests/Telemetry/TelemetryRecorderTests.swift`
- `OraCoreTests/Telemetry/TelemetryPrivacyTests.swift`

Default tests:

- records events with deterministic sequence numbers,
- records spans with start/end/failure/cancel balance,
- renders public debug fields visibly and keeps sensitive fields private/omitted,
- supports one turn ID shared across events,
- does not require OSLog, microphone, model loading, or sleeps.

Commit:

```bash
git add Ora/Telemetry OraCoreTests/Telemetry project.yml
git commit -m "feat: add v2 telemetry spine"
```

### Phase 2 and later

Every phase must add a `Telemetry acceptance` section to its execution plan and worker prompt.

Minimum requirements by phase:

- **Phase 2 text loop:** turn/input/action/proposal/result/completion events in order.
- **Phase 3 actions:** action execution spans, permission categories, audit correlation IDs.
- **Phase 4 prompt/output:** prompt/output sizes, token counts, first-token latency, parser retry/rejection events; no prompt/output content.
- **Phase 5 UI:** overlay state transition events and user confirmation/rejection events.
- **Phase 6 voice:** audio capture, ASR preparation/partial/final, LLM, TTS synthesis/playback, cancellation, and barge-in events in one trace.
- **Phase 7 legacy cleanup:** tests proving deprecated subsystems no longer emit default v2 telemetry.
- **Phase 8 stabilization:** manual scenarios include trace review using `./build.sh logs --category telemetry` and Instruments signposts.

## 8. Definition of done for telemetry

Telemetry is real when all of these are true:

- every v2 turn has a reconstructable local timeline,
- logs expose non-sensitive event names, IDs, timings, counts, categories, and reasons as visible public fields,
- sensitive content is absent/private by contract tests,
- every major stage has duration spans,
- cancellation and barge-in leave balanced traces,
- default tests assert event order and privacy without OSLog scraping,
- manual verification can answer “where did this turn spend time?” from logs/signposts.
