
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
