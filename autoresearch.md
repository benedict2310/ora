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

## How to Run
`./autoresearch.sh` — outputs `METRIC name=number` lines.

## Files in Scope
- `agent-tools/TestSuite/Sources/AgentBench/Resources/system-prompt.txt` — the system prompt used by the benchmark. Modifying this changes TTFT directly via token count.
- `Ora/Resources/system-prompt.txt` — production system prompt (should mirror benchmark after validated wins)
- `agent-tools/TestSuite/Sources/AgentBench/LLMBackend.swift` — generation parameters (temperature, topP, max tokens)
- `agent-tools/TestSuite/Sources/AgentBench/SystemPrompt.swift` — template variable resolution

## Off Limits
- Benchmark test cases (`benchmarks/*.json`) — don't change the tests
- Benchmark scoring/judging logic (`Benchmark.swift`, `JSONParser.swift`)
- Production app Swift source (beyond documented config params)
- Model weights, quantization

## Constraints
- pass_rate must stay >= 0.75 (currently 0.794) — don't sacrifice correctness for speed
- Changes to the system prompt must keep the 3 required JSON output formats valid (response/tool_call/proposal)
- Must keep ISO 8601 datetime requirement for calendar tools
- Keep the benchmark running on qwen3-4b (production model)

## Key Insights
1. **TTFT ≈ O(input tokens)** — reducing prompt length proportionally reduces TTFT
2. The benchmark's `SystemPrompt.swift` only resolves `{{tools}}` (not the newer `{{core_tools}}` etc.) so tool variable placeholders appear as literal text in the prompt. This means the static instructional text (sections 1-16) is the real token cost.
3. The production system prompt has 16 verbose sections. Some are not exercised by the benchmark (Notes, Mail, Messages, Research, Skills). Compressing them reduces TTFT without affecting pass rate.
4. Template variables that aren't resolved (`{{core_tools}}`, `{{deferred_tools_catalog}}`, `{{discovered_tools_section}}`, `{{available_skills}}`) contribute only their literal placeholder text (~40-80 chars each), so they're small.
5. The CRITICAL OUTPUT RULES section is repeated verbosely but is essential for JSON format compliance.

## What's Been Tried
(updated as experiments run)

### Baseline
- avg_ttft=660ms, pass_rate=0.794 — reference run

## Ideas Backlog
- Try greedy decoding (temperature=0) in LLMBackend — may improve JSON validity too
- Try `applyChatTemplate` instead of manual `encode(text:)` in LLMBackend — special tokens encoded more efficiently
- Compress CRITICAL OUTPUT RULES section (currently ~30 lines) to ~10 lines
- Replace multi-bullet domain sections with single-line summaries (Notes, Mail, Messages, Research, Skills)
- Move workflow guidance entirely into tool parameter descriptions (tool-schema-only prompt)
- Try max_tokens=400 instead of 800 — doesn't affect TTFT but reduces total generation time
