# Background Tasks (BG)

Background execution for URL-based research in Ora.

## Overview

This epic adds a queue for explicit research jobs:

1. the user or agent provides one or more URLs
2. Ora fetches and cleans the content off the foreground path
3. Ora saves artifacts under `~/Documents/Ora Research/`
4. Ora generates a local summary when the foreground pipeline is idle
5. Ora can later list or load the saved result back into the agent loop

v1 is intentionally narrow. It does **not** include generic web search, browser automation, scheduling, or daemonized execution.

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

## Non-Goals

- Generic “research anything on the web” source discovery
- Browser automation / Playwright
- Background execution while Ora is closed
- Cron / scheduled tasks
- Cloud execution
