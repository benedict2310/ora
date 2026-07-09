# Ora v2 Shape and Migration Plan

> **For agentic workers:** Use this as the north-star plan for implementation. Before coding each phase, create a small TDD execution plan with failing tests, implementation steps, verification commands, and a scoped commit.

**Goal:** Reshape Ora into a concise local-first macOS voice assistant focused on calendar, reminders, contacts, and minimal safe system actions.

**Architecture:** Use a subtractive migration: introduce a small v2 composition inside the existing app, port only the proven pieces that fit, make the default tests fast and high-signal, then remove deprecated subsystems. Keep the app buildable after every phase.

**Tech Stack:** Swift 6, AppKit/SwiftUI, AVFoundation, EventKit, Contacts, SwiftData or a smaller local audit store, MLX Swift, FluidAudio Parakeet, Kokoro TTS, OSLog `Logger`, `OSSignposter`, optional future MetricKit diagnostics.

---

## 1. Target product shape

Ora v2 has one clear path:

```text
Hotkey or text input
    ↓
Transcript / user request
    ↓
Compact assistant session
    ↓
Local LLM structured output
    ↓
Core action host
    ↓
Read result or confirmation proposal
    ↓
Confirmed mutation execution
    ↓
Overlay answer + optional TTS + audit record
```

The default app should expose only:

- push-to-talk and optional text input,
- compact overlay,
- local model path,
- calendar actions,
- reminder actions,
- contacts lookup,
- minimal system actions,
- permission recovery,
- audit/history for mutations,
- small preferences surface.

Everything else is legacy unless a future PDR/ADR revives it.

## 2. Target source layout

The final code should be easy to navigate by product responsibility, not by historical feature growth.

```text
Ora/
  App/
    OraAppDelegate.swift
    OraCompositionRoot.swift
    OraFeatureSet.swift

  Interaction/
    AssistantSession.swift
    AssistantTurn.swift
    AssistantEvent.swift
    AssistantState.swift
    VoiceLoop.swift
    TextInputLoop.swift

  Telemetry/
    TelemetryEvent.swift
    TelemetryRecorder.swift
    TelemetrySink.swift
    TelemetryClock.swift
    OSTelemetrySink.swift

  ModelRuntime/
    LocalASRClient.swift
    LocalLLMClient.swift
    LocalTTSClient.swift
    StructuredOutputGenerator.swift
    SystemPromptBuilder.swift

  Actions/
    Action.swift
    ActionHost.swift
    ActionProposal.swift
    ActionResult.swift
    ActionAuditRecorder.swift
    Calendar/
    Reminders/
    Contacts/
    System/

  UI/
    Overlay/
    Preferences/
    Confirmation/

  Data/
    AuditStore.swift
    SettingsStore.swift
    SessionLog.swift

  Permissions/
    PermissionCenter.swift
    PermissionStatus.swift

  Legacy/
    README.md
```

### Layout rules

- New v2 code goes into the target folders above.
- Existing proven code can be moved or wrapped into the target folders only when it fits the new boundary.
- Deprecated code should not receive new dependencies from v2 code.
- A temporary `Ora/Legacy/` folder is acceptable during migration, but the end state should delete it.

## 3. Core module responsibilities

### `App/`

Owns app startup and dependency composition.

Responsibilities:

- construct one default `OraFeatureSet`,
- initialize local model clients,
- initialize core action adapters,
- initialize overlay/preferences/status bar,
- register only v2 actions,
- avoid direct feature logic in app delegate.

Acceptance:

- app startup has one composition root,
- deprecated subsystems are not initialized by default,
- default feature list fits on one screen.

### `Interaction/`

Owns user turns and state transitions.

Responsibilities:

- turn lifecycle: idle → listening/text input → transcribing → thinking → proposal/result → done/error,
- cancellation and interruption,
- bounded structured-output retry,
- no direct EventKit/Contacts calls.

Acceptance:

- one pure state-machine test covers supported transitions,
- one happy-path assistant turn test uses fake model and fake action host,
- one failure-path test shows permission or validation failure clearly.

### `ModelRuntime/`

Owns local inference adapters and prompt construction.

Responsibilities:

- ASR transcript production,
- local LLM structured output,
- optional TTS response generation,
- compact v2 prompt built from the core action catalog,
- no cloud provider selection.

Acceptance:

- prompt includes only v2 capabilities,
- prompt size is tracked by a fast contract test,
- structured output test rejects unsupported/deprecated tool names.

### `Actions/`

Owns all user data reads/mutations and safety policy.

Responsibilities:

- validate action arguments,
- normalize ASR-imperfect user strings,
- enforce confirmation for mutations,
- call EventKit/Contacts/system APIs through adapters,
- produce bounded user-visible summaries,
- record mutation audit entries.

Core action families:

- `Calendar`: query schedule, find slots, create, update, delete.
- `Reminders`: list, create, update, complete, delete.
- `Contacts`: fuzzy search, resolve invitees.
- `System`: open app, open URL/search, open settings.

Acceptance:

- no mutation action can execute without an approved proposal,
- unsupported action names fail validation,
- fuzzy contact/reminder matching is tested with ASR-like misspellings.

### `UI/`

Owns presentation only.

Responsibilities:

- compact overlay,
- confirmation UI,
- minimal preferences,
- permission recovery affordances,
- audit/history view.

Default preferences:

- General: hotkey, private mode / voice output.
- Permissions: microphone, calendar, reminders, contacts, accessibility if still needed.
- Models: local model status and recovery.
- Audit: mutation history.

Acceptance:

- no UI path exposes deprecated platform features,
- proposal UI clearly shows action, target, time/date, and consequences,
- settings remain small enough to scan quickly.

### `Data/`

Owns local records needed by v2.

Responsibilities:

- mutation audit entries,
- lightweight settings,
- optional session transcript log for recent UI continuity.

Non-responsibilities:

- semantic long-term memory,
- embedding retrieval,
- memory distillation,
- background summarization.

Acceptance:

- audit entries answer “what changed, when, why, and whether the user confirmed,”
- session logging does not become retrieval memory.

### `Telemetry/`

Owns local-first observability for the conversation loop.

Responsibilities:

- emit typed events with turn IDs, sequence numbers, timestamps, durations, and privacy-classified fields,
- write deterministic in-memory traces for tests,
- write non-sensitive debug fields visibly to unified logs,
- create signpost intervals for performance work in Instruments,
- correlate input, ASR/STT, LLM, actions, TTS, playback, cancellation, and barge-in events.

Non-responsibilities:

- cloud analytics,
- remote collection,
- logging transcript, prompt, audio, contact, calendar, reminder, URL, or raw tool payload content by default.

Acceptance:

- every v2 behavior story defines telemetry acceptance criteria,
- default tests assert event order and privacy classification without OSLog scraping,
- non-sensitive fields such as IDs, phases, durations, counts, action names, categories, and reasons are public/visible in local logs,
- sensitive content is omitted or private by contract.

See `docs/architecture/v2-telemetry-and-debuggability-plan.md` and `docs/product/pdrs/0004-make-conversation-observability-a-core-requirement.md`.

## 4. Legacy cut list

The following directories are deprecated from the default product and should be deleted, archived, or unreachable by default during the migration:

```text
Ora/BackgroundTasks/
Ora/Cloud/
Ora/Memory/
Ora/Skills/
Ora/Tools/Mail/
Ora/Tools/Messages/
Ora/Tools/Notes/
Ora/Tools/Research/
Ora/Tools/Skills/
Ora/UI/TaskProgress/
Ora/Resources/Skills/
OraTests/BackgroundTasks/
OraTests/Cloud/
OraTests/Memory/
OraTests/Skills/
OraTests/Tools/Mail/
OraTests/Tools/Messages/
OraTests/Tools/Notes/
OraTests/Tools/Research/
```

The following areas may be ported selectively:

```text
Ora/ASR/
Ora/Audio/
Ora/Hotkey/
Ora/LLM/
Ora/Overlay/
Ora/Permissions/
Ora/Persistence/
Ora/Setup/
Ora/Tools/Calendar/
Ora/Tools/Contacts/
Ora/Tools/Reminders/
Ora/Tools/System/
Ora/TTS/
Ora/UI/Components/
Ora/Utilities/
```

## 5. Migration phases

### Phase 0: Documentation reset

Status: complete in this branch.

Outputs:

- `docs/product/overview.md`
- `docs/product/pdrs/`
- `docs/architecture/overview.md`
- `docs/architecture/adrs/`
- `docs/legacy/v1/`

### Phase 1: Define the v2 contracts and test gate

Goal: create the skeleton that future work must satisfy before moving production behavior.

Tasks:

1. Add `Ora/App/OraFeatureSet.swift` with a single default core feature set.
2. Add `Ora/Actions/Action.swift`, `ActionProposal.swift`, `ActionResult.swift`, and `ActionHost.swift` protocols/types.
3. Add `Ora/Interaction/AssistantState.swift` and state transition rules.
4. Add a new fast test target or fast test subset for v2 contracts.
5. Update `./build.sh test` to run the fast v2 gate by default.

Default tests:

- feature set contains only calendar, reminders, contacts, minimal system actions,
- mutation actions require proposals,
- state machine transitions are deterministic,
- deprecated action names are rejected.

Commit:

```bash
git add project.yml build.sh Ora/App Ora/Actions Ora/Interaction OraCoreTests
git commit -m "test: add v2 core contracts"
```

### Phase 1.5: Establish the v2 telemetry spine

Goal: make observability part of the product contract before building the assistant loop on top of it.

Tasks:

1. Add typed telemetry events, fields, visibility classifications, and turn/sequence correlation.
2. Add a deterministic recorder with test clock and in-memory sink.
3. Add an OSLog sink that renders non-sensitive fields as public/visible and omits or protects sensitive fields.
4. Add signpost interval helpers for turn, ASR/STT, LLM, action, TTS, playback, and barge-in spans.
5. Add test helpers every later v2 test can reuse for event order and privacy assertions.

Default tests:

- events get deterministic sequence numbers,
- spans close on success, failure, and cancellation,
- public debug fields are marked visible,
- transcript/prompt/user payload fields are absent or private,
- no test depends on live OSLog, real timers, microphone, model loading, or speakers.

Commit:

```bash
git add Ora/Telemetry OraCoreTests/Telemetry project.yml
git commit -m "feat: add v2 telemetry spine"
```

### Phase 2: Build the text-first assistant loop

Goal: prove the assistant flow without audio/model complexity.

Tasks:

1. Add `AssistantSession` that accepts typed text and fake model output.
2. Add fake `ActionHost` for tests.
3. Add result/proposal rendering model for UI.
4. Keep ASR/TTS out of the loop until behavior is deterministic.

Default tests:

- typed request → read-only action result,
- typed request → mutation proposal,
- confirmed proposal → executed action + audit record,
- rejected proposal → no execution,
- text turn emits turn/input/action/proposal/result/completion telemetry in order,
- input telemetry exposes public character counts and turn IDs, not typed request content.

Commit:

```bash
git add Ora/Interaction Ora/Actions OraCoreTests
git commit -m "feat: add v2 text-first assistant loop"
```

### Phase 3: Port core actions with adapters

Goal: move calendar, reminders, contacts, and minimal system actions behind the new `ActionHost` boundary.

Tasks:

1. Port or wrap calendar reads and mutations.
2. Port or wrap reminder reads and mutations.
3. Port or wrap contact fuzzy lookup.
4. Port minimal system open-app/open-url/open-settings actions.
5. Keep legacy mail/messages/notes/research/tools unregistered.

Default tests:

- one happy path and one failure path per action family,
- ASR-imperfect contact/reminder lookup fixtures,
- mutation confirmation enforcement,
- permission-denied summaries,
- action telemetry records domain/name/kind, confirmation state, result category, duration, and audit correlation without raw user payloads.

Commit:

```bash
git add Ora/Actions OraCoreTests
git commit -m "feat: port v2 core actions"
```

### Phase 4: Replace prompt and structured output surface

Goal: make the LLM see only the v2 product.

Tasks:

1. Add compact v2 system prompt builder.
2. Include only core actions in action catalog.
3. Reject unknown/deprecated action names before execution.
4. Track prompt size in a fast test.

Default tests:

- prompt contains calendar/reminders/contacts/minimal system actions,
- prompt does not contain memory, skills, research, mail, messages, notes, cloud, or vision policy,
- structured output parser accepts response/action/proposal only,
- invalid JSON gets bounded retry behavior,
- prompt/output telemetry records sizes, token counts, retry counts, first-token timing, and parser categories without prompt or model-output content.

Commit:

```bash
git add Ora/ModelRuntime Ora/Resources OraCoreTests
git commit -m "feat: add v2 prompt and structured output"
```

### Phase 5: Rebuild the compact UI around v2 states

Goal: make the visible app match the smaller product.

Tasks:

1. Map `AssistantState` to overlay states.
2. Build proposal confirmation UI for mutations.
3. Reduce preferences to General, Permissions, Models, Audit.
4. Remove UI entry points for deprecated features.

Default tests:

- view models render listening/thinking/proposal/error states,
- preferences tab list contains only v2 tabs,
- proposal view model exposes action, target, date/time, and confirmation consequence,
- UI telemetry records state transitions and confirmation/rejection choices with visible event names and no sensitive proposal payload content.

Commit:

```bash
git add Ora/UI Ora/Overlay Ora/Preferences OraCoreTests
git commit -m "feat: simplify v2 UI surface"
```

### Phase 6: Reattach voice and local model runtime

Goal: connect the proven audio/model pieces after the text loop is correct.

Tasks:

1. Connect push-to-talk to `VoiceLoop`.
2. Connect ASR transcript output to `AssistantSession`.
3. Connect local LLM structured output to v2 parser.
4. Connect TTS to final assistant response only.
5. Keep real model/audio tests opt-in, not default.

Default tests:

- voice loop state transitions use fakes,
- ASR text is treated as untrusted input,
- final text response can trigger optional TTS,
- cancellation stops current turn cleanly,
- voice telemetry reconstructs audio capture → ASR/STT → LLM → action/proposal/result → TTS/playback → completion/cancel in order,
- barge-in telemetry records monitoring, detection, confirmation/rejection, and cancellation without transcript or audio content.

Opt-in tests:

- real ASR smoke,
- real TTS smoke,
- local model smoke.

Commit:

```bash
git add Ora/Interaction Ora/ModelRuntime Ora/ASR Ora/Audio Ora/TTS OraCoreTests
git commit -m "feat: connect v2 voice loop"
```

### Phase 7: Remove or quarantine legacy code and tests

Goal: make the repository reflect the product instead of preserving dead surface.

Tasks:

1. Delete deprecated source directories that no longer compile into v2.
2. Delete or move deprecated tests out of the default test target.
3. Remove deprecated dependencies from `project.yml` when unused.
4. Remove deprecated setup/preferences affordances.
5. Update docs if any cut changes the accepted v2 scope.

Verification:

```bash
./build.sh test
./build.sh
```

Commit:

```bash
git add -A
git commit -m "refactor: remove legacy platform surface"
```

### Phase 8: Stabilize the narrow product

Goal: polish the few supported workflows until they are reliable.

Tasks:

1. Run manual calendar/reminder/contact scenarios.
2. Tighten failure copy for permission and ambiguity cases.
3. Measure default test runtime.
4. Measure prompt length and TTFT.
5. Review local telemetry traces/signposts for each manual scenario.
6. Fix only issues in the v2 scope.

Verification:

```bash
./build.sh test
./build.sh run
```

Commit:

```bash
git add -A
git commit -m "fix: stabilize v2 core workflows"
```

## 6. Default test suite shape

The default test suite should contain a small set of durable contract tests:

```text
OraCoreTests/
  App/
    OraFeatureSetTests.swift
  Interaction/
    AssistantStateTests.swift
    AssistantSessionTests.swift
  Telemetry/
    TelemetryRecorderTests.swift
    TelemetryPrivacyTests.swift
  ModelRuntime/
    StructuredOutputTests.swift
    SystemPromptContractTests.swift
  Actions/
    ActionHostTests.swift
    CalendarActionTests.swift
    ReminderActionTests.swift
    ContactActionTests.swift
    SystemActionTests.swift
  Data/
    AuditStoreTests.swift
  UI/
    OverlayViewModelTests.swift
    PreferencesSurfaceTests.swift
```

Default test rules:

- every behavior test that changes conversation flow asserts telemetry event order and privacy classification,
- no real network,
- no real model loading,
- no real microphone/speaker dependency,
- no permission prompts,
- no sleeps/timers unless controlled by a test clock,
- no tests for deprecated features,
- target runtime under 60 seconds.

## 7. MacTalk PR 14 improvements to port

MacTalk PR [benedict2310/MacTalk#14](https://github.com/benedict2310/MacTalk/pull/14) contains several fixes that should inform Ora v2 implementation.

### ASR / Parakeet runtime

Port these ideas into `ModelRuntime/LocalASRClient.swift` or the v2 wrapper around `Ora/ASR/ParakeetEngine.swift`:

- Keep `TdtDecoderState` owned by each engine/session instead of resetting shared `AsrManager` decoder state.
- Initialize decoder state from `manager.decoderLayerCount` before streaming transcription.
- Reset local decoder state at the start of each user turn.
- Use a fresh decoder state for final full-buffer transcription so partial streaming state cannot pollute the final result.
- Keep chunk processing serialized if v2 ever processes chunks on background tasks; Parakeet streaming decoder state is order-dependent.

Ora already uses the v3 Parakeet model identifier/path, but current `Ora/ASR/ParakeetEngine.swift` still uses the older `manager.transcribe(buffer, source: .microphone)` style and shared bootstrap reset behavior. That should be updated during the v2 ASR port.

### Capture-before-prepare behavior

MacTalk starts microphone capture before Parakeet preparation so the user does not lose the beginning of speech while the model warms. Ora currently preloads ASR on app launch, but the v2 voice loop should still be robust on cold start or failed preload:

- start audio capture immediately when the user begins speaking,
- buffer pre-roll samples while ASR prepares,
- start transcription after preparation completes,
- stop capture and drain/cancel pending work if preparation fails or the start is cancelled.

This belongs in `Interaction/VoiceLoop.swift`, not in app startup.

### Transcript cleanup

Port a small, tested final-transcript cleaner before text reaches the assistant session:

- strip leading punctuation/artifacts from ASR output,
- normalize duplicate spaces and punctuation spacing,
- remove common filler words such as `um`, `uh`, `erm`, `er`, `hm`, and `hmm` only as standalone words,
- capitalize sentence starts after cleanup,
- avoid removing filler substrings inside real words such as `summary`.

This should be tested as a pure unit contract because ASR-imperfect text directly affects tool selection and fuzzy lookup.

### Permission diagnostics

MacTalk's stale Accessibility fix is less directly applicable because Ora v2 should not require Accessibility for its core flow unless a future feature reintroduces paste/automation. The useful principle is still worth keeping:

- UI state should reflect current macOS trust, not only a stored preference.
- Local ad-hoc/DerivedData builds can have stale TCC rows; diagnostics should explain bundle ID, signing mode, and executable path when permission state looks inconsistent.
- Do not reset TCC permissions automatically in production-signed builds.

If v2 keeps or reintroduces Accessibility-dependent features, add a tiny policy object and tests before wiring UI toggles.

### Logging privacy

MacTalk review removed transcript prefixes from logs and kept only character counts. Ora v2 should follow the same rule: production logs may include lengths, states, timings, and error categories, but should not log transcript content or clipboard/action payload text.

## 8. Definition of done for v2 shape

The new shape is real when all of these are true:

- `docs/product/` and `docs/architecture/` describe the app a contributor sees in code.
- default app startup initializes no deprecated subsystems.
- default registered actions are only calendar, reminders, contacts, and minimal system actions.
- default prompt does not mention deprecated domains.
- preferences expose only the v2 surface.
- default tests are fast and focused on product contracts.
- old platform features are deleted or unreachable without development-only flags.
- the app supports one polished end-to-end happy path for each core use case,
- every supported conversation path produces a local trace that shows I/O, ASR/STT, LLM, action, TTS/playback, cancellation, and barge-in timing without exposing private user content.

## 9. Immediate next step

After Phase 1 is accepted, implement Phase 1.5 as a dedicated TDD story before Phase 2:

1. create the typed telemetry event model and privacy field policy,
2. add deterministic recorder/sink/clock test helpers,
3. add OSLog rendering that marks non-sensitive fields public/visible and protects sensitive fields,
4. add signpost interval helpers for major conversation spans,
5. make telemetry assertions mandatory in every Phase 2+ execution plan and acceptance criteria.
