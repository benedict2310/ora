# Ora - System Architecture

> **Version:** 1.1
> **Last Updated:** 2025-12-27
> **Minimum macOS:** 26 (Tahoe)

---

## Table of Contents

0. [Story Mapping](#story-mapping)
1. [System Architecture Overview](#1-system-architecture-overview)
2. [Agentic Loop Design](#2-agentic-loop-design)
3. [Audio Pipeline](#3-audio-pipeline)
4. [Model Runtime Strategy](#4-model-runtime-strategy)
5. [Model Distribution & Management](#5-model-distribution--management)
6. [System Prompt Design](#6-system-prompt-design)
7. [Swift 6 Implementation](#7-swift-6-implementation)
8. [Security & Threat Model](#8-security--threat-model)
9. [Benchmarks & Performance](#9-benchmarks--performance)
10. [Model Selection Matrix](#10-model-selection-matrix)

---

## Story Mapping

This section maps architecture components to their implementation stories. See [README.md](README.md) for full story index and status.

| Architecture Component | Implementation Stories | Status |
|:-----------------------|:-----------------------|:-------|
| **Menubar UI + Hotkey** | F.01, F.05 | ✅ Complete |
| **AudioPipeline** | A.01 (Audio Service) | ✅ Complete |
| **ASRService** | A.02, A.03, A.04 | ✅ Complete |
| **LLMRuntime** | L.01 (LLM Runtime) | ✅ Complete |
| **Structured Output** | L.02 (Structured Output) | ✅ Complete |
| **ConversationManager** | L.03 (Conversation Manager) | ✅ Complete |
| **System Prompt** | L.04 (System Prompt) | ✅ Complete |
| **Simple ASR→LLM Pipeline** | O.01 (ASR-LLM Pipeline) | 🚧 To Do |
| **AgentLoop** | O.02 (Agent Loop) | 🚧 To Do |
| **ConversationOrchestrator** | O.03 (Conversation Orchestrator) | 🚧 To Do |
| **ConfirmationGate** | O.04 (Confirmation Flow) | 🚧 To Do |
| **ToolHost + Tools** | X.01-X.05 | 🚧 To Do |
| **TTSEngine** | T.01 (TTS Service) | 🚧 To Do |
| **AudioPlayback** | T.02 (Audio Playback) | 🚧 To Do |

### Implementation Order

```
Phase 1-2: ✅ Complete
  F.* (Foundations) → A.* (ASR) → L.* (LLM)

Phase 3: 🚧 Current
  O.01 (ASR-LLM Pipeline) ← Simple wiring for testing

Phase 4: Next
  X.01 (Tool Protocol) → X.02-X.05 (Tools) → O.02 (Agent Loop)

Phase 5: TTS
  T.01 → T.02 → T.03

Phase 6: Full Orchestration
  O.03 (Full Orchestrator) → O.04 (Confirmation Flow)
```

---

## 1. System Architecture Overview

### Component Diagram

```
[Menubar UI + Hotkey (⌥Space)]
        |
        v
[ConversationOrchestrator @MainActor]  <--- renders state + confirmations
        |
        v
[AgentLoop actor]  <--- step budget, tool gating, policy enforcement, audit events
   |        | \
   |        |  \--> [ToolHost actor] ---> (EventKit / Contacts / Reminders / Safe Actions)
   |        |          |   \
   |        |          |    \--> [ConfirmationGate @MainActor] (mutations require explicit consent)
   |        |
   |        \--> [LLMRuntime actor]  (MLX Swift + Qwen 2.5)  ---> token stream
   |
   \--> [AudioPipeline actor]
          |--> [AVAudioEngine Capture + RingBuffer]
          |--> [VAD/EOU] ---> end-of-speech events
          \--> [ASRService] (FluidAudio Parakeet streaming) ---> partial transcript stream

[TTSEngine actor] (Kokoro MLX) ---> audio chunk stream ---> [AudioPlayback actor]
        |                              \--> [AVSpeechSynthesizer fallback]
        v
[Local Audit Log + Session Store] (SwiftData; encrypted; local-only)
```

### Key Boundaries

Clear separation of concerns enforces security and maintainability:

| Component | Can Access | Cannot Access |
|:----------|:-----------|:--------------|
| **UI Layer** | Submit user speech, confirmations, cancel | Never call tools directly |
| **AgentLoop** | LLM for next step, ToolHost for execution | Direct system frameworks |
| **ToolHost** | EventKit, Contacts, safe system actions | LLM, UI state |
| **LLMRuntime** | Token generation only | Tools, files, clipboard, UI |
| **AudioPipeline** | Transcript events | Intent parsing, planning |

### Swift 6 Concurrency Note

Treat each boundary as an actor with explicit, `Sendable` message types. Enable Swift 6 strict concurrency checking early ("Complete" checking in Xcode) to catch data races before they ship.

---

## 2. Agentic Loop Design

### Event Model (Internal Canonical Format)

Use a single append-only event log for the session; derive UI state from it.

```json
{
  "id": "evt_...",
  "ts": "2025-12-27T09:12:34.123Z",
  "type": "user|asr_partial|assistant|tool_call|tool_result|proposal|confirmation|error",
  "role": "user|assistant|tool",
  "content": {
    "text": "...",
    "json": { "any": "structured payload" }
  },
  "meta": {
    "trusted": false,
    "source": "asr|llm|eventkit|contacts|system",
    "token_count": 123,
    "hash": "sha256..."
  }
}
```

**Principles:**
- Everything not authored by your app code is **untrusted** (ASR text, tool outputs, even LLM outputs)
- The LLM never "sees" raw tool output as instructions; it sees them as **data** (bounded, sanitized)

### Tool Schema Definition

Each tool is defined with:

| Property | Description |
|:---------|:------------|
| `name` | Unique tool identifier |
| `args_schema` | JSON Schema for arguments |
| `kind` | `read` or `mutate` |
| `confirmation` | Required policy for mutations |

**Example: `calendar.create_event`**

```json
{
  "name": "calendar.create_event",
  "description": "Create a calendar event. Requires confirmation.",
  "kind": "mutate",
  "args_schema": {
    "type": "object",
    "additionalProperties": false,
    "properties": {
      "title": { "type": "string", "minLength": 1, "maxLength": 120 },
      "start": { "type": "string", "format": "date-time" },
      "end":   { "type": "string", "format": "date-time" },
      "notes": { "type": "string", "maxLength": 2000 },
      "location": { "type": "string", "maxLength": 200 },
      "calendar_id": { "type": "string", "maxLength": 200 }
    },
    "required": ["title", "start", "end"]
  }
}
```

**Enforcement Tip:** Constrain LLM output to only produce valid JSON/tool calls using llama.cpp grammar (GBNF) so the agent cannot "smuggle" free-form instructions inside a tool call envelope.

### Loop Policy

**v1 Defaults:**

| Parameter | Value | Purpose |
|:----------|:------|:--------|
| `max_steps_per_turn` | 6 | Prevent runaway loops |
| `max_tool_calls_per_turn` | 3 | Limit tool invocations |
| `max_total_tokens_generated` | 800 | Per-turn token budget |

**Retry Strategy:**

| Failure Type | Strategy |
|:-------------|:---------|
| Tool execution (transient) | Exponential backoff: 200ms → 500ms → 1s, max 3 retries |
| LLM JSON parse failure | 1 retry with stricter schema / shorter context |

### Confirmation Flow (Two-Phase Commit)

**Phase 1: Proposal** (no tool calls executed)
- LLM produces a proposal object:
  - Summary of what it plans to do
  - List of tool calls (dry-run)
  - User-facing "confirm?" prompt

**Phase 2: Execution** (after explicit user confirm)
- ToolHost executes the approved tool calls

**UI Requirements:**
- Show "What will change" (diff-like preview)
- Show where it will happen (which calendar / which contact)
- **Timeout:** 1 minute - proposal auto-cancels if no response

### Treating Tool Outputs as Untrusted

**Rules:**
- Sanitize + bound (maxChars, strip control chars, normalize newlines)
- Never concatenate tool output into the system prompt
- Put tool results into a dedicated `tool_result` channel with a data header the model cannot override

**Example wrapper:**

```
TOOL_RESULT (untrusted data)
tool=contacts.search
rows=3
data_json=...
```

---

## 3. Audio Pipeline

### Capture: AVAudioEngine + Ring Buffer

```swift
// AVAudioEngine.inputNode.installTap → push audio frames into lock-free ring buffer
// Tap block may be called off-main; do no heavy work there
// Copy samples, timestamp, enqueue. Avoid allocations/locks in time-critical audio paths.
```

### Rolling-Window Partial ASR

Prefer FluidAudio streaming rather than re-transcribing overlapping windows:
- `StreamingEouAsrManager` with 160ms/320ms chunk support
- Built-in end-of-utterance detection

**Pipeline Configuration:**

| Parameter | Value | Notes |
|:----------|:------|:------|
| Frame size | 20ms @ 16kHz (320 samples) | Internal processing |
| Chunk to ASR | 160ms | Reduces TTFT while keeping overhead reasonable |
| Partial emit rate | ~5-10 Hz | Throttled for UI stability |

**Events:**
- `asr_partial`: Every chunk (throttled)
- `asr_final`: When EOU triggers

### VAD / End-of-Speech

**v1 Approach: Push-to-Talk Only**

For v1, we use a simple PTT model:
- User holds hotkey while speaking
- Release triggers finalization immediately
- No EOU detection needed

**Why PTT-only for v1:**
- Simplest to implement correctly
- Most predictable for users
- Zero tuning required
- Works in all environments (noisy or quiet)
- Clear mental model: "hold to speak, release to send"

**Future (v2+):** Optional EOU mode for users who prefer auto-detection.

### Threading Model

| Thread | Responsibility |
|:-------|:---------------|
| **Audio thread** | Capture → ring buffer only |
| **ASR actor** | Pulls from ring buffer, feeds streaming ASR, emits partials |
| **AgentLoop actor** | Starts when PTT released (hotkey up) |

**Cancellation:** User hits hotkey again → cancel ASR + agent + TTS, flush playback queue

---

## 4. Model Runtime Strategy

### LLM Runtime: MLX Swift (Primary)

**Decision:** MLX Swift is the primary runtime for maximum Apple Silicon performance.

**Why MLX:**
- Apple's first-party Swift bindings (`mlx-swift`)
- Language model support via `mlx-swift-lm`
- Best throughput on Apple Silicon (unified memory architecture)
- Native Swift integration, no bridging overhead
- Active development by Apple ML team

**Trade-offs vs llama.cpp:**
- No native grammar-constrained decoding (GBNF) → use validation + retry
- Model format: MLX safetensors (not GGUF)
- Requires macOS 14+ (we target macOS 26+)

### LLM Model: Qwen 2.5

**Primary Model:** Qwen 2.5 7B (4-bit quantized)
**Fallback Model:** Qwen 2.5 3B (4-bit quantized)

| Model | RAM Usage | Context | Use Case |
|:------|:----------|:--------|:---------|
| **Qwen 2.5 7B-4bit** | ~5GB | 8k | Primary - best reasoning + tool calling |
| **Qwen 2.5 3B-4bit** | ~2GB | 4k | Fallback for lower-RAM devices |

**Why Qwen 2.5:**
- Excellent structured JSON output (critical for tool calling)
- Strong instruction following
- Good multilingual support
- Well-supported in MLX ecosystem (`mlx-community` models on HuggingFace)

**Model Sources (Verified on HuggingFace):**
- LLM Primary: [`mlx-community/Qwen2.5-7B-Instruct-4bit`](https://huggingface.co/mlx-community/Qwen2.5-7B-Instruct-4bit)
- LLM Fallback: [`mlx-community/Qwen2.5-3B-Instruct-4bit`](https://huggingface.co/mlx-community/Qwen2.5-3B-Instruct-4bit)
- TTS: [`mlx-community/Kokoro-82M-bf16`](https://huggingface.co/mlx-community/Kokoro-82M-bf16)
- TTS Swift: [`kokoro-swift-mlx`](https://github.com/mattmireles/kokoro-swift-mlx)

### Structured Output Strategy

**Approach:** Post-generation validation + retry (v1)

Since MLX lacks native grammar constraints, we enforce structured output via:

1. **Strong system prompt** - Explicit JSON-only instruction
2. **Schema validation** - Validate against JSON Schema after generation
3. **Retry on failure** - Max 2 retries with increasingly strict prompts
4. **Streaming JSON parsing** - Detect malformed JSON early

```swift
// Retry policy for JSON validation failures
struct JSONRetryPolicy {
    let maxAttempts = 3
    let stricterPromptOnRetry = true
    let reduceContextOnRetry = true  // Drop older messages if needed
}
```

**Future improvement:** Monitor for Swift grammar-constrained decoding libraries.

### ASR: FluidAudio Parakeet

**Decision:** FluidAudio Parakeet for speech-to-text (as specified).

**SDK Version:** v0.8.1+ (via SwiftPM)

**Streaming Approach for v1 (PTT Mode):**
- Use `StreamingEouAsrManager` for 160/320ms chunk streaming with built-in EOU detection
- EOU detection disabled for v1 (finalization on PTT release)
- Alternative: `AsrManager` batch transcription on PTT release (simpler, slightly higher latency)

**Streaming Options (for reference):**
| Manager | Use Case | Chunking | EOU Detection |
|:--------|:---------|:---------|:--------------|
| `StreamingEouAsrManager` | Voice assistant (recommended) | 160/320ms | Built-in (1280ms debounce) |
| `StreamingAsrManager` | Rolling-window with volatile/confirmed | Re-decode windows | No (use VAD) |
| `AsrManager` | Batch transcription | Full buffer | No |

**Model:** Parakeet TDT 0.6B v3 (CoreML)
- Source: `https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml` (~600MB)
- Multilingual support (English primary)
- ~190× real-time throughput on M4 Pro

**Custom Storage Path:**
FluidAudio supports custom model directories via `AsrModels.downloadAndLoad(to:)`:
```swift
let oraDir = appSupport.appendingPathComponent("Ora/Models/asr/parakeet", isDirectory: true)
let models = try await AsrModels.downloadAndLoad(to: oraDir, configuration: .defaultConfiguration(), version: .v3)
```

### TTS: Kokoro MLX

**Primary:** Kokoro MLX Swift
**Fallback:** `AVSpeechSynthesizer` (system TTS)

**Model:** [`mlx-community/Kokoro-82M-bf16`](https://huggingface.co/mlx-community/Kokoro-82M-bf16)
**Swift Implementation:** [`kokoro-swift-mlx`](https://github.com/mattmireles/kokoro-swift-mlx)

- 82M parameter model - lightweight but high quality
- Faster-than-real-time generation after warmup (~3.3x on M-series)
- **Important:** Always show text response in UI, regardless of TTS status
- If Kokoro fails: show error message + fallback to AVSpeechSynthesizer
- Downloaded on first run (not bundled)

**Streaming Playback:**
- Generate PCM chunks (200-400ms)
- Enqueue into `AVAudioPlayerNode` via `scheduleBuffer`
- Keep small jitter buffer (600-1000ms queued) to avoid underruns
- On interrupt: stop node + clear queued buffers

### Warmup Strategy (Critical for UX)

On app launch (background, non-blocking):

| Component | Warmup Action | Expected Time |
|:----------|:--------------|:--------------|
| **ASR** | Run 1-2 silent chunks through feature extractor | ~200ms |
| **LLM** | Run tiny prompt to force Metal kernel compilation | ~500-1000ms |
| **TTS** | Synthesize 0.2s of silence and discard | ~300ms |

Show subtle loading indicator in menu bar until warmup complete.

---

## 5. Model Distribution & Management

### Storage Location

```
~/Library/Application Support/Ora/
├── Models/
│   ├── llm/
│   │   ├── qwen2.5-7b-instruct-4bit/    # Primary LLM
│   │   └── qwen2.5-3b-instruct-4bit/    # Fallback LLM
│   ├── asr/
│   │   └── parakeet/                     # Downloaded on first run
│   └── tts/
│       └── kokoro/                       # Downloaded on first run
├── Sessions/                             # SwiftData store
└── AuditLog/                             # Encrypted audit logs
```

### First-Run Download Flow

1. **App Launch** → Check for required models
2. **Missing Models** → Show download modal (blocks app usage)
3. **Download** → Fetch all three models **in parallel** from HuggingFace (with resume support)
4. **Verify** → SHA256 checksum validation; show error + retry on failure
5. **Ready** → Enable voice assistant

**Postpone Behavior:** If user postpones, show minimal UI with "Resume Setup" button. App stays open but non-functional.

**Resume Support:** Download progress persisted across app restarts. Partial downloads resume where they left off.

**Download Sources (HuggingFace):**
- LLM 7B: `https://huggingface.co/mlx-community/Qwen2.5-7B-Instruct-4bit`
- LLM 3B: `https://huggingface.co/mlx-community/Qwen2.5-3B-Instruct-4bit`
- TTS: `https://huggingface.co/mlx-community/Kokoro-82M-bf16`
- ASR: `https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml` (~600MB)

### Preferences: Model Management

Users can manage models in Preferences → Models:

| Model | Actions | Notes |
|:------|:--------|:------|
| **LLM (Qwen 2.5 7B)** | Download, Delete, Set Primary | User-manageable |
| **LLM (Qwen 2.5 3B)** | Download, Delete, Set Primary | User-manageable |
| **ASR (Parakeet)** | View info only | Required, cannot delete (~600MB) |
| **TTS (Kokoro)** | View info only | Required, cannot delete |

**Note:** No hot-swap between models. User selects primary LLM; change takes effect on next app restart.

**UI Elements:**
- Model name, size, download status
- Storage usage per model
- "Download" / "Delete" / "Set as Primary" buttons
- Progress bar during downloads

### Model Versioning

Store model metadata in SwiftData:

```swift
@Model
class InstalledModel {
    var name: String
    var version: String
    var path: URL
    var sizeBytes: Int64
    var sha256: String
    var downloadedAt: Date
    var isPrimary: Bool
    var availableUpdate: String?  // New version if available
}
```

### Model Update Strategy

**No separate model updates.** Models are updated through app updates:

1. **Daily app update check** - Ora checks for new app versions daily
2. **System notification** - "Ora: Update available (v1.2.0)"
3. **Click notification** → Opens download page / App Store
4. **New models included** - App updates may include new/improved model support
5. **Download on update** - New models downloaded on first launch after update

**Rationale:** New models require implementation changes anyway. Bundling model updates with app updates simplifies the update flow and ensures compatibility.

---

## 6. System Prompt Design

### Core Requirements

The system prompt MUST include:
1. **Current date/time and timezone** - For date parsing
2. **Strict JSON output instructions** - For structured output compliance
3. **Available tools schema** - For tool calling
4. **User preferences** - Default calendar, etc.

### System Prompt Template

```
You are Ora, a helpful voice assistant running locally on macOS. You help users manage their calendar, reminders, and contacts.

CURRENT CONTEXT:
- Date: {current_date} (e.g., "Friday, December 27, 2025")
- Time: {current_time} (e.g., "2:30 PM")
- Timezone: {timezone} (e.g., "America/Los_Angeles")
- Default Calendar: {default_calendar_name}

CRITICAL OUTPUT RULES:
1. You MUST respond with valid JSON only. No markdown, no explanations outside JSON.
2. Every response must match one of these formats:

For direct answers (no tool needed):
{"type": "response", "text": "Your spoken response here"}

For tool calls:
{"type": "tool_call", "tool": "tool_name", "args": {...}}

For confirmations (mutations):
{"type": "proposal", "summary": "What will happen", "tool": "tool_name", "args": {...}}

3. All dates/times in tool arguments MUST be ISO 8601 format: "2025-12-27T14:30:00-08:00"
4. If the user's request is ambiguous, ask for clarification using a response.
5. Never execute mutations without first proposing them for confirmation.

AVAILABLE TOOLS:
{tools_json_schema}

Remember: JSON only. No prose outside the JSON structure.
```

### Dynamic Context Injection

```swift
struct SystemPromptBuilder {
    func build(
        currentDate: Date,
        timezone: TimeZone,
        defaultCalendar: String?,
        tools: [Tool]
    ) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE, MMMM d, yyyy"
        formatter.timeZone = timezone

        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "h:mm a"
        timeFormatter.timeZone = timezone

        return template
            .replacing("{current_date}", with: formatter.string(from: currentDate))
            .replacing("{current_time}", with: timeFormatter.string(from: currentDate))
            .replacing("{timezone}", with: timezone.identifier)
            .replacing("{default_calendar_name}", with: defaultCalendar ?? "Default")
            .replacing("{tools_json_schema}", with: encodeToolSchemas(tools))
    }
}
```

### Retry Prompt (Stricter)

When JSON validation fails, retry with stricter prompt:

```
Your previous response was not valid JSON. You MUST respond with ONLY a JSON object.
Do not include any text before or after the JSON.
Do not use markdown code blocks.
Just output the raw JSON object starting with { and ending with }.

User's original request: {original_request}
```

---

## 7. Swift 6 Implementation

### Core Protocols

```swift
// MARK: - Audio
protocol AudioCapturing: Sendable {
    func start() async throws
    func stop() async
    var frames: AsyncStream<AudioFrame> { get }
}

struct AudioFrame: Sendable {
    let pcm16: [Int16]
    let sampleRate: Int
    let channels: Int
    let timestamp: UInt64
}

// MARK: - ASR
protocol ASRServicing: Sendable {
    func transcribe(frames: AsyncStream<AudioFrame>) -> AsyncThrowingStream<ASREvent, Error>
}

enum ASREvent: Sendable {
    case partial(text: String, stability: Float)
    case final(text: String)
    case endOfSpeech
}

// MARK: - LLM
protocol LLMServicing: Sendable {
    func respond(to messages: [LLMMessage], schema: JSONSchema) -> AsyncThrowingStream<LLMDelta, Error>
}

struct LLMMessage: Sendable {
    enum Role: Sendable { case system, user, tool, assistant }
    let role: Role
    let content: String
}

enum LLMDelta: Sendable {
    case token(String)
    case jsonFragment(String)
    case completed
}

// MARK: - Tools
protocol Tool: Sendable {
    var name: String { get }
    var kind: ToolKind { get }
    var schema: JSONSchema { get }
    func validate(args: JSONValue) throws
    func execute(args: JSONValue) async throws -> ToolResult
}

enum ToolKind: Sendable { case read, mutate }

struct ToolResult: Sendable {
    let json: JSONValue
    let humanSummary: String
}

// MARK: - Agent Loop
protocol AgentLooping: Sendable {
    func handleUserText(_ text: String) async
    func confirm(_ decision: Bool) async
    func cancel() async
}

// MARK: - TTS
protocol TTSServicing: Sendable {
    func speak(_ text: String) -> AsyncThrowingStream<AudioChunk, Error>
}

struct AudioChunk: Sendable {
    let pcmFloat32: [Float]
    let sampleRate: Int
}
```

### ToolHost with Confirmation Gate

```swift
actor ToolHost {
    private let tools: [String: Tool]
    private let policy: ToolPolicy
    private let audit: AuditLogger

    func callTool(name: String, args: JSONValue, confirmed: Bool) async throws -> ToolResult {
        guard let tool = tools[name] else { throw ToolError.unknownTool }
        try tool.validate(args: args)

        if tool.kind == .mutate {
            guard confirmed else { throw ToolError.confirmationRequired }
        }

        // Enforce allowlist + rate limits
        try policy.checkAllowed(tool: tool, args: args)

        let result = try await tool.execute(args: args)
        await audit.recordToolResult(tool: name, args: args, result: result)
        return result
    }
}
```

### Example: Calendar Tools

```swift
import EventKit

struct CalendarListTool: Tool {
    let name = "calendar.list_calendars"
    let kind: ToolKind = .read
    let schema: JSONSchema = .object(required: [], properties: [:])

    func validate(args: JSONValue) throws {}

    func execute(args: JSONValue) async throws -> ToolResult {
        let store = EKEventStore()
        let calendars = store.calendars(for: .event).map {
            ["id": $0.calendarIdentifier, "title": $0.title]
        }
        return ToolResult(
            json: .array(calendars.map(JSONValue.object)),
            humanSummary: "Found \(calendars.count) calendars."
        )
    }
}

struct CalendarCreateEventTool: Tool {
    let name = "calendar.create_event"
    let kind: ToolKind = .mutate
    let schema: JSONSchema = /* see schema above */

    func validate(args: JSONValue) throws {
        // JSON schema validation + semantic checks (end > start, title non-empty)
    }

    func execute(args: JSONValue) async throws -> ToolResult {
        let store = EKEventStore()
        let ev = EKEvent(eventStore: store)
        ev.title = args["title"].stringValue
        ev.startDate = args["start"].dateValue
        ev.endDate = args["end"].dateValue
        try store.save(ev, span: .thisEvent, commit: true)

        return ToolResult(
            json: .object(["event_id": .string(ev.eventIdentifier)]),
            humanSummary: "Created event \"\(ev.title ?? "")\"."
        )
    }
}
```

### Example: Contacts Tool

```swift
import Contacts

struct ContactsSearchTool: Tool {
    let name = "contacts.search"
    let kind: ToolKind = .read
    let schema: JSONSchema = .object(
        required: ["query"],
        properties: ["query": .string(max: 120), "limit": .int(min: 1, max: 20)]
    )

    func validate(args: JSONValue) throws {}

    func execute(args: JSONValue) async throws -> ToolResult {
        let store = CNContactStore()
        let query = args["query"].stringValue
        let keys: [CNKeyDescriptor] = [
            CNContactGivenNameKey as NSString,
            CNContactFamilyNameKey as NSString,
            CNContactEmailAddressesKey as NSString
        ]
        let predicate = CNContact.predicateForContacts(matchingName: query)
        let contacts = try store.unifiedContacts(matching: predicate, keysToFetch: keys)

        let rows = contacts.prefix(args["limit"].intValue).map {
            ["given": $0.givenName, "family": $0.familyName,
             "emails": $0.emailAddresses.map { $0.value as String }]
        }

        return ToolResult(
            json: .array(rows.map(JSONValue.object)),
            humanSummary: "Found \(rows.count) contacts matching \"\(query)\"."
        )
    }
}
```

### UI State Machine

```swift
@MainActor
final class AssistantViewModel: ObservableObject {
    enum State {
        case idle
        case listening
        case thinking
        case proposing(Proposal)
        case executing
        case speaking
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var transcriptPartial: String = ""
    @Published private(set) var lastError: String?

    func onHotkeyDown() { state = .listening /* start capture */ }
    func onHotkeyUp()   { state = .thinking  /* stop capture; finalize ASR */ }

    func onProposal(_ p: Proposal) { state = .proposing(p) }
    func onConfirm(_ yes: Bool)    { state = yes ? .executing : .idle }
    func onSpoken()                { state = .idle }
}
```

---

## 8. Security & Threat Model

### Mitigations (Mapped to Code)

#### Prompt Injection / Tool Hijacking

| Mitigation | Implementation |
|:-----------|:---------------|
| Structured-only agent outputs | Grammar/JSON schema enforcement in `LLMRuntime/StructuredDecoding.swift` |
| Tool allowlist + argument validation | `Tools/ToolHost.swift` |
| Step budgets + tool-call budgets | `Agent/AgentLoop.swift` |

#### Unauthorized Mutations

| Mitigation | Implementation |
|:-----------|:---------------|
| Two-phase commit with UI-owned confirm token | `Agent/ConfirmationGate.swift` |
| Mutate tools hard-require `confirmed == true` | `Tools/ToolHost.swift` |

#### Tool Output Injection

| Mitigation | Implementation |
|:-----------|:---------------|
| Sanitize & bound tool results before adding to context | `Agent/ContextBuilder.swift` |
| Tag everything with `trusted=false` unless app-authored | `Core/EventModel.swift` |

#### Privacy Defaults

| Mitigation | Implementation |
|:-----------|:---------------|
| All inference runs locally | No data uploaded; network only for downloads |
| Encrypted on-device audit log | `Storage/AuditStore.swift` |
| Redaction toggles + "Delete session" button | `UI/PrivacySettings.swift`

#### Focus Recovery During External Operations

When system permission dialogs or tool-initiated operations (opening apps, URLs, Finder) steal focus from Ora, the overlay must remain visible and not cancel the session. This is handled by two tracking systems:

| System | Purpose | Files |
|:-------|:--------|:------|
| `PermissionPromptTracker` | Tracks active permission dialogs | `Permissions/PermissionPromptTracker.swift` |
| `ExternalFocusTracker` | Tracks tool operations that steal focus | `Permissions/ExternalFocusTracker.swift` |

**CRITICAL: Permission Request Architecture**

Permission tracking is handled at **two levels** - do NOT add tracker calls in both:

1. **Central tracking via `PermissionsManager.request()`** - Used by setup wizard, AudioService, and other high-level code. `PermissionsManager` wraps all permission requests with tracker calls automatically.

2. **Tool-level tracking via providers** - `EventStoreProvider` and `RemindersStoreProvider` have their own tracker calls for when tools need permissions directly (bypassing `PermissionsManager`).

**DO NOT add tracker calls to individual permission files** (`MicrophonePermission`, `EventKitPermission`, `ContactsPermission`). These are called by `PermissionsManager` which already tracks - adding tracker calls there causes double tracking, which breaks focus recovery (the inner `endPrompt` clears the state before the outer wrapper finishes).

```swift
// PermissionsManager.request() - ALREADY has tracking
func request(_ type: PermissionType) async -> PermissionStatus {
    let shouldTrackPrompt = client.checkStatus(for: type) == .notDetermined
    if shouldTrackPrompt {
        await PermissionPromptTracker.shared.beginPrompt(for: type)
    }
    let status = await client.request(type)  // Calls MicrophonePermission.request(), etc.
    if shouldTrackPrompt {
        await PermissionPromptTracker.shared.endPrompt(for: type)
    }
    return status
}
```

**Supported permission types:** `.microphone`, `.calendar`, `.reminders`, `.contacts`

**Reference implementations:**
- `PermissionsManager.request()` - Central tracking for all permissions
- `EventStoreProvider.ensureCalendarAccess()` - Tool-level calendar tracking
- `RemindersStoreProvider.ensureRemindersAccess()` - Tool-level reminders tracking

The `OverlayWindowController.handleAppDeactivated()` method checks both trackers before deciding to cancel a session.

---

## 9. Benchmarks & Performance

### Instrumentation Points

Use `os_signpost` / Points of Interest for wall-clock timings:

| Signpost | Measures |
|:---------|:---------|
| `hotkey_down` → `first_audio_frame` | Input latency |
| `first_audio_frame` → `first_asr_partial` | ASR startup |
| `end_of_speech` → `asr_final` | ASR finalization |
| `asr_final` → `llm_ttft` | LLM time-to-first-token |
| `llm_done` → `proposal_rendered` | UI rendering |
| `confirm` → `tool_done` | Tool execution |
| `tool_done` → `first_tts_audio` | TTS generation |
| `first_tts_audio` → `playback_started` | Audio output |

### Memory/CPU Monitoring

- **Development:** Instruments (Time Profiler, Allocations, Points of Interest)
- **Production:** MetricKit for aggregated power/perf diagnostics

### Test Harnesses

#### 1. Long-Session Soak
- 60 minutes of repeated turns: ASR → LLM → TTS
- **Assert:** No monotonic memory growth (leak budget < ~50MB/hr)

#### 2. Tool Stress
- 200 read-only tool calls back-to-back (contacts search, calendar list)
- 50 mutation proposals (deny 49, accept 1)
- **Assert:** Gating correctness maintained

#### 3. Adversarial Prompt Injection
- Inject tool-looking strings into:
  - ASR transcript
  - Tool results (e.g., contact names containing `"{ tool_call: … }"`)
- **Assert:** ToolHost rejects anything not coming through structured channel + confirmation gate

### Acceptance Criteria (v1)

| Category | Metric | Target |
|:---------|:-------|:-------|
| **PTT UX** | First partial transcript | ≤300-500ms after speech onset |
| **PTT UX** | EOU finalization | ≤1.2s after end of speech |
| **Agent** | TTFT (local) | ≤700ms for short prompts |
| **Agent** | Mutation safety | Tool calls never execute without confirmation |
| **TTS** | First audio | ≤500-900ms after text ready (post-warmup) |
| **Reliability** | 30-min session | No crashes, no audio underruns, no runaway loops |

---

## 10. Model Selection Matrix

**Runtime:** MLX Swift (all configurations)
**Model Family:** Qwen 2.5

| Unified RAM | Primary Model | Fallback | Context | Notes |
|:------------|:--------------|:---------|:--------|:------|
| **8 GB** | Qwen 2.5 3B-4bit | - | 2-4k | Minimum viable; prioritize TTFT |
| **16 GB** | Qwen 2.5 7B-4bit | Qwen 2.5 3B-4bit | 4-8k | Recommended config |
| **32 GB** | Qwen 2.5 7B-4bit | Qwen 2.5 3B-4bit | 8-16k | Extended context available |
| **64+ GB** | Qwen 2.5 7B-4bit | Qwen 2.5 3B-4bit | 16k+ | Future: consider 14B+ models |

**Model Memory Budget:**

| Component | Estimated RAM |
|:----------|:--------------|
| Qwen 2.5 7B-4bit | ~5GB |
| Qwen 2.5 3B-4bit | ~2GB |
| Parakeet ASR | ~500MB |
| Kokoro TTS | ~500MB |
| KV Cache (8k context) | ~1GB |
| **Total (7B config)** | ~7GB |

**Minimum System Requirements:**
- macOS 26 (Tahoe) or later
- Apple Silicon (M1 or later)

| RAM | Experience | Model Used |
|:----|:-----------|:-----------|
| **8 GB** | Minimum viable | Qwen 2.5 3B (auto-selected) |
| **16 GB** | Recommended | Qwen 2.5 7B |
| **32 GB** | Best | Qwen 2.5 7B + extended context |

User is informed of RAM-based recommendations during first-run setup.
