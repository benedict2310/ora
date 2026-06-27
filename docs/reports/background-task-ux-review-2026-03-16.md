# Background Task UX Review

**Date:** 2026-03-16
**Scope:** `docs/stories/container-execution/` and current background research implementation

## Summary

Ora's background-task backend is solid, but the current product shape is too constrained to feel like "research." The problem is not the queue, persistence, or artifact model. The problem is that the current security boundary is exposed directly as the primary user experience: `research.start` requires explicit URLs, so the user must do the discovery work manually.

That is the wrong layer for the restriction.

The recommended direction is:

1. Keep the current queue, artifact, and summary pipeline.
2. Add a query-first research front end above it.
3. Introduce explicit autonomy modes instead of a single hard-coded behavior.
4. Support an opt-in `dangerous` mode only when Ora can prove it is running in a strong isolation boundary.

## Current State

What exists today:

- `research.start` only accepts explicit `urls` in [ResearchStartTool.swift](/Users/bene/Dev-Source-NoBackup/ora/Ora/Tools/Research/ResearchStartTool.swift).
- The background worker is fetch-only (`URLSessionWorker`) and does not perform source discovery.
- Network safety is strong for the current scope: scheme checks, host checks, private IP blocking, redirect validation, response-size caps, content-type allowlisting.
- Artifacts, summaries, notifications, and task progress UI are implemented and working.

What this means in practice:

- Ora can execute a background fetch/summarize pipeline well.
- Ora cannot yet behave like a real research assistant.
- The user has to discover sources outside Ora, then paste them back into Ora.

## Core UX Problem

The product currently conflates:

- **security policy**
- **execution runtime**
- **user entry point**

Those should be separate.

The user-facing request should be:

> "Research the latest Nvidia Blackwell server rollout."

The system should then choose one of several execution policies:

- safe research with approval
- trusted research with low friction
- dangerous research with broad autonomy

The current URL-only design is a valid execution primitive, but a poor primary interface.

## Important Security Reality Check

Do not assume "container" automatically means "no shared kernel."

- Standard Docker containers share the host kernel.
- Docker's Enhanced Container Isolation (ECI) is different: Docker describes it as using hardware virtualization and a dedicated lightweight VM per container.
- Stronger isolation approaches include microVM/VM or sandboxed-kernel systems such as ECI, Kata Containers, or gVisor-class runtimes.

So the right product rule is:

- If Ora is only running background work in-process or in a normal container, `dangerous` mode should be treated as genuinely dangerous.
- If Ora is running in a verified VM-backed or equivalent hardened runtime, then `dangerous` mode becomes a reasonable user option.

## Recommended UX Model

### 1. Safe Mode (Default)

**User experience**

- User asks a research question in plain language.
- Ora performs source discovery.
- Ora presents a source plan once:
  - topic
  - proposed sources/domains
  - why each source was chosen
  - estimated time / page budget
- User approves once.
- Ora enqueues the task and runs in the background.

**What is allowed**

- web search / source discovery
- read-only fetch of public URLs
- bounded link following
- summarization and artifact creation

**What is not allowed**

- authenticated browsing
- internal/private network access
- arbitrary code execution
- open-ended browsing without a budget

### 2. Trusted Mode

**User experience**

- User asks a question in plain language.
- Ora discovers sources and auto-starts the task without a per-task approval prompt.
- The user can see what Ora chose and cancel immediately.

**How it is granted**

- per-user preference
- optionally per-domain trust
- optionally per-session trust

**Why this exists**

- This removes the "one extra confirmation every time" friction for users who trust Ora on ordinary public-web research.

### 3. Dangerous Mode

**User experience**

- User explicitly enables a red-labeled session mode such as `Dangerous Research`.
- Ora may autonomously search, follow links, widen the source set, and use more capable browsing tools.
- Ora still pauses for sensitive actions such as login/payment/captcha or leaving public-web research.

**What is allowed**

- autonomous source discovery
- broader link traversal
- browser-backed retrieval when static fetch is insufficient
- more generous budgets

**What must still be blocked or gated**

- private IPs / loopback / link-local / metadata addresses
- local files
- intranet / RFC1918 targets unless separately and explicitly enabled
- authenticated or state-changing browser actions without takeover

**Important**

- `dangerous` should be session-scoped by default, not a hidden permanent global foot-gun.
- It should be visible in UI and auditable in logs/artifacts.

## Best Practices From Current Agent Products

### A. Put approvals on capability escalation, not on raw parameters

Today Ora effectively asks the user to supply the exact URLs up front. That is overfitting the approval model to the transport layer.

Better pattern:

- Approve the **research plan**
- not the raw `urls` array

That keeps humans in the loop without making them do the assistant's job.

### B. Use tiered autonomy modes

Modern agent tools expose multiple approval/autonomy modes instead of a single binary. Ora should do the same:

- safe
- trusted
- dangerous

This is much better than a global all-or-nothing switch.

### C. Require takeover for sensitive browser moments

Even in dangerous mode, sensitive actions should transfer control back to the user:

- authentication
- payment
- captcha
- consent forms
- personal account areas

### D. Keep visible provenance

Every research run should preserve:

- source list
- source selection rationale
- timestamps
- redirects
- final URLs
- failures
- summary provenance

The user should be able to inspect "what Ora used" without reopening the conversation.

### E. Budget the task

Each research task should have explicit ceilings:

- search query count
- fetched page count
- per-page size limit
- total runtime
- maximum domain spread
- whether link following is allowed

Budgets make autonomy understandable and debuggable.

### F. Make runtime isolation explicit, not implied

If dangerous mode depends on stronger isolation, surface that in product and architecture:

- `Runtime isolation: In-process`
- `Runtime isolation: Container`
- `Runtime isolation: VM-backed isolated worker`

Dangerous mode should be unavailable or strongly warned when the runtime is not sufficiently isolated.

## Recommended Architecture Changes

### 1. Add a research planning layer

Introduce a new user-facing stage above `research.start`.

Suggested tools:

- `research.plan`
- `research.start_from_plan`

or:

- extend `research.start` to accept `query` and internally resolve a plan first

Recommendation:

- keep `research.start(urls:)` as the low-level execution primitive
- add `research.plan(query:)` as the main user-facing entry point

This preserves the current pipeline and minimizes churn.

### 2. Add explicit autonomy policy to task inputs/policy

The current `BackgroundTaskPolicy` only carries `taskKind` and `timeoutSeconds`.

It should grow into an execution policy object, for example:

- `autonomyMode: safe | trusted | dangerous`
- `discoveryEnabled: Bool`
- `browserMode: none | fetch_only | interactive`
- `maxSearchQueries`
- `maxFetchedPages`
- `maxDomainHops`
- `allowedDomains`
- `allowAuthenticatedBrowsing`
- `allowPrivateNetwork`
- `isolationRequirement: none | recommended | required`

This makes policy first-class and auditable.

### 3. Split planner from worker

The current `BackgroundWorker` is fetch-only. Keep that shape, but add a separate planner/discovery component.

Recommended roles:

- `ResearchPlanner`
  - query expansion
  - source discovery
  - source ranking
  - plan generation
- `BackgroundWorker`
  - execute the approved plan
  - fetch/process pages
  - store artifacts

This avoids turning the worker into a second freeform agent loop.

### 4. Add runtime backends

The worker abstraction should eventually support multiple backends:

- `InProcessFetchWorker`
- `IsolatedContainerFetchWorker`
- `BrowserWorker`
- `VMBackedDangerousWorker`

Then the policy decides which backend is allowed for the task.

### 5. Add a real task browser

BG.08 added menu bar and overlay status, which is useful but not enough.

Ora also needs a task browser that shows:

- queued / running / completed / failed
- source plan
- chosen domains
- artifacts
- summary
- audit trail
- rerun / continue / load into chat

Without this, a more autonomous research UX will feel opaque.

## Proposed Product Flow

### Safe Mode

1. User: "Research Nvidia Blackwell rollout."
2. Ora runs `research.plan(query:)`.
3. Ora shows:
   - proposed sources
   - domain count
   - fetch budget
   - why these sources were selected
4. User approves once.
5. Ora runs background task and notifies on completion.

### Trusted Mode

1. User: "Research Nvidia Blackwell rollout."
2. Ora automatically creates the plan and starts the task.
3. The task browser shows live sources and progress.
4. User can cancel or inspect provenance.

### Dangerous Mode

1. User enables dangerous mode for this session.
2. User: "Research Nvidia Blackwell rollout and keep digging until you have the most reliable sources."
3. Ora autonomously searches, follows links, and broadens the source set within configured budgets.
4. Ora pauses for any sensitive browser step.
5. Ora returns a result with provenance and a clearly marked autonomy/audit trail.

## Recommended Next Stories

### BG.09 - Query-First Research Planning

Add freeform query-based source discovery and source-plan approval above the existing URL pipeline.

### BG.10 - Research Autonomy Modes

Add user-visible `safe`, `trusted`, and `dangerous` research modes with policy persistence and prompt integration.

### BG.11 - Isolated Worker Runtime

Implement a runtime abstraction that can report verified isolation level and gate dangerous mode accordingly.

### BG.12 - Research Task Browser

Add a first-class UI for inspecting plans, active tasks, provenance, artifacts, and reruns.

## Concrete Recommendations For Ora

### Recommendation 1

Do **not** keep URL paste as the primary research UX.

### Recommendation 2

Do **not** give the background worker arbitrary tool access without a policy layer.

### Recommendation 3

Do add query-based source discovery immediately.

### Recommendation 4

Do add a user-visible autonomy mode selector.

### Recommendation 5

Do support dangerous mode, but only:

- with explicit opt-in
- with visible session state
- with strong budgets
- with preserved audit trails
- with verified runtime isolation

## External References

- Docker Engine security: containers share the host kernel  
  <https://docs.docker.com/engine/security/>
- Docker Desktop Enhanced Container Isolation: dedicated lightweight VM / hardware virtualization boundary  
  <https://docs.docker.com/security/for-admins/hardened-desktop/enhanced-container-isolation/>
- gVisor overview  
  <https://gvisor.dev/docs/>
- Kata Containers overview  
  <https://katacontainers.io/>
- OpenAI Codex CLI approval modes (`suggest`, `auto-edit`, `full-auto`) and note that full-auto is useful in fully sandboxed environments  
  <https://github.com/openai/codex>
- OpenAI Deep Research: clarification first, then multi-source web research  
  <https://openai.com/index/introducing-deep-research/>
- OpenAI Operator system card: user takeover for sensitive actions such as passwords/payment/captcha  
  <https://openai.com/index/operator-system-card/>
