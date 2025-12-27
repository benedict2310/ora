# Orchestration Epic

The central orchestration layer that coordinates all components into a cohesive voice assistant experience.

## Overview

This epic provides the agentic loop and conversation flow that ties together:
- Audio/ASR → Transcription
- Transcription → LLM reasoning
- LLM → Tool execution (with confirmation)
- Response → TTS playback
- All → UI updates

## Prerequisites

- **Foundations:** F.05 (Hotkey), F.07 (Overlay), F.08 (Persistence)
- **ASR:** A.01, A.02, A.03
- **LLM:** L.01, L.02, L.03, L.04
- **TTS:** T.01, T.02, T.03
- **Tools:** X.01-X.05

## Story Index

| Story | Title | Description | Dependencies | Status |
|-------|-------|-------------|--------------|--------|
| **O.01** | [Agent Loop](O.01-AGENT-LOOP.md) | Core reasoning loop with tool execution | L.01, L.02, X.01 | ✅ Spec Complete |
| **O.02** | [Conversation Orchestrator](O.02-CONVERSATION-ORCHESTRATOR.md) | Full pipeline coordination | O.01, A.03, T.02 | ✅ Spec Complete |
| **O.03** | [Confirmation Flow](O.03-CONFIRMATION-FLOW.md) | UI-driven tool confirmation | O.01, F.07 | ✅ Spec Complete |

## Dependency Graph

```
┌─────────────────────────────────────────────────────────────┐
│                All Previous Epics                            │
│  (Foundations, ASR, LLM, TTS, Tools)                        │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
                    O.01 (Agent Loop)
                              │
                              ├──► O.02 (Conversation Orchestrator)
                              │
                              └──► O.03 (Confirmation Flow)
```

## Architecture Alignment

From `ARCHITECTURE.md`:
```
[ConversationOrchestrator @MainActor]  <--- renders state + confirmations
        |
        v
[AgentLoop actor]  <--- step budget, tool gating, policy enforcement, audit events
   |        | \
   |        |  \--> [ToolHost actor]
   |        |
   |        \--> [LLMRuntime actor]
   |
   \--> [AudioPipeline actor]
```

## State Machine

```
idle → listening → thinking → [proposing → executing] → responding → speaking → idle
                                     ↓
                                  denied → idle
```

## Loop Policy (v1)

| Parameter | Value |
|:----------|:------|
| `max_steps_per_turn` | 6 |
| `max_tool_calls_per_turn` | 3 |
| `max_total_tokens_generated` | 800 |
| `confirmation_timeout` | 60 seconds |

## Success Criteria

- [ ] PTT triggers full pipeline: ASR → LLM → (Tools) → TTS
- [ ] Tool proposals shown in UI with confirm/deny
- [ ] Confirmation timeout (1 min) auto-cancels
- [ ] Response streams to UI and TTS simultaneously
- [ ] User can cancel at any point
- [ ] All actions logged to audit trail
- [ ] State machine handles all edge cases
