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
- **ASR:** A.01, A.02, A.03, A.04
- **LLM:** L.01, L.02, L.03, L.04

## Story Index

| Story | Title | Description | Dependencies | Status |
|-------|-------|-------------|--------------|--------|
| **O.01** | [ASR-LLM Pipeline](O.01-ASR-LLM-PIPELINE.md) | Simple ASR → LLM wiring for testing | A.04, L.01, L.03, L.04 | ✅ Complete |
| **O.02** | [Agent Loop](O.02-AGENT-LOOP.md) | Core reasoning loop with tool execution | L.01, L.02, X.01 | ✅ Complete |
| **O.03** | [Conversation Orchestrator](O.03-CONVERSATION-ORCHESTRATOR.md) | Full pipeline coordination | O.01, O.02, T.02 | ✅ Complete |
| **O.04** | [Confirmation Flow](O.04-CONFIRMATION-FLOW.md) | UI-driven tool confirmation | O.02, F.07 | 🚧 To Do |
| **O.05** | [Improved Hotkey Flow](O.05-IMPROVED-HOTKEY-FLOW.md) | Tap-to-start, Enter-to-submit interaction | O.01 | ✅ Complete |
| **O.06** | [Agent Loop Integration](O.06-AGENT-LOOP-INTEGRATION.md) | Wire AgentLoop into the main pipeline (tools + proposals). | O.02, X.02, L.04, F.07 | 🚧 To Do |

## Incremental Approach

The orchestration is split into phases for easier testing:

### Phase 1: O.01 (ASR-LLM Pipeline)
- Basic voice → text → response flow
- No tools, no TTS, no multi-step reasoning
- Enables end-to-end testing of ASR + LLM

### Phase 2: O.02 (Agent Loop) + Tools
- Add tool calling and structured output
- Multi-step reasoning with budget limits
- Requires X.01 (Tool Protocol)

### Phase 3: O.03 (Full Orchestrator) + TTS
- Full state machine with all phases
- TTS playback integration
- Replaces/extends SimplePipelineController

### Phase 4: O.04 (Confirmation Flow)
- UI for confirming tool mutations
- Timeout handling

## Dependency Graph

```
        A.04 (Hotkey Wiring)
        L.01, L.03, L.04
                │
                ▼
      O.01 (ASR-LLM Pipeline)  ◄── Phase 1: Basic testing
                │
                │     X.01 (Tool Protocol)
                │           │
                ▼           ▼
        O.02 (Agent Loop)  ◄─────── Phase 2: Tool execution
                │
                │     T.01, T.02 (TTS)
                │           │
                ▼           ▼
   O.03 (Conversation Orchestrator) ◄─ Phase 3: Full pipeline
                │
                ▼
     O.04 (Confirmation Flow)  ◄──── Phase 4: Guardrails UI
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

## State Machine (Full - O.03)

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

### O.01 (Simplified)
- [ ] Hotkey triggers ASR → LLM → text response
- [ ] Response displays in overlay
- [ ] State machine handles basic flow

### O.02-O.04 (Full)
- [ ] PTT triggers full pipeline: ASR → LLM → (Tools) → TTS
- [ ] Tool proposals shown in UI with confirm/deny
- [ ] Confirmation timeout (1 min) auto-cancels
- [ ] Response streams to UI and TTS simultaneously
- [ ] User can cancel at any point
- [ ] All actions logged to audit trail
- [ ] State machine handles all edge cases
