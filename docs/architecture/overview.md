# Ora v2 Architecture Overview

> Status: Draft for v2 reset  
> Last updated: 2026-07-02

## Architectural goal

Ora v2 is a small local-first macOS voice assistant, not a general agent platform. The architecture should make the supported product obvious: a push-to-talk loop, local model inference, a small trusted tool host, visible confirmation for mutations, and local auditability.

## Core flow

```text
Push-to-talk / text input
    ↓
ASR transcript or typed request
    ↓
Assistant session
    ↓
Local LLM structured output
    ↓
Tool host validation
    ↓
Read result or confirmation proposal
    ↓
Tool execution after confirmation
    ↓
Overlay response + optional TTS + audit entry
```

## Primary boundaries

| Boundary | Responsibility | Must not do |
| --- | --- | --- |
| Activation UI | Hotkey, menu bar affordance, compact overlay lifecycle | Call tools directly |
| Audio pipeline | Capture speech, produce transcripts, play TTS | Decide intent or execute actions |
| Assistant session | Own one user turn, prompt construction, structured-output loop | Reach into EventKit/Contacts directly |
| Prompt builder | Build a compact prompt from the current core tool set | Include deprecated tools or legacy policy text |
| Tool host | Validate arguments, enforce confirmation policy, call tools | Trust raw LLM output or mutate without consent |
| Core tools | Calendar, reminders, contacts, minimal system actions | Expand into mail/messages/research/scripts/memory |
| Audit store | Record proposed and executed mutations locally | Become long-term semantic memory |
| Preferences | Permissions, hotkey/private mode, model status, audit access | Become an admin console for experimental systems |

## Core components

### Activation and overlay

The user starts every interaction explicitly. Push-to-talk is the primary input path; text input may exist as an accessibility/debug fallback. The overlay shows:

1. what Ora heard,
2. what Ora is thinking/doing,
3. any proposed mutation before execution,
4. the final answer or failure.

### Local model path

v2 starts with one local ASR path, one local LLM path, and one local TTS path. Model selection can be pragmatic internally, but the product should not expose a broad provider/model marketplace during the v2 reset.

### Structured assistant session

The LLM must produce one of a small set of structured outputs:

- plain response,
- read-only tool call,
- mutation proposal.

The session may retry invalid JSON/output, but retries should be bounded and observable.

### Tool host

The tool host is the only layer allowed to call macOS frameworks for user data or actions. It validates schema, normalizes ASR-imperfect user strings, checks permissions, and records audit data.

### Confirmation gate

All create/edit/delete actions for calendar and reminders require explicit confirmation. Read-only actions can execute without confirmation. Safe system actions are limited to open app, open URL/search, and open settings.

### Audit store

Audit is not memory. It exists so users can answer: “What did Ora change, when, and why?” It should not feed an open-ended personalization/memory system in v2.

## In scope for v2 architecture

- Push-to-talk voice loop and compact overlay.
- Local ASR, local LLM, local TTS.
- Calendar query/find/create/update/delete with confirmation for mutations.
- Reminder list/create/update/complete/delete with confirmation for mutations.
- Contacts search with fuzzy matching for ASR errors.
- Minimal system actions: open app, open URL/search, open relevant settings.
- Permission recovery and clear failure states.
- Local audit trail for mutations.
- Small high-signal test suite.

## Out of scope for v2 architecture

- Long-term memory and memory admin UI.
- Skills, scripts, script authorization, and tool discovery marketplaces.
- Background task runners, autonomous research, and container workers.
- Mail, messages, notes, file search, broad system automation.
- Cloud provider abstraction and provider preferences.
- Vision/multimodal attachments.
- Broad model management UI.

## Implementation migration principle

Reuse proven internals only when they fit these boundaries. Do not preserve a subsystem just because it exists. During v2 work, deleted or disabled features should also lose their default tests and prompt surface.
