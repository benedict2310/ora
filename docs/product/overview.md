# Ora v2 Product Overview

> Status: Draft for v2 reset  
> Last updated: 2026-07-02

## Product promise

Ora is a private, local-first macOS voice assistant for fast personal productivity actions.

Ora should feel like this:

> Press a hotkey, say a practical request, see exactly what Ora understood, approve anything that changes data, and get a clear result.

## Positioning

Ora v2 is not a general agent platform. It is a narrow assistant that does a small set of personal productivity workflows well.

## Target users

1. **Mac productivity users** who want quick calendar/reminder/contact actions without context switching.
2. **Privacy-conscious users** who prefer local inference and local data handling.
3. **Voice-first/accessibility users** who need predictable voice-driven task execution.

## Core use cases

### Calendar

Calendar is the flagship use case and must be excellent.

Supported intents:

- Ask about schedule: “What does my day look like?”
- Find availability: “Find 30 minutes tomorrow afternoon.”
- Create events: “Schedule lunch with Roland next Friday.”
- Update events: “Move my 3pm to 4pm.”
- Delete/cancel events: “Cancel my dentist appointment.”

### Reminders

Reminders should make capture and simple task management reliable.

Supported intents:

- Create reminders: “Remind me to submit expenses Monday morning.”
- List reminders: “What reminders are due today?”
- Update reminders: “Move that reminder to tomorrow.”
- Complete reminders: “Mark buy milk as done.”

### Contacts

Contacts primarily supports calendar/reminder flows and direct lookup.

Supported intents:

- Lookup contact info: “What’s Sarah’s email?”
- Resolve invitees: “Schedule with Roland.”
- Fuzzy matching for ASR errors, nicknames, and approximate names.

### Minimal system actions

System actions are convenience shortcuts, not automation.

Supported intents:

- Open app.
- Open URL or web search in the browser.
- Open Ora settings or relevant macOS settings.

## Product principles

1. **Narrow beats broad.** If a feature does not improve the voice loop or the core productivity actions, it is out of v2.
2. **Predictability beats cleverness.** Ora should say no instead of improvising dangerous or surprising behavior.
3. **Confirmation before mutation.** User data changes require an explicit visible proposal and approval.
4. **ASR is imperfect.** Search and lookup must tolerate homophones, misspellings, and approximate names.
5. **Local-first by default.** The v2 product does not depend on cloud providers.
6. **Fast enough to trust.** Prompt, tools, UI, and tests should stay small enough to keep interaction latency low.

## Explicit non-goals

The following are not part of v2 core:

- long-term memory,
- skills/scripts,
- background tasks,
- autonomous research,
- mail,
- messages,
- notes,
- cloud providers,
- vision/multimodal input,
- broad model marketplace/management UI,
- general Mac automation,
- broad file search,
- high test coverage as a goal.

## Minimal preferences

v2 preferences should be limited to:

- General: hotkey, private mode / voice output toggle.
- Permissions: microphone, accessibility if needed, calendar, reminders, contacts.
- Models: current local model status and recovery actions.
- Audit/history: user-visible record of mutations.

## Success criteria

- A new contributor can understand the product scope from `docs/product/` in minutes.
- A new contributor can understand the architecture from `docs/architecture/` in minutes.
- The default tool list fits on one screen.
- The default prompt only describes supported v2 capabilities.
- Default tests are fast and protect the core product promises.
- Unsupported feature requests produce clear refusal or fallback behavior.
