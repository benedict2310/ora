# Autoresearch: LLM Time-to-First-Token (TTFT)

## Objective
Reduce the time-to-first-token (TTFT) for the Ora LLM pipeline using the AgentBench benchmark suite. TTFT is dominated by the prefill computation, which scales with input token count. The primary lever is **system prompt compression** — every token removed from the system prompt directly reduces TTFT.

The benchmark uses `agent-tools/TestSuite` which runs 34 real-inference tests across calendar, reminders, contacts, system tools, and multi-step queries using qwen3-4b (production model).

## Metrics
- **Primary**: `avg_ttft_ms` (ms, lower is better) — average TTFT across all 34 tests
- **Secondary**:
  - `min_ttft_ms` — best-case TTFT
  - `max_ttft_ms` — worst-case TTFT
  - `pass_rate` — fraction of tests passing (0.0–1.0, must not degrade significantly)
  - `prompt_chars` — character count of the built system prompt (proxy for token count)

## Baseline
- avg_ttft_ms: ~660ms
- pass_rate: 27/34 = 0.794
- System prompt: ~9785 chars (~2935 estimated tokens at 0.3 tok/char)

## Current Best (as of session 3)
- avg_ttft_ms: 399.8ms (−74.6% from 1578ms all-time baseline)
- pass_rate: 0.912 (31/34)
- System prompt: ~1508 chars static text

## How to Run
`./autoresearch.sh` — outputs `METRIC name=number` lines.

## Files in Scope
- `agent-tools/TestSuite/Sources/AgentBench/Resources/system-prompt.txt` — the system prompt used by the benchmark (symlink to production prompt)
- `Ora/Resources/system-prompt.txt` — production system prompt
- `agent-tools/TestSuite/Sources/AgentBench/LLMBackend.swift` — generation parameters (temperature, topP, max tokens)
- `agent-tools/TestSuite/Sources/AgentBench/SystemPrompt.swift` — template variable resolution

## Off Limits
- Benchmark test cases (`benchmarks/*.json`) — don't change the tests
- Benchmark scoring/judging logic (`Benchmark.swift`, `JSONParser.swift`)
- Production app Swift source (beyond documented config params)
- Model weights, quantization

## Constraints
- pass_rate must stay >= 0.75 (currently 0.912) — don't sacrifice correctness for speed
- Changes to the system prompt must keep the 3 required JSON output formats valid (response/tool_call/proposal)
- Must keep ISO 8601 datetime requirement for calendar tools
- Keep the benchmark running on qwen3-4b (production model)

## Prompt Lock (DO NOT CHANGE — Tested Critical)

| Element | Reason |
|---------|--------|
| `Remember: JSON only.` at end | CRITICAL — removing causes −17pp pass_rate crash |
| `no prose outside JSON` in OUTPUT FORMAT header | Important — removing causes +2 failures (prose-before-JSON) |
| Spaces in JSON examples | Important — removing causes calendar.create_event to fail |
| Capability list in intro ("for calendar, reminders...") | Critical — removing causes basic tool failures |
| `"You are Ora"` persona format | Critical — other formats cause random JSON errors |

## Key Insights
1. **TTFT ≈ O(input tokens)** — reducing prompt length proportionally reduces TTFT
2. The benchmark only tests calendar/reminders/contacts/system domains — NOTES/MESSAGES/MAIL/SKILLS/RESEARCH sections don't affect pass_rate but ARE needed for production quality
3. **"Never claim to perform an action without calling a tool"** — single most valuable instruction (+15pp pass_rate when added)
4. **"..." in format examples** — teaches model these are variable placeholders, NOT literal values (+6pp pass_rate)
5. **DYNAMIC TOOLS guidance** in static prompt confuses model when no deferred tools are present (+3pp when moved to encodeDeferredToolCatalog)
6. **Required-params-only tool schema** (no `:type`, no optional params) — double win: shorter AND higher accuracy
7. **Measurement variance** at temperature=0.7 is ~±3pp pass_rate and ~±10ms TTFT between runs

## What to Try Next (Priority Order)
See autoresearch.ideas.md for full backlog.

### Highest Priority: KV Cache Prefix Sharing
Pre-compute the KV state for the ~400-token static system prompt prefix (everything before CORE TOOLS section). Reuse it for all requests/tests, only prefilling the per-test delta (tools + user message ~100-250 tokens). Expected TTFT improvement: 400ms → 100-200ms (2-4x reduction).

Implementation path: see autoresearch.ideas.md for full details.

### Lower Priority
- Try different date/time format in CONTEXT (shorter format like "Mon 3/16" vs "Monday, March 16, 2026")
- Try temperature=0.5 (not 0 — affects accuracy; 0.5 might be more deterministic with less accuracy loss)
