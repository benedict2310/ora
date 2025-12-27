# LLM Integration Epic

Integrate MLX Swift with Qwen 2.5 for local language model inference.

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
[LLMRuntime actor] (MLX Swift + Qwen 2.5) ---> token stream
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
| Qwen 2.5 7B-4bit | ~5GB | 8k | Primary (≥16GB RAM) |
| Qwen 2.5 3B-4bit | ~2GB | 4k | Fallback (<16GB RAM) |

## Success Criteria

- [ ] Model loads in < 5 seconds (after first compile)
- [ ] Time-to-first-token < 400ms (warm)
- [ ] Streaming tokens update UI in real-time
- [ ] JSON output validates against schema
- [ ] Retry on malformed JSON (max 3 attempts)
- [ ] Conversation context maintained across turns
