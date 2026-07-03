# BG.00 - Background Tasks Overview

**Epic:** Background Tasks
**Status:** Complete
**Priority:** P1 (High)
**Estimated Effort:** 1 day
**Dependencies:** None
**Target:** macOS 26 (Tahoe)

## Summary

Add a background-task subsystem that lets Ora fetch and summarize explicit user-provided URLs without blocking the foreground voice/text pipeline. v1 is intentionally narrow: enqueue a research job, run it off the conversational path, persist artifacts in a stable user-visible folder, optionally notify the user when it completes, and let the agent load the summarized result later.

This epic does **not** include open-ended web search, browser automation, scheduled jobs, or daemonized execution.

## Architecture Context and Reuse

- Foreground orchestration already lives in [AgentLoop.swift](/Users/bene/Dev-Source-NoBackup/ora/Ora/Orchestration/AgentLoop.swift) and [SimplePipelineController.swift](/Users/bene/Dev-Source-NoBackup/ora/Ora/Orchestration/SimplePipelineController.swift).
- Tool registration is centralized in [ToolRegistry.swift](/Users/bene/Dev-Source-NoBackup/ora/Ora/Tools/ToolRegistry.swift).
- SwiftData schema/container ownership lives in [PersistenceManager.swift](/Users/bene/Dev-Source-NoBackup/ora/Ora/Persistence/PersistenceManager.swift).
- GPU access is already serialized inside [LLMService.swift](/Users/bene/Dev-Source-NoBackup/ora/Ora/LLM/LLMService.swift) via [MLXMetalGate.swift](/Users/bene/Dev-Source-NoBackup/ora/Ora/LLM/MLXMetalGate.swift).
- Notification authorization already has a lightweight in-app pattern in [ModelMigrationCoordinator.swift](/Users/bene/Dev-Source-NoBackup/ora/Ora/Models/ModelMigrationCoordinator.swift).

## Resolved v1 Decisions

- `research.start` works on explicit `urls`; it does not discover sources from a freeform query.
- Background jobs are persisted for auditability and later retrieval, but unfinished jobs are **not resumed** after relaunch.
- Artifacts are stored under `~/Documents/Ora Research/`.
- Summary generation uses the **local** runtime only and never routes fetched content through a cloud provider.
- Notification default click activates Ora; the explicit action button for v1 is `Show in Finder`.

## System Shape

```text
User turn
  -> AgentLoop
  -> research.start
  -> BackgroundTaskManager.enqueue()
  -> URLSessionWorker + safety policy
  -> ArtifactStore.save()
  -> SummaryGenerator.enqueue()
  -> optional local notification
  -> research.list_results / research.load_result in a later turn
```

## Lifecycle

```text
queued -> running -> succeeded
queued -> running -> failed
queued -> canceled
running -> canceled

launch reconciliation:
queued/running from a previous app run -> canceled
```

## Story Breakdown

- [BG.01](BG.01-TASK-QUEUE.md): task model, queue manager, lifecycle, launch reconciliation
- [BG.02](BG.02-WORKER-ABSTRACTION.md): in-process worker and HTML text extraction
- [BG.03](BG.03-NETWORK-SAFETY.md): SSRF/IP/scheme/content-type/size protections
- [BG.04](BG.04-ARTIFACT-PERSISTENCE.md): deterministic artifact storage and Finder reveal
- [BG.05](BG.05-SUMMARY-GENERATION.md): local summarization queue, sanitization, foreground-aware cancellation
- [BG.06](BG.06-NOTIFICATIONS.md): local notifications for completion/failure
- [BG.07](BG.07-CONTEXT-LOADING.md): research tools for listing/loading results into the agent loop

## Privacy Posture Change (IMPORTANT)

This epic introduces Ora's **first outbound network connections to arbitrary third-party servers**. While the user explicitly provides URLs, this fundamentally changes Ora's privacy posture from "nothing leaves the device" to "user-directed content is fetched." Mitigations:

- Set a generic or empty `User-Agent` header (do not identify Ora).
- Disable `Referer` headers between multi-URL fetches.
- Use ephemeral `URLSession` per task (no cookie/credential persistence).
- Consider a first-use disclosure when `research.start` is invoked for the first time.
- Document that HTTP requests inherently expose the user's IP to the target server.

## Data Flow Between Stories

```text
research.start (BG.07)
  → BackgroundTaskManager.enqueue() (BG.01)
  → URLSessionWorker.execute() (BG.02) via SafeURLSession (BG.03)
  → returns WorkerResult (shared type: BG.02)
  → ArtifactStore.save(task:workerResult:) (BG.04)
  → SummaryGenerator.enqueue(taskID:) (BG.05) reads from result.json artifact
  → TaskNotificationService.postCompletion() (BG.06)
  → research.load_result reads summary.md + result.json (BG.07)
```

`WorkerResult` is the single data type flowing from BG.02 through BG.04 to BG.05. BG.05 reads from the persisted `result.json` artifact, not from in-memory `WorkerResult`.

## Entitlements (Future Sandboxing)

When Ora adopts App Sandbox, this epic will require:
- `com.apple.security.network.client` — outbound HTTP/HTTPS
- `com.apple.security.files.user-selected.read-write` or `com.apple.security.files.downloads.read-write` — artifact storage in `~/Documents/Ora Research/`

## Non-Goals

- Generic internet research without user-provided URLs
- Browser automation / Playwright
- Arbitrary code execution
- Daemon or login-item execution while Ora is closed
- Cron/scheduled tasks
- Cloud-hosted execution

## Acceptance Criteria

- [x] Epic framing is aligned with the current Ora architecture and file layout.
- [x] v1 scope is explicit about URL-based research only.
- [x] Lifecycle, persistence behavior, artifact root, and notification semantics are unambiguous.
- [x] Downstream stories can be implemented without inventing missing architecture.

## Risks

- Narrow v1 scope is less magical than “research anything,” but it is buildable now and composes cleanly with Ora’s existing agent loop.
- Future phases can add source discovery or stronger isolation without invalidating the v1 queue/artifact interfaces.
- **Privacy posture change:** See dedicated section above. This is Ora’s first network-initiating feature and must be communicated clearly.
