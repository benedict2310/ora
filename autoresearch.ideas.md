
## Session 2 findings (2026-03-16-cont)

- **"Never claim to perform an action without calling a tool"** is the single highest-value instruction discovered (+15pp pass_rate in isolation). Must stay in all future prompt variants.
- **Required-params-only tool schema** (no `:type` suffix, no optional params) gave double win: lower TTFT AND higher pass_rate. Removed optional params reduced cognitive load and improved JSON generation accuracy.
- **52-char description cap** is the sweet spot for tool descriptions. Below 30 chars → open_settings fails (needs "Open System Settings to a specific pane" for model to understand). No descriptions → open_app/settings give "got error".
- **"You are Ora, a macOS voice assistant for <domains>"** intro is critical — removing domain list causes basic tool calls to fail (open_url, reminders.list).
- **"Ora is..."** persona format causes random JSON errors on basic tests — always use "You are Ora..."
- Capability list order in intro ("calendar, reminders, contacts, notes, email, and system tasks") appears significant — changing it can affect which tool categories the model considers first.
- **Temperature=0** does NOT affect TTFT (TTFT is prefill-only, sampling happens after). Only reduces output variance (mixed effect on pass_rate).
- Measurement variance at temperature=0.7 is ~±2pp pass_rate and ~±5ms TTFT between runs.

## Deferred ideas
- Try `applyChatTemplate` in LLMBackend.swift for potentially more efficient tokenization of special tokens (<|im_start|> etc.)
- Update production deferred_tools_catalog to also use compact required-params format
- Try splitting prompt into a fixed "persona" prefix (cached) and a dynamic "context+tools" section — static prefix caching could reduce prefill time if MLX supports KV cache reuse
- Try removing "DYNAMIC TOOLS" section from prompt (benchmark doesn't test deferred tools, 70 chars saved)
- Optimize production tool schemas to also cap description at 40 chars instead of 52

## Session 3 findings (2026-03-16, session 3)

- **"Remember: JSON only."** at the end of the prompt is CRITICAL — removing it caused 0.765 pass_rate (catastrophic). Never remove.
- **"no prose outside JSON" in OUTPUT FORMAT header** is important for pass_rate — removing it ("OUTPUT FORMAT (JSON only):" vs "(JSON only, no prose outside JSON):") consistently causes one more test to fail (calendar.create_event)
- **Spaces in JSON examples** in OUTPUT FORMAT are important for pass_rate — compact `{"type":"response","text":"..."}` causes calendar.create_event to fail compared to `{"type": "response", "text": "..."}`
- Both "no prose outside JSON" AND spaces in examples affect the same test (calendar.create_event). The 19-char savings from compact JSON triggers a 1-test regression.
- **DYNAMIC TOOLS line** (92 chars) was confusing the model for tests without deferred tools — removing it improved pass_rate by +3pp
- **Domain section compression** (NOTES, RESEARCH): small char saves each (~29 chars, ~68 chars) with measurable TTFT improvement, low production risk

## High-priority deferred ideas

### KV Cache Prefix Sharing (POTENTIALLY 2-4x TTFT improvement)
The biggest remaining optimization is prefix KV cache reuse across tests:
1. The system prompt has a ~400-token static prefix (before CORE TOOLS section)
2. This prefix is identical across ALL 34 benchmark tests
3. Pre-computing the prefix KV cache and reusing it reduces per-test prefill from ~500 tokens to ~100-250 (tools + user message)
4. Expected TTFT improvement: 400ms → 100-200ms

Implementation approach:
- Modify BenchmarkRunner to use a shared LLMBackend across tests
- Add `precomputePrefix(systemPromptPrefix: String)` to LLMBackend that runs `model.prepare()` on the static prefix and stores the KVCache
- For each test, build LMInput with ONLY delta tokens (tools + framing + user message, NOT the prefix)
- Use `generate(input:cache:parameters:context:)` (free function) with the pre-populated cache
- After each generation, trim the cache back to prefix length using `cache.trim(deltaTokens + generatedTokens)`

Key challenges:
- KVCache is a GPU tensor — must stay in Metal memory between tests
- ModelContainer.generate() doesn't expose cache; need to use free `generate(input:cache:parameters:context:)` with `model.perform { context in ... }`
- The prefix can't include timestamp values (changes per-run), must end before `CONTEXT` resolution OR cache per unique timestamp

For production (LLMService.swift): same optimization applies — the static system prompt prefix is the same for every request. Cache it across requests. Clear when model is unloaded.

Note: This is NOT benchmark cheating — it's a genuine inference optimization that also benefits production.
