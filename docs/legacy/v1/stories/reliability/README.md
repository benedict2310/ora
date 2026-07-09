# Reliability Epic

Error handling, recovery, and graceful degradation for a robust voice assistant experience.

## Overview

This epic ensures Ora handles failures gracefully:
- Component failures (ASR timeout, LLM OOM, TTS crash)
- Graceful degradation when features unavailable
- User-friendly error messaging
- Automatic recovery where possible

## Prerequisites

- **Foundations:** F.01 (App Shell)
- **All Integration Epics:** ASR, LLM, TTS, Tools, Orchestration

## Story Index

| Story | Title | Description | Dependencies | Status |
|-------|-------|-------------|--------------|--------|
| **E.01** | [Error Recovery & Fallbacks](E.01-ERROR-RECOVERY.md) | Unified error handling and graceful degradation | O.02 | 📝 Spec Complete |

## Architecture Alignment

From `ARCHITECTURE.md`:
```
[ConversationOrchestrator @MainActor]  <--- handles errors, shows fallback UI
        |
        v
[AgentLoop actor]  <--- catches component failures, reports errors
   |        | \
   |        |  \--> [ToolHost actor] --> errors logged to audit
   |        |
   |        \--> [LLMRuntime actor] --> OOM detection, model reload
   |
   \--> [AudioPipeline actor] --> timeout handling
```

## Error Categories

| Category | Examples | Recovery Strategy |
|:---------|:---------|:------------------|
| **Transient** | Network timeout, temporary unavailable | Retry with backoff |
| **Resource** | OOM, disk full | Unload models, free memory, retry |
| **Permanent** | Missing permissions, corrupted model | Show error, guide user |
| **User** | Cancelled operation, timeout | Acknowledge gracefully |

## Success Criteria

- [ ] No unhandled crashes during normal operation
- [ ] All errors shown with user-friendly messages
- [ ] Automatic recovery for transient failures
- [ ] Graceful degradation (TTS fails → text only)
- [ ] All errors logged for debugging
