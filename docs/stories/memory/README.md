# Memory System (MEM)

> Persistent conversation history, user-visible memory artifacts, and implicit retrieval for Ora.

## Objective

Give Ora long-term memory so conversations survive restarts, users can inspect/edit what Ora remembers, and relevant context is retrieved automatically when needed.

## Sub-Epics

### MEM.01 — Persist Full Transcript (Critical Gap)
Close the gap between in-memory `ConversationManager` and SwiftData `Session`. Every message must survive app restart/crash.

| ID | Title | Status | Deps |
|:---|:------|:-------|:-----|
| MEM.01 | [Conversation Persistence Sink](MEM.01-CONVERSATION-PERSISTENCE-SINK.md) | Not Started | F.08 |
| MEM.02 | [AgentLoop Persistence Integration](MEM.02-AGENTLOOP-PERSISTENCE-INTEGRATION.md) | Not Started | MEM.01 |
| MEM.03 | [Tool Result Persistence](MEM.03-TOOL-RESULT-PERSISTENCE.md) | Not Started | MEM.01 |

### MEM.02 — Reduce UI Hitching
Debounce/batch SwiftData saves to minimize main-actor blocking.

| ID | Title | Status | Deps |
|:---|:------|:-------|:-----|
| MEM.04 | [Debounced Save Scheduler](MEM.04-DEBOUNCED-SAVE-SCHEDULER.md) | Not Started | MEM.01 |
| MEM.05 | [Persistence Performance Guardrail](MEM.05-PERSISTENCE-PERFORMANCE-GUARDRAIL.md) | Not Started | MEM.04 |

### MEM.03 — User-Visible Memory Artifacts
Create human-editable long-term memory and per-session summaries on disk.

| ID | Title | Status | Deps |
|:---|:------|:-------|:-----|
| MEM.06 | [On-Disk Memory Folder](MEM.06-ON-DISK-MEMORY-FOLDER.md) | Not Started | MEM.01 |
| MEM.07 | [Summary Template](MEM.07-SUMMARY-TEMPLATE.md) | Not Started | MEM.06 |

### MEM.04 — Auto-Distill Memory
Extract facts/preferences from sessions and update MEMORY.md + session summaries using the local model.

| ID | Title | Status | Deps |
|:---|:------|:-------|:-----|
| MEM.08 | [Memory Distiller Pipeline](MEM.08-MEMORY-DISTILLER-PIPELINE.md) | Not Started | MEM.01, MEM.06, MEM.07 |
| MEM.09 | [Memory Update Policy](MEM.09-MEMORY-UPDATE-POLICY.md) | Not Started | MEM.08 |

### MEM.05 — Retrieval
Implicit retrieval: summaries + MEMORY.md first, transcript fallback.

| ID | Title | Status | Deps |
|:---|:------|:-------|:-----|
| MEM.10 | [Memory Trigger Detector](MEM.10-MEMORY-TRIGGER-DETECTOR.md) | Not Started | MEM.06 |
| MEM.11 | [Keyword Retrieval Index](MEM.11-KEYWORD-RETRIEVAL-INDEX.md) | Not Started | MEM.06, MEM.10 |
| MEM.12 | [Embedding Hybrid Retrieval](MEM.12-EMBEDDING-HYBRID-RETRIEVAL.md) | Not Started | MEM.11 |
| MEM.13 | [Transcript Fallback Retrieval](MEM.13-TRANSCRIPT-FALLBACK-RETRIEVAL.md) | Not Started | MEM.11 |

### MEM.06 — Memory Management UX
User can view/edit MEMORY.md and Ora respects changes.

| ID | Title | Status | Deps |
|:---|:------|:-------|:-----|
| MEM.14 | [MEMORY.md File Watcher](MEM.14-MEMORY-FILE-WATCHER.md) | Not Started | MEM.06, MEM.11 |
| MEM.15 | [Memory Manager Panel](MEM.15-MEMORY-MANAGER-PANEL.md) | Not Started | MEM.06 |

### MEM.07 — Future Hardening (Post-v1)
Performance and scalability improvements.

| ID | Title | Status | Deps |
|:---|:------|:-------|:-----|
| MEM.16 | [Background Persistence ModelActor](MEM.16-BACKGROUND-PERSISTENCE-MODELACTOR.md) | Future | MEM.04 |
| MEM.17 | [Transcript Storage Migration](MEM.17-TRANSCRIPT-STORAGE-MIGRATION.md) | Future | MEM.01 |

## Implementation Order

```
Phase 1: Transcript Persistence (MEM.01 → MEM.02 → MEM.03 → MEM.04 → MEM.05)
Phase 2: Memory Artifacts (MEM.06 → MEM.07)
Phase 3: Auto-Distill (MEM.08 → MEM.09)
Phase 4: Retrieval (MEM.10 → MEM.11 → MEM.12/MEM.13)
Phase 5: UX (MEM.14, MEM.15)
Future: Hardening (MEM.16, MEM.17)
```

## Dependency Graph

```
F.08 (Persistence Layer) ✅
 │
 ▼
MEM.01 (Persistence Sink)
 │
 ├─► MEM.02 (AgentLoop Integration)
 ├─► MEM.03 (Tool Result Persistence)
 ├─► MEM.04 (Debounced Saves) ──► MEM.05 (Perf Guardrail)
 ├─► MEM.06 (On-Disk Memory) ──► MEM.07 (Summary Template)
 │    │                            │
 │    ├─► MEM.10 (Trigger Detector)│
 │    │    │                       │
 │    │    ▼                       │
 │    ├─► MEM.11 (Keyword Index) ◄─┘
 │    │    │
 │    │    ├─► MEM.12 (Embeddings)
 │    │    ├─► MEM.13 (Transcript Fallback)
 │    │    └─► MEM.14 (File Watcher)
 │    │
 │    └─► MEM.15 (Memory Panel)
 │
 ├─► MEM.08 (Distiller) ──► MEM.09 (Update Policy)
 ├─► MEM.16 (Background ModelActor) [Future]
 └─► MEM.17 (Storage Migration) [Future]
```
