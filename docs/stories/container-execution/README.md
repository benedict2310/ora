# Background Tasks (BG)

Safe, containerized background task execution for Ora.

## Overview

Enable Ora to execute autonomous background tasks (initially HTTP fetch + parsing) while providing a high-quality user experience with notifications, persistent artifacts, and conversation integration.

**Phased Isolation Strategy:**

| Phase | Isolation | Scope | Status |
|:------|:----------|:------|:-------|
| **Phase 1** | In-process `URLSession` + sandboxed parsing | HTTP fetch, readability extraction | 🚧 To Do |
| **Phase 2** | XPC Service with App Sandbox profile | Untrusted content parsing, PDF extraction | 📋 Future |
| **Phase 3** | Apple Container (Linux VM) | Arbitrary code execution, browser automation | 📋 Future |

## Stories

| ID | Title | Status | Dependencies |
|:---|:------|:-------|:-------------|
| BG.00 | [Background Tasks Overview](BG.00-BACKGROUND-TASKS-OVERVIEW.md) | 🚧 To Do | None |
| BG.01 | [Task Queue](BG.01-TASK-QUEUE.md) | 🚧 To Do | None |
| BG.02 | [Worker Abstraction](BG.02-WORKER-ABSTRACTION.md) | 🚧 To Do | BG.01 |
| BG.03 | [Network Safety Policy](BG.03-NETWORK-SAFETY.md) | 🚧 To Do | BG.02 |
| BG.04 | [Artifact Persistence](BG.04-ARTIFACT-PERSISTENCE.md) | 🚧 To Do | BG.01 |
| BG.05 | [Summary Generation](BG.05-SUMMARY-GENERATION.md) | 🚧 To Do | BG.02, BG.04 |
| BG.06 | [Local Notifications](BG.06-NOTIFICATIONS.md) | 🚧 To Do | BG.01 |
| BG.07 | [Context Loading](BG.07-CONTEXT-LOADING.md) | 🚧 To Do | BG.04, BG.05 |

## Dependency Graph

```
BG.00 (Overview / UX Flow)
  │
  ├── BG.01 (Task Queue) ─────────────────┐
  │     │                                  │
  │     ├── BG.02 (Worker Abstraction)     ├── BG.04 (Artifact Persistence)
  │     │     │                            │     │
  │     │     └── BG.03 (Network Safety)   │     │
  │     │                                  │     │
  │     └── BG.06 (Notifications)          │     │
  │                                        │     │
  └────────────────────────────────────────┘     │
                                                 │
              BG.05 (Summary Generation) ◄───────┘
                │
                └── BG.07 (Context Loading)
```

## Implementation Order

1. **BG.00** - Define UX flow and architecture (design only)
2. **BG.01** - Task queue infrastructure
3. **BG.02 + BG.04** - Worker runtime + artifact storage (parallel)
4. **BG.03** - Network safety layer
5. **BG.06** - Notifications
6. **BG.05** - Summary generation
7. **BG.07** - Context loading into conversation

## Non-Goals (v1)

- No daemon / login item background helper
- No browser automation (HTTP + parsing only)
- No cloud execution
- No task scheduling / cron
- Tasks do not survive app restarts (v1)
