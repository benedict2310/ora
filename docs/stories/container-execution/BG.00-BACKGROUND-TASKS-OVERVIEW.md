# BG.00 - Background Tasks Overview

**Epic:** Background Tasks
**Status:** Not Started
**Priority:** P1 (High)
**Estimated Effort:** 1 day
**Dependencies:** None
**Target:** macOS 26 (Tahoe)
**Design Reference:** None

---

## 1. Objective

Define the end-to-end architecture and UX flow for background task execution in Ora. This story is the framing document for the entire Background Tasks epic — it establishes the interaction model, isolation strategy, and integration points with the existing pipeline.

## 2. User Story

As a **user**, I want Ora to **perform research tasks in the background** so that I can **get curated results without waiting for long-running fetches during conversation**.

## 3. Scope

### In Scope

- End-to-end UX flow definition (trigger → queue → execute → notify → load)
- Phased isolation strategy (in-process → XPC → Apple Container)
- Architecture diagram showing relationship to existing pipeline components
- Task lifecycle state machine specification
- Artifact layout and user-visible folder structure
- Notification strategy (start + completion)
- Integration points with `AgentLoop`, `ConversationManager`, and `ToolRegistry`

### Out of Scope

- Implementation code (covered by BG.01-BG.07)
- Browser automation / Playwright
- Daemon / login item background helper
- Cloud execution
- Task scheduling / cron
- Cross-device sync

## 4. Architecture Alignment

### Relationship to Existing Pipeline

```
┌─────────────────────────────────────────────────────────┐
│                 EXISTING PIPELINE                        │
│  Hotkey → ASR → AgentLoop → Tools → TTS                │
│                    │                                     │
│                    │ (new tool: research.start)          │
│                    ▼                                     │
│  ┌─────────────────────────────────────────┐            │
│  │        BACKGROUND TASK SYSTEM           │            │
│  │                                         │            │
│  │  BackgroundTaskManager (actor)          │            │
│  │    ├── TaskQueue (SwiftData)            │            │
│  │    ├── WorkerPool (1-2 concurrent)      │            │
│  │    ├── ArtifactStore (~/Documents/)     │            │
│  │    └── NotificationService (UNUser...)  │            │
│  └──────────────────┬──────────────────────┘            │
│                     │                                    │
│                     │ (new tool: research.load_result)   │
│                     ▼                                    │
│              AgentLoop context injection                 │
└─────────────────────────────────────────────────────────┘
```

### Concurrency Model

- `BackgroundTaskManager` is a new **actor** that runs alongside `SimplePipelineController`
- Workers execute on background threads via Swift Concurrency tasks
- GPU access for summary generation serialized via existing `MLXMetalGate`
- UI updates via `@MainActor` notifications

### Key Boundaries

| Component | Can Access | Cannot Access |
|:----------|:-----------|:--------------|
| **BackgroundTaskManager** | URLSession, FileManager, UNNotificationCenter | LLM directly (must queue via MLXMetalGate) |
| **Workers** | Network (validated URLs only), output directory | Host filesystem, other workers, LLM |
| **ArtifactStore** | ~/Documents/Ora Research/ | App bundle, ~/Library/ |
| **NotificationService** | UNUserNotificationCenter | Tool execution, conversation state |

### Phased Isolation Strategy

**Phase 1 (v1): In-Process URLSession**
- Workers run as Swift Concurrency tasks within Ora's process
- Network safety enforced by host-side URL validation before fetch
- HTML parsing via SwiftSoup (or similar) in-process
- Sufficient for HTTP fetch + readability extraction

**Phase 2 (future): XPC Service**
- Dedicated XPC service with restricted App Sandbox profile
- Network-only entitlement, no filesystem access except output dir
- Swift-native, no cross-compilation needed

**Phase 3 (future): Apple Container**
- Linux VM via apple/containerization Swift package
- Full process isolation for untrusted code execution
- Requires cross-compilation (Swift Static Linux SDK)
- Sub-second startup on Apple Silicon

### End-to-End UX Flow

```
1. User: "Research the latest Swift concurrency best practices"
         │
2. AgentLoop recognizes research intent
   LLM generates: {"type": "tool_call", "tool": "research.start", "args": {...}}
         │
3. BackgroundTaskManager.enqueue(task)
   Task state: queued → running
         │
4. Notification: "🔍 Research started: Swift concurrency best practices"
         │
5. URLSessionWorker executes:
   - Fetch URLs (validated, rate-limited)
   - Parse HTML → readability text
   - Extract structured data → result.json
         │
6. ArtifactStore writes to ~/Documents/Ora Research/2026-01-31/task-abc123-swift-concurrency/
   Task state: running → succeeded
         │
7. SummaryGenerator queues LLM summarization (after current turn)
   Writes summary.md to artifact folder
         │
8. Notification: "✅ Research complete: Swift concurrency best practices"
   Actions: [Open in Ora] [Show in Finder]
         │
9. User: "What did you find about structured concurrency?"
   AgentLoop calls: research.load_result → injects summary into context
   LLM answers based on summarized research
```

### Task Lifecycle State Machine

```
              enqueue()
                │
                ▼
           ┌─────────┐
           │ queued   │
           └────┬─────┘
                │ worker available
                ▼
           ┌─────────┐   timeout / error
           │ running  │──────────────────┐
           └────┬─────┘                  │
                │ complete               │
                ▼                        ▼
           ┌─────────┐           ┌──────────┐
           │succeeded│           │  failed   │
           └─────────┘           └──────────┘
                                      ▲
           ┌─────────┐                │
           │canceled │◄───── user cancel / app quit
           └─────────┘
```

### Artifact Layout

```
~/Documents/Ora Research/
  └── 2026-01-31/
      └── task-abc123-swift-concurrency/
          ├── summary.md          (LLM-generated, human-readable)
          ├── result.json         (structured extraction data)
          ├── citations.json      (source URLs + titles)
          └── raw/                (optional: original fetched content)
              └── page-1.html
```

### Task Schema

```swift
@Model
final class BackgroundTask {
    var id: UUID
    var type: String                    // e.g., "web.research.fetch"
    var inputs: BackgroundTaskInputs    // URLs, query, etc.
    var policy: BackgroundTaskPolicy    // timeout, max_bytes, domain allowlist
    var state: BackgroundTaskState      // queued | running | succeeded | failed | canceled
    var artifactPath: String?           // ~/Documents/Ora Research/...
    var error: String?                  // failure reason if failed
    var createdAt: Date
    var startedAt: Date?
    var completedAt: Date?
    var sessionID: UUID?                // conversation session that triggered this
}
```

## 5. Implementation Plan (Draft)

### 5.1 Files to Create

This is a design-only story. No code files are created. Implementation is split across BG.01-BG.07.

### 5.2 Files to Modify

- None

### 5.3 Tests to Add

- None (design document)

### 5.4 Dependencies/Config

- None

## 6. Acceptance Criteria

- [ ] AC-1: Architecture diagram documents all component boundaries and data flow
- [ ] AC-2: UX flow covers trigger → queue → execute → notify → load lifecycle
- [ ] AC-3: Phased isolation strategy (Phase 1/2/3) is documented with clear scope per phase
- [ ] AC-4: Task state machine is fully specified with all transitions
- [ ] AC-5: Artifact layout and naming convention is defined
- [ ] AC-6: Integration points with existing pipeline (AgentLoop, ConversationManager, ToolRegistry) are identified
- [ ] AC-7: Non-goals are explicitly listed
- [ ] AC-8: Memory/resource considerations documented (impact on 16GB systems)

## 7. Verification Plan

### Automated Tests

- [ ] N/A — design document

### Manual Tests

- [ ] Review by project owner for architectural alignment
- [ ] Verify no conflicts with existing pipeline components

## 8. Performance / Reliability Considerations

- Background tasks must not degrade foreground conversation latency
- Workers should be cancelable within 1 second of user request or app quit
- Memory overhead of task queue + worker pool should stay under 100MB
- On 16GB systems (~7GB used by models), background tasks have ~2-3GB budget
- Summary generation must queue behind active conversation (GPU serialization via MLXMetalGate)

## 9. Risks & Mitigations

- **LLM prompt injection via fetched content** — Sanitize all content before LLM context injection; summarize through a controlled prompt, never inject raw HTML
- **Memory pressure from concurrent tasks + models** — Cap concurrent workers at 1-2; enforce response size limits (5MB)
- **User confusion about background behavior** — Clear notifications on start/complete; visible artifact folder; quit stops all tasks
- **Phase 1 in-process isolation is weaker** — Acceptable for HTTP fetch; escalate to XPC/Container for untrusted code in Phase 2/3

## 10. Open Questions

- Should background tasks be triggerable via voice only, or also via a menu/UI action?
- What is the maximum number of concurrent background tasks? (Proposed: 2)
- Should artifacts auto-delete after N days? (Proposed: 30 days, configurable)
- Should we support task retry on transient network failure? (Proposed: yes, max 2 retries)

---

## Implementation Summary

(TBD after implementation.)

## Code Review Findings

(TBD by review agent.)

## Completion Status

(TBD after merge.)
