# ADR-0005: Request-local LLM KV cache

- Status: Accepted
- Date: 2026-10-15

## Decision

Each foreground `LLMService.generate` call prepares and consumes its complete
prompt exactly once with a newly allocated request-local KV cache. The cache is
not retained between turns, retries, cancellations, or failures. One-shot
completion already follows the same isolated-cache behavior.

The service calls the injected runtime's cache factory inside `MLXMetalGate`
for every request and passes that cache with the complete request to generation.
The immutable transfer wrapper holds only the actual `[KVCache]`; it has no
independent test identity or offset counters. Production retains the text chat
template/fallback and VLM processor preparation before handing the full `LMInput`
and that same cache to `TokenIterator`.

[Model-free tests](../../../OraTests/LLM/LLMServiceTests.swift) consume deterministic
UTF-8 input units into a CPU-only implementation of the pinned `KVCache` interface
and advance its offset. They detect service-level persistent-cache reuse, including
retry and stream-consumer cancellation. The fake records invocations of the
production-used cleanup hook, verifying that each request cleans up exactly once
under the gate after weak references to both its wrapper and actual KV state are
dead, including error/cancel exits.
Tests do not execute model tokenization, image processing, or Metal inference,
and make no throughput or speedup claim.

## Context and trade-off

The pinned MLX runtime consumes the full supplied `LMInput` against the supplied
cache. Reusing the prior request's cache while supplying a full conversation
therefore duplicates history and produces incorrect context. Prefix reuse is
intentionally deferred; request-local caches trade potential reuse for a simple,
correct baseline and bounded ownership.

GPU serialization through `MLXMetalGate`, the 512 MiB allocator cache limit,
memory checks, stop-token handling, and guarded explicit `clearCache` remain
unchanged. The allocator buffer cache is separate from attention KV state.

Every foreground runtime request now finishes or unwinds its nested cache-owning
operation before nonthrowing cleanup runs under the same held Metal gate. Cleanup
synchronizes queued GPU work (including preparation/prefill failure paths), then
calls `GPU.clearCache()` before releasing the gate, on success, error, or consumer
cancellation. The model runtime retains the producer handle returned by the same
underlying `generateTask` API, cancels and joins it before returning, so an early
stream exit cannot leave it using request KV state during cleanup. Cleanup does
not replace the original error. Requests rejected before runtime/cache creation
do not initialize or touch GPU cleanup.

## Contract evidence

The [locked graph](../../../Package.resolved) pins `mlx-swift-lm` 2.31.3 at
`25b00d4e22e61ec9c41efda47990cd2084ec87ff`:

- [`TokenIterator` initialization and preparation](https://github.com/ml-explore/mlx-swift-lm/blob/25b00d4e22e61ec9c41efda47990cd2084ec87ff/Libraries/MLXLMCommon/Evaluate.swift#L579-L646)
  pass the supplied input and cache to `model.prepare` without removing prior input.
- [Text model preparation](https://github.com/ml-explore/mlx-swift-lm/blob/25b00d4e22e61ec9c41efda47990cd2084ec87ff/Libraries/MLXLLM/LLMModel.swift#L22-L39)
  prefills the full supplied text against that cache.
- [Qwen3 VL preparation](https://github.com/ml-explore/mlx-swift-lm/blob/25b00d4e22e61ec9c41efda47990cd2084ec87ff/Libraries/MLXVLM/Models/Qwen3VL.swift#L1608-L1688)
  likewise supplies the full text/image embeddings and cache to the language model.
- [Stream/producer lifetime](https://github.com/ml-explore/mlx-swift-lm/blob/25b00d4e22e61ec9c41efda47990cd2084ec87ff/Libraries/MLXLMCommon/Evaluate.swift#L1101-L1151):
  the stream-only wrapper delegates to `generateTask` and discards its handle;
  early termination can leave the producer using the cache until that task is joined.

Prefix reuse would require a separately validated token-prefix and multimodal
state contract; no such reuse is introduced here.
