# LLM Integration Epic

Integrate MLX Swift with Qwen local models for on-device language model inference.

## Overview

This epic provides the local LLM runtime for Ora, enabling:
- Model loading and warmup
- Streaming token generation
- Structured JSON output with validation
- System prompt management
- Conversation context handling

## Prerequisites

- **Foundations:** F.03 (Model Manager), F.08 (Persistence)

## Story Index

| Story | Title | Description | Dependencies |
|-------|-------|-------------|--------------|
| **L.01** | [LLM Runtime](L.01-LLM-RUNTIME.md) | MLX Swift wrapper, model loading, inference | F.03 |
| **L.02** | [Structured Output](L.02-STRUCTURED-OUTPUT.md) | JSON schema validation, retry logic | L.01 |
| **L.03** | [Conversation Manager](L.03-CONVERSATION-MANAGER.md) | Context management, message history | L.01, F.08 |
| **L.04** | [System Prompt](L.04-SYSTEM-PROMPT.md) | Dynamic prompt building with tools/context | L.01 |
| **L.05** | [Additional LLM Models](L.05-ADDITIONAL-LLM-MODELS.md) | Multi-model support, planner/executor | L.01, F.03 |
| **L.06** | [Qwen 3 Upgrade](L.06-QWEN3-UPGRADE.md) | Replace Qwen 2.5 with Qwen 3 | L.01, F.03, F.09 |
| **L.07** | [Qwen 3.5 27B Text Local Model](L.07-QWEN35-27B-TEXT.md) | Add an optional advanced sharded Qwen 3.5 local model | L.06, BUG.01, BUG.04, M.02 |

## Dependency Graph

```
F.03 (Model Manager) ──► L.01 (LLM Runtime)
                              │
                              ├──► L.02 (Structured Output)
                              │
F.08 (Persistence) ───────────┼──► L.03 (Conversation Manager)
                              │
                              └──► L.04 (System Prompt)
```

## Architecture Alignment

From `ARCHITECTURE.md`:
```
[LLMRuntime actor] (MLX Swift + local Qwen models) ---> token stream
```

## Key Interfaces

```swift
// From ARCHITECTURE.md
protocol LLMServicing: Sendable {
    func respond(to messages: [LLMMessage], schema: JSONSchema) -> AsyncThrowingStream<LLMDelta, Error>
}

struct LLMMessage: Sendable {
    enum Role: Sendable { case system, user, tool, assistant }
    let role: Role
    let content: String
}

enum LLMDelta: Sendable {
    case token(String)
    case jsonFragment(String)
    case completed
}
```

## Model Configuration

| Model | Size | Context | Use Case |
|:------|:-----|:--------|:---------|
| Qwen 3 4B | ~2.5GB | current Ora default | Broad device support, setup default |
| Qwen 3.5 27B Text | ~14.3GB | 262k (model config) | Optional advanced local model on 32GB+ Macs |

## Success Criteria

- [ ] Model loads in < 5 seconds (after first compile)
- [ ] Time-to-first-token < 400ms (warm)
- [ ] Streaming tokens update UI in real-time
- [ ] JSON output validates against schema
- [ ] Retry on malformed JSON (max 3 attempts)
- [ ] Conversation context maintained across turns
