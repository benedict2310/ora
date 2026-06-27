# BG.09 - Container Runtime

**Epic:** Background Tasks
**Status:** 🚧 To Do
**Priority:** P1 (High)
**Estimated Effort:** 5 days
**Dependencies:** BG.02
**Target:** macOS 26 (Tahoe)

## Summary

Add a container-based worker backend so background research tasks run inside an isolated Linux environment instead of in-process. The production implementation uses Apple's Containerization stack on macOS 26, but the host-side integration is hidden behind a `ContainerRuntime` protocol so tests can inject mocks and the app is not hard-wired to one runtime implementation. The container has public-internet access but no access to the user's filesystem, local network, credentials, or applications. This isolation boundary becomes the primary security model for autonomous topic research.

The existing `BackgroundWorker` protocol stays intact. This story adds `ContainerWorker` as a second conformance alongside the existing `URLSessionWorker`. `BackgroundTaskManager` gains the ability to dispatch tasks to either backend. The in-process worker remains available as a fallback when the container runtime is unavailable.

## Why This Matters

BG.01–BG.08 built a solid task queue, artifact pipeline, and UI. But the product shape is wrong: users must paste URLs manually because Ora's safety model is host-side URL validation. Moving execution into an isolated container shifts the security boundary from "validate every URL" to "the container can't touch anything it shouldn't." This unlocks a single-approval UX where the user says "research X" and Ora handles the rest autonomously.

## Verification Notes

- The existing `BackgroundWorker` protocol in [BackgroundWorker.swift](/Users/bene/Dev-Source-NoBackup/ora/Ora/BackgroundTasks/Workers/BackgroundWorker.swift) already defines the pluggable worker contract. `ContainerWorker` is a new conformance.
- `BackgroundTaskManager` in [BackgroundTaskManager.swift](/Users/bene/Dev-Source-NoBackup/ora/Ora/BackgroundTasks/BackgroundTaskManager.swift) currently owns a single configured worker. This story must add real per-task backend selection rather than only swapping the global worker at configuration time.
- Production runtime is Apple's Containerization stack on macOS 26. The Swift integration should be written against a local `ContainerRuntime` protocol, with `ContainerizationRuntime` as the production implementation.

## Architecture Context and Reuse Guidance

- **Reuse** the existing `BackgroundWorker` protocol. `ContainerWorker` conforms to it and returns `WorkerResult`, but `WorkerResult`, artifact persistence, and task inputs must be extended so query/provenance data survives the pipeline.
- **Reuse** `BackgroundTaskInputs` for passing the research request into the container. Extend it with a `query` field (see BG.10) so the container agent can receive freeform research queries.
- **Reuse** `ArtifactStore` (BG.04) for persisting results returned from the container.
- **Do not** expose container lifecycle details to the tool layer or the agent loop. From the LLM's perspective, `research.start` enqueues a task — the worker backend is an implementation detail.
- **Do not** give the container access to the host filesystem or local network. The only data that crosses the boundary is `input.json` and `output.json`.
- **Keep** host-side validation for explicit user-provided `urls`. Autonomous discovery for `query` happens inside the isolated container, but if the host can see a URL before enqueue, it should validate it before handing it to the runtime.

## Isolation Model

```
┌─────────────────────────────────────────────────────────┐
│  Host (Ora.app)                                         │
│                                                         │
│  BackgroundTaskManager                                  │
│    ├─ URLSessionWorker (in-process, existing)           │
│    └─ ContainerWorker (new)                             │
│         │                                               │
│         │  input: { query, constraints }                │
│         │  output: { pages, metadata, citations }       │
│         ▼                                               │
│  ┌────────────────────────────────────┐                 │
│  │  Linux Container (isolated)        │                 │
│  │                                    │                 │
│  │  ✅ Internet access (public web)   │                 │
│  │  ✅ Search engines                 │                 │
│  │  ✅ Page fetching & extraction     │                 │
│  │  ✅ Link following within budget   │                 │
│  │                                    │                 │
│  │  ❌ Host filesystem                │                 │
│  │  ❌ Host local network / RFC1918   │                 │
│  │  ❌ User credentials / cookies     │                 │
│  │  ❌ Other apps / system services   │                 │
│  │  ❌ Persistent state across tasks  │                 │
│  └────────────────────────────────────┘                 │
└─────────────────────────────────────────────────────────┘
```

## Resolved Decisions

- Production runtime is Apple's Containerization stack on macOS 26. The app talks to it through a `ContainerRuntime` protocol, with `ContainerizationRuntime` as the production implementation. If unavailable, fall back to `URLSessionWorker` with a user-visible notice.
- Each task gets a **fresh container instance** (or a clean snapshot restore). No state carries between tasks — this prevents data leakage and makes execution reproducible.
- Container networking: public internet only. Use host-enforced runtime/network configuration where the Containerization stack supports it; do not rely on in-container firewall rules as the sole boundary. Host-side URL validation remains in place for explicit `urls` as defense in depth.
- Host↔container communication uses a **shared directory** mounted read-write. The host writes a single `input.json` before task start and reads a single `output.json` after task completion. No network server on either side. The container does not write arbitrary artifact files into the shared directory.
- Container image is a minimal Linux base with Python 3 + `requests` + `beautifulsoup4` + a lightweight research agent script. No headless browser in v1.
- Container timeout: inherits `BackgroundTaskPolicy.timeoutSeconds` (default 120s, max 300s). The host kills the container if it exceeds the timeout.
- Image distribution: ship the image or image assets inside the signed app bundle only. No first-use runtime download.
- Container startup target: < 3 seconds. If cold start is materially slower, add a pre-warmed runtime/cache as an optimization, but do not change the one-task-one-container isolation model.

## File Touch List

- `Ora/BackgroundTasks/Container/ContainerWorker.swift`
  Purpose: `BackgroundWorker` conformance that dispatches tasks to an isolated container and collects results.

- `Ora/BackgroundTasks/Container/ContainerRuntime.swift`
  Purpose: protocol defining the runtime contract (`prepare`, `start`, `stop`, `kill`, `isAvailable`) used by `ContainerWorker` and tests.

- `Ora/BackgroundTasks/Container/ContainerizationRuntime.swift`
  Purpose: production implementation backed by Apple's Containerization stack on macOS 26.

- `Ora/BackgroundTasks/Container/ContainerConfiguration.swift`
  Purpose: codable container config (image path, memory limit, network policy, timeout, shared directory path).

- `Ora/BackgroundTasks/Container/ContainerNetworkPolicy.swift`
  Purpose: host-side runtime/network policy model for the Containerization implementation.

- `Ora/BackgroundTasks/Container/ContainerImageManager.swift`
  Purpose: locate and validate the bundled container image/assets shipped inside the app. No runtime download path.

- `Ora/BackgroundTasks/Container/ContainerIO.swift`
  Purpose: serialize `input.json` into the shared directory, deserialize `output.json` after completion, enforce single-file I/O boundaries, and validate output size/structure before the host writes artifacts.

- `Ora/BackgroundTasks/BackgroundTaskManager.swift`
  Purpose: add worker selection logic — use `ContainerWorker` when available, fall back to `URLSessionWorker`.

- `Ora/BackgroundTasks/BackgroundTaskPolicy.swift`
  Purpose: add `workerBackend` field (`.auto`, `.container`, `.inProcess`) so policy can express a preference.

- `Ora/BackgroundTasks/BackgroundTaskInputs.swift`
  Purpose: add optional `query: String?` field for freeform research requests (used by the container agent, ignored by `URLSessionWorker`).

- `Ora/BackgroundTasks/Workers/WorkerResult.swift`
  Purpose: extend worker output to carry optional query/provenance fields from the container worker.

- `Ora/BackgroundTasks/Artifacts/ArtifactManifest.swift`
  Purpose: add compact query/provenance rollups to `manifest.json` and full provenance to `result.json`.

- `Ora/BackgroundTasks/Artifacts/ArtifactStore.swift`
  Purpose: persist host-written artifacts from validated `output.json`, not container-written files.

- `Ora/UI/TaskProgress/TaskProgressObserver.swift`
  Purpose: keep the existing `queued -> fetching -> summarizing` state model while allowing query-based tasks to render `Researching` in the display layer.

- `OraTests/BackgroundTasks/ContainerWorkerTests.swift`
  Purpose: integration tests with mock container runtime.

- `OraTests/BackgroundTasks/ContainerIOTests.swift`
  Purpose: input/output serialization, size validation, malformed output handling.

## Container Agent (In-Container Software)

The research agent that runs inside the container is a self-contained Python script. It is NOT part of the Swift codebase. It lives at:

- `Container/research-agent/agent.py` — main entry point
- `Container/research-agent/requirements.txt` — pinned dependencies
- `Container/Containerfile` — image build definition

The agent receives `input.json` from the shared directory and writes a single `output.json` back to the same directory. The host validates that output, then writes artifacts through the existing `ArtifactStore`.

### Input Contract

```json
{
  "task_id": "uuid",
  "query": "latest Nvidia Blackwell server rollout",
  "constraints": {
    "max_search_queries": 5,
    "max_pages": 15,
    "max_domains": 8,
    "max_page_size_bytes": 5242880,
    "timeout_seconds": 120
  },
  "urls": ["https://example.com/optional-explicit-url"]
}
```

Either `query` or `urls` (or both) must be provided. If `query` is present, the agent performs source discovery. If only `urls` is present, the agent fetches those URLs directly (backward-compatible with BG.07 behavior).

### Output Contract

```json
{
  "task_id": "uuid",
  "status": "completed",
  "query": "latest Nvidia Blackwell server rollout",
  "pages": [
    {
      "url": "https://...",
      "final_url": "https://...",
      "title": "Page Title",
      "text": "Extracted text content...",
      "content_type": "text/html",
      "word_count": 1234,
      "fetched_at": "2026-03-16T10:00:00Z"
    }
  ],
  "metadata": {
    "started_at": "2026-03-16T10:00:00Z",
    "completed_at": "2026-03-16T10:01:30Z",
    "search_queries_used": ["nvidia blackwell server", "blackwell GB200 rollout 2026"],
    "requested_url_count": 8,
    "succeeded_url_count": 6,
    "failed_url_count": 2
  },
  "failed_urls": [
    {
      "url": "https://...",
      "code": "fetch_failed",
      "message": "Connection timeout"
    }
  ],
  "provenance": {
    "search_queries": ["nvidia blackwell server", "blackwell GB200 rollout 2026"],
    "discovery_rationale": "Selected sources covering official announcements, technical analysis, and supply chain reporting.",
    "domains_used": ["nvidia.com", "anandtech.com", "tomshardware.com"]
  }
}
```

The host-side `ContainerIO` maps this output into an extended `WorkerResult` carrying optional query/provenance fields. `ArtifactStore` then persists the validated result into the existing host-controlled artifact layout.

### Agent Behavior

1. Read `input.json` from the working directory.
2. If `query` is present: perform web search (DuckDuckGo HTML Lite or similar no-auth search), discover sources, rank by relevance and diversity.
3. If `urls` are present: fetch those URLs directly.
4. For each selected source: fetch, extract text, record metadata.
5. Respect all constraints (max pages, max domains, timeout).
6. Write `output.json` to the working directory.
7. Exit with code 0 on success, non-zero on fatal error.

The agent is autonomous inside the container. It does not call back to the host for approval at any point. It follows links, expands queries, and makes its own decisions within the configured budget.

## Implementation Steps

1. **Define `ContainerConfiguration`.**
   Fields:
   - `imagePath: URL`
   - `memoryLimitMB: Int` (default: 512)
   - `cpuCount: Int` (default: 2)
   - `networkPolicy: ContainerNetworkPolicy`
   - `sharedDirectoryPath: URL`
   - `timeoutSeconds: Int`

2. **Define `ContainerNetworkPolicy`.**
   Requirements:
   - Model the host-side network restrictions the Containerization-backed runtime will apply
   - Preserve explicit host-side URL validation for user-provided `urls`
   - Do not rely on in-container firewall rules as the sole boundary

3. **Implement `ContainerRuntime`.**
   Lifecycle:
   - `prepare()` — verify image exists, pre-warm one container instance
   - `start(configuration:) -> ContainerHandle` — create and start a container
   - `stop(handle:)` — graceful shutdown
   - `kill(handle:)` — forced termination (for timeout)
   - `isAvailable: Bool` — runtime availability check

   Define this as a protocol. Implement `ContainerizationRuntime` as the production backend using Apple's Containerization stack. Gate behind `#available(macOS 26, *)`.

4. **Implement `ContainerIO`.**
   Responsibilities:
   - Write `input.json` to the shared directory before container start.
   - After container exit, read `output.json` from the shared directory.
   - Validate output: max size (10 MB), valid JSON, required fields present, and no unexpected file system objects in the shared directory.
   - Reject symlinks, hardlinks, device nodes, or extra files in the shared directory.
   - Map output JSON → extended `WorkerResult`.
   - Clean up the shared directory after result extraction.
   - On container non-zero exit or timeout: return a `WorkerError` with the container's stderr if available.

5. **Implement `ContainerWorker`.**
   Flow:
   ```
   execute(taskID, input, policy) -> WorkerResult
     1. Create temp shared directory
     2. Write input.json via ContainerIO
     3. Start container via ContainerRuntime
     4. Wait for container exit (with timeout)
     5. Read output.json via ContainerIO
     6. Map to WorkerResult
     7. Clean up shared directory
     8. Return result
   ```
   Cancellation: if the Swift `Task` is cancelled, kill the container immediately.

6. **Implement `ContainerImageManager`.**
   Responsibilities:
   - Check for bundled image/assets in app resources
   - Validate image integrity (checksum/signature metadata as applicable)
   - Surface a clear error when the bundled runtime assets are missing or invalid
   - No runtime download path

7. **Extend `BackgroundTaskPolicy`.**
   Add:
   ```swift
   enum WorkerBackend: String, Codable, Sendable {
       case auto       // Use container if available, else in-process
       case container  // Require container; fail if unavailable
       case inProcess  // Force in-process (existing behavior)
   }
   ```
   Default: `.auto`

8. **Extend `BackgroundTaskInputs`.**
   Add:
   ```swift
   let query: String?  // Freeform research query for the container agent
   ```
   When `query` is present, the container agent performs source discovery. When only `urls` are present, it fetches directly (backward-compatible).

9. **Update `BackgroundTaskManager` worker selection.**
   ```swift
   private func selectWorker(policy: BackgroundTaskPolicy) -> any BackgroundWorker {
       switch policy.workerBackend {
       case .auto:
           return containerRuntime.isAvailable ? containerWorker : urlSessionWorker
       case .container:
           guard containerRuntime.isAvailable else {
               // Fail the task with a descriptive error
           }
           return containerWorker
       case .inProcess:
           return urlSessionWorker
       }
   }
   ```
   Current architecture owns a single configured worker. Update the manager to own both backends and select per task, while keeping test injection possible.

10. **Update persisted schemas.**
    - Extend `BackgroundTaskInputs` with `query: String?`
    - Extend `BackgroundTaskPolicy` with `workerBackend`
    - Extend `WorkerResult` / `WorkerMetadata` with optional query/provenance fields
    - Extend artifact persistence so `manifest.json` stores compact query/provenance rollups and `result.json` stores the full provenance block
    - Preserve backward compatibility with existing persisted `BackgroundTaskRecord` instances by using optional fields and defaults

11. **Build the container image.**
    Create `Container/Containerfile`:
    ```dockerfile
    FROM python:3.12-slim
    WORKDIR /task
    COPY research-agent/ /agent/
    RUN pip install --no-cache-dir -r /agent/requirements.txt
    ENTRYPOINT ["python", "/agent/agent.py"]
    ```

12. **Write the container research agent.**
    `Container/research-agent/agent.py`:
    - DuckDuckGo HTML Lite search (no API key, no JS)
    - `requests` + `beautifulsoup4` for fetching and extraction
    - Budget enforcement (max queries, max pages, max domains, timeout)
    - JSON input/output via files in the working directory
    - Self-contained — no dependencies on the host
    - Writes one `output.json` only

## Tests and Validation

### Unit Tests

- `test_containerIO_writesValidInputJSON`
- `test_containerIO_readsValidOutputJSON`
- `test_containerIO_rejectsOversizedOutput`
- `test_containerIO_rejectsMalformedOutput`
- `test_containerIO_mapsOutputToWorkerResult`
- `test_containerWorker_returnsResultOnSuccess`
- `test_containerWorker_failsOnContainerTimeout`
- `test_containerWorker_failsOnNonZeroExit`
- `test_containerWorker_cancellationKillsContainer`
- `test_containerWorker_cleansUpSharedDirectory`
- `test_workerSelection_prefersContainerWhenAvailable`
- `test_workerSelection_fallsBackToInProcessWhenUnavailable`
- `test_workerSelection_failsWhenContainerRequiredButUnavailable`
- `test_containerizationRuntime_reportsAvailability`
- `test_containerNetworkPolicy_modelsHostRestrictions`
- `test_containerImageManager_validatesChecksum`
- `test_taskInputs_supportsQueryField`
- `test_taskPolicy_supportsWorkerBackendField`
- `test_taskPolicy_backwardCompatibleWithExistingRecords`
- `test_workerResult_supportsOptionalProvenance`
- `test_artifactStore_persistsProvenanceInResultJSON`
- `test_artifactStore_manifestIncludesCompactProvenanceSummary`

### Integration Tests (require container runtime)

- `test_integration_containerResearchesQueryAndReturnsResult`
- `test_integration_containerFetchesExplicitURLs`
- `test_integration_containerRespectsTimeout`
- `test_integration_endToEndArtifactPersistence`

### Manual Validation

- Ask Ora to research a topic. Confirm the task runs in a container (check logs for container lifecycle events).
- Confirm the container has no access to the host filesystem (attempt to read `/Users/` from inside — should fail).
- Confirm artifacts appear in `~/Documents/Ora Research/` as before.
- Confirm the existing in-process worker still works when container runtime is unavailable.
- Confirm query-based tasks render `Researching` in the UI while URL-based tasks still render URL-oriented progress text.

## Acceptance Criteria

- [ ] `ContainerWorker` conforms to `BackgroundWorker` and returns `WorkerResult`.
- [ ] The downstream pipeline (artifacts, summaries, notifications, UI) works regardless of which worker backend was used.
- [ ] Each task runs in a fresh container instance with no state carried from previous tasks.
- [ ] Production runtime uses Apple's Containerization stack through a protocol-backed `ContainerRuntime` integration.
- [ ] The container has no access to the host filesystem, credentials, or applications.
- [ ] Host↔container data exchange uses a shared directory with exactly one `input.json` and one `output.json`.
- [ ] Container output is validated for size, format, and required fields before being accepted.
- [ ] The host rejects unexpected files or unsafe file system objects in the shared directory.
- [ ] Task timeout kills the container and returns a descriptive error.
- [ ] `BackgroundTaskManager` selects the worker backend based on `BackgroundTaskPolicy.workerBackend`.
- [ ] Falls back to in-process worker when container runtime is unavailable with a user-visible notice.
- [ ] Container image/assets ship inside the signed app bundle; no runtime download is performed.
- [ ] `BackgroundTaskInputs` supports a `query` field for freeform research.
- [ ] Explicit user-provided `urls` are still validated on the host before being passed to the container runtime.
- [ ] Provenance is persisted long-term: compact summary in `manifest.json`, full detail in `result.json`.

## Risks and Open Questions

- **Apple Containerization network controls:** Prototype the exact host-enforced network restrictions early. Keep explicit URL validation on the host even after the container backend lands.
- **Bundled image size:** Shipping the image/assets inside the app bundle is a deliberate product/security choice. If size becomes painful, shrink the image; do not add first-use downloads.
- **Container startup latency:** Target < 3 seconds. If cold start is > 5 seconds, add runtime pre-warming as an optimization.
- **Search engine rate limiting:** The in-container agent uses DuckDuckGo HTML Lite. If DDG blocks automated requests, the agent needs a fallback search provider or a different approach. The agent's search strategy is decoupled from the host, so swapping it is a container-image update, not a Swift code change.
- **Output trust:** Even though the container is isolated, its output is consumed by the host LLM for summarization. Malicious web content could attempt prompt injection through the extracted text. The existing sanitizer path from BG.05 still applies to container output and remains required.
- **Backward compatibility:** Adding optional fields to `BackgroundTaskInputs` and `BackgroundTaskPolicy` must not break existing persisted `BackgroundTaskRecord` instances. Use optional fields with defaults.
