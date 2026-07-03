# PDR-0002: Deprecate platform features from v2 core

- Status: Accepted
- Date: 2026-07-02
- Related: `0001-ora-v2-product-scope.md`

## Context

Ora accumulated platform-like features that are individually interesting but collectively dilute the core product. These features increase maintenance load, prompt size, preferences complexity, security review burden, and test runtime.

## Decision

The following feature families are deprecated from the v2 core product:

- long-term memory and memory admin UI,
- skills, scripts, script authorization, and tool discovery,
- background tasks, container workers, and autonomous research,
- mail tools,
- messages tools,
- notes tools,
- cloud provider integrations,
- vision/multimodal attachments,
- broad model marketplace or provider switching UI,
- broad file search and broad Mac automation.

Deprecated means:

- not shown in the default UI,
- not registered in the default tool set,
- not described in the default prompt,
- not required by the default test suite,
- not used as a reason to keep legacy docs current.

## User impact

Users lose breadth but gain clarity. Ora should become easier to trust because it only offers actions it can perform predictably and safely.

## Consequences

- Existing implementation may be deleted, hidden behind development flags, or left temporarily unreachable while v2 is cut down.
- Tests for deprecated features should be deleted or moved out of the default gate.
- Future revival of any deprecated family requires a new PDR explaining the user value and an ADR explaining the architecture boundary.

## Non-deprecated support capabilities

The following support capabilities remain allowed because they directly support the v2 product:

- setup/recovery for required local models,
- permission recovery for microphone/calendar/reminders/contacts,
- local audit history for mutations,
- minimal diagnostics needed to support the core voice loop.
