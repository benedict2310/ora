# Background Tasks (BG)

Background execution for research in Ora.

## Overview

The initial epic shipped a queue for explicit URL-based research jobs:

1. the user or agent provides one or more URLs
2. Ora fetches and cleans the content off the foreground path
3. Ora saves artifacts under `~/Documents/Ora Research/`
4. Ora generates a local summary when the foreground pipeline is idle
5. Ora can later list or load the saved result back into the agent loop

Follow-on stories now extend that foundation with container-based isolation and autonomous research.

## Architecture Shift: Container-First

BG.01–BG.08 used an in-process worker with host-side URL validation (`SafeURLSession`, `URLSafetyValidator`) as the primary security boundary. This required per-URL approval dialogs and manual URL entry.

BG.09–BG.10 move the security boundary to a container. The research agent runs inside an isolated Linux container with internet access but no access to the host filesystem, local network, or credentials. This enables a single-approval UX: the user says "research X" and the container agent handles everything autonomously.

The in-process worker and host-side safety layer remain as a fallback for systems without container support, and as defense-in-depth inside the container.

## Stories

| ID | Title | Status | Dependencies |
|:---|:------|:-------|:-------------|
| BG.00 | [Background Tasks Overview](BG.00-BACKGROUND-TASKS-OVERVIEW.md) | ✅ Complete | None |
| BG.01 | [Task Queue](BG.01-TASK-QUEUE.md) | ✅ Complete | BG.00 |
| BG.02 | [Worker Abstraction](BG.02-WORKER-ABSTRACTION.md) | ✅ Complete | BG.01 |
| BG.03 | [Network Safety Policy](BG.03-NETWORK-SAFETY.md) | ✅ Complete | BG.02 |
| BG.04 | [Artifact Persistence](BG.04-ARTIFACT-PERSISTENCE.md) | ✅ Complete | BG.01 |
| BG.05 | [Summary Generation](BG.05-SUMMARY-GENERATION.md) | ✅ Complete | BG.02, BG.04 |
| BG.06 | [Local Notifications](BG.06-NOTIFICATIONS.md) | ✅ Complete | BG.01, BG.04, BG.05 |
| BG.07 | [Context Loading](BG.07-CONTEXT-LOADING.md) | ✅ Complete | BG.01, BG.04, BG.05 |
| BG.08 | [Task Progress UI](BG.08-TASK-PROGRESS-UI.md) | ✅ Complete | BG.01, BG.06 |
| BG.09 | [Container Runtime](BG.09-CONTAINER-RUNTIME.md) | 🚧 To Do | BG.02 |
| BG.10 | [Autonomous Research](BG.10-AUTONOMOUS-RESEARCH.md) | 🚧 To Do | BG.09 |

Verification note: 2026-03-16 review, fix pass, and BG.08 implementation confirmed BG.01-BG.08 are implemented. Focused BG.08/UI tests passed `55/55`.

## Recommended Implementation Order

1. `BG.01` task queue and launch reconciliation
2. `BG.04` artifact persistence  } can be parallelized
3. `BG.02` worker abstraction     } with BG.04 (both depend only on BG.01)
4. `BG.03` network safety wrapper (depends on BG.02, but validation logic can be built alongside BG.04)
5. `BG.05` local summary generation
6. `BG.06` local notifications
7. `BG.07` research tools and context loading
8. `BG.08` task progress UI
9. **`BG.09` container runtime** — the isolation layer; prototype Virtualization.framework first
10. **`BG.10` autonomous research** — query-based UX on top of container worker

## Future Stories

| ID | Title | Description |
|:---|:------|:------------|
| BG.11 | Research Task Browser | Full UI for inspecting plans, sources, provenance, artifacts, and reruns |
| BG.12 | Research Constraints | User-configurable research preferences (source types, domain filters, depth) |
| BG.13 | Browser-Backed Retrieval | Headless browser inside the container for JS-heavy sites |

## Current Non-Goals

- Browser automation / Playwright (future BG.13)
- Background execution while Ora is closed
- Cron / scheduled tasks
- Cloud execution
- Per-URL approval dialogs or autonomy mode selection (replaced by container isolation)
