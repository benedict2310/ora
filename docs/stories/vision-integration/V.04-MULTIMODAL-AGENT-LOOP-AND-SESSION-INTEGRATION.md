# V.04 - Multimodal Agent Loop & Session Integration

**Epic:** Vision Integration
**Status:** Not Started
**Priority:** P1 (High)
**Estimated Effort:** 3-4 days
**Dependencies:** V.01, V.02, V.03, O.06, F.08
**Target:** macOS 26 (Tahoe)
**Design Reference:** [ARCHITECTURE.md - Section 2](../ARCHITECTURE.md#2-agentic-loop-design)

---

## 1. Objective

Integrate image-bearing turns into Ora's live agent loop so users can attach a screenshot, ask a question by voice or text, receive a streamed answer, and continue a follow-up conversation without breaking tool use, TTS, or session history.

## 2. User Story

As a user, I want Ora to reason over my attached screenshot during a normal turn so that vision feels like part of the assistant, not a separate one-off feature.

## 3. Scope

### In Scope

- Pass pending image attachments from the overlay/pipeline into the model request used by the agent loop.
- Let `StructuredGenerator` continue validating structured JSON output when the prompt includes image references.
- Preserve tool-calling and confirmation flows for multimodal turns.
- Keep follow-up turns in the same live session aware of recently attached images where the selected local model/runtime supports it.
- Persist conversation-safe attachment metadata or summary markers without storing raw image bytes in SwiftData.
- Clear staged attachments and cached references at the right session lifecycle boundaries.

### Out of Scope

- Cross-restart restoration of full multimodal context
- Document/page chunking or OCR pipelines
- Video understanding
- Cloud vision execution

## 4. Architecture Alignment

- Reuse `AgentLoop`, `ConversationManager`, and `StructuredGenerator`; do not build a parallel "vision loop".
- Preserve tool guardrails and audit logging. Multimodal input should change prompt context, not weaken confirmation or logging.
- Keep raw image data out of `Session.messagesData`; persist only human-readable markers and metadata needed for audit/history clarity.
- Keep TTS unchanged. Vision output still resolves to normal assistant text that can be spoken.
- Relevant files:
  - `Ora/Orchestration/AgentLoop.swift`
  - `Ora/LLM/ConversationManager.swift`
  - `Ora/LLM/StructuredGenerator.swift`
  - `Ora/Orchestration/SimplePipelineController.swift`
  - `Ora/Persistence/Models/Session.swift`
  - `Ora/Persistence/PersistenceManager.swift`

## 5. Implementation Plan (Draft)

### 5.1 Files to Create

- None required if attachment metadata fits into current persistence structures.

### 5.2 Files to Modify

- `Ora/Orchestration/SimplePipelineController.swift` - Submit pending attachments with the next user turn and clear them on the correct lifecycle edges.
- `Ora/Orchestration/SimplePipelineController+Speech.swift` - Ensure streamed responses and post-response behavior remain unchanged for multimodal turns.
- `Ora/Orchestration/AgentLoop.swift` - Build multimodal-capable messages and keep tool execution/proposal behavior intact.
- `Ora/LLM/ConversationManager.swift` - Maintain in-memory context for recent image-bearing turns in the current session.
- `Ora/LLM/StructuredGenerator.swift` - Keep retry/validation behavior intact when messages include image references.
- `Ora/Persistence/Models/Session.swift` - Persist attachment-safe metadata markers rather than image payloads.
- `Ora/Persistence/PersistenceManager.swift` - Append session messages with attachment metadata where appropriate.
- `Ora/Overlay/OverlayState.swift` - Show a user-facing summary of submitted attachments if needed for transparency.

### 5.3 Tests to Add

- `OraTests/Orchestration/AgentLoopTests.swift` - Multimodal turn flow with tool-calling preserved.
- `OraTests/Orchestration/SimplePipelineControllerTests.swift` - Submit/cancel/follow-up behavior with attached images.
- `OraTests/StructuredGeneratorTests.swift` - JSON validation retry behavior with multimodal message context.
- `OraTests/PersistenceTests.swift` - Session persistence stores attachment markers/metadata but not raw image bytes.

### 5.4 Dependencies/Config

- No new package dependencies.
- If attachment staging has TTL or cleanup jobs, document that policy in the implementation.

## 6. Acceptance Criteria

- [ ] AC-1: A user can attach an image, speak a question, and receive a streamed response through the normal agent loop.
- [ ] AC-2: Tool-calling and confirmation flows still work when the turn includes an attached image.
- [ ] AC-3: Follow-up turns within the same live session can still refer to the recently attached image when the selected local model/runtime supports that context.
- [ ] AC-4: Session persistence stores only safe attachment markers/metadata and never raw image bytes in `messagesData`.
- [ ] AC-5: If the selected provider or model cannot handle the attached image, Ora surfaces clear guidance instead of silently ignoring the attachment.

## 7. Verification Plan

### Automated Tests

- [ ] `./build.sh test`
- [ ] Add agent-loop tests that verify multimodal requests still yield valid structured output and tool execution.
- [ ] Add persistence tests confirming attachment metadata is stored without raw image payloads.
- [ ] Add pipeline tests covering cancel/reset/follow-up behavior after an image-bearing turn.

### Manual Tests

- [ ] Attach a screenshot, ask a simple question, and confirm streamed response + TTS still work.
- [ ] Ask a follow-up question about the same screenshot in the same session and confirm the model retains the relevant context.
- [ ] Execute a safe read-only tool request after a multimodal turn and confirm the tool flow still works.
- [ ] Trigger a state-changing tool proposal after a multimodal turn and confirm confirmation UI still appears correctly.

## 8. Performance / Reliability Considerations

- Multimodal turns will increase token/input preparation cost; this story must preserve responsive streaming once generation begins.
- In-memory attachment references should be released when sessions end to avoid retaining large images longer than necessary.
- Persistence additions must not significantly grow the SwiftData session blob or break current save/decode performance.

## 9. Risks & Mitigations

- Mixed text/tool/image state can complicate prompt assembly
  - Mitigation: keep one multimodal-capable message model and one conversation manager rather than separate text and vision histories.

- Follow-up image context may behave differently across model repos
  - Mitigation: test same-session follow-up explicitly on the chosen local model and document any context limitations.

- Persistence may accidentally capture too much attachment detail
  - Mitigation: explicitly define and test the allowed stored metadata shape before merging.

## 10. Open Questions

- Should submitted user messages with images show a visible attachment summary bubble in the overlay history, or is a compact metadata marker sufficient for v1? The story leaves room for a lightweight visual summary, but persistence must remain metadata-only.

---

## Implementation Summary

(TBD after implementation.)

## Code Review Findings

(TBD by review agent.)

## Completion Status

(TBD after merge.)
