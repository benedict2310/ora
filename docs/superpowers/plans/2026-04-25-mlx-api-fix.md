# MLX API Break Fix Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `subagent-driven-development` (recommended) or `executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Restore a green build on `main` by fixing the `mlx-swift-lm` integration break in the lowest-risk way for release.

**Architecture:** The current failure is a dependency drift problem, not a product-logic bug. Ora’s code is written against the `mlx-swift-lm` 2.x loading API, but `project.yml` tracks `mlx-swift-lm` on `branch: main`, which currently resolves to a 3.x checkout with breaking loader and embedder API changes. The fastest, safest release fix is to pin `mlx-swift-lm` to the latest compatible 2.x tag (`2.31.3`), verify the full build/test matrix, and defer a 3.x migration to a separate branch.

**Tech Stack:** XcodeGen, Swift 6, `mlx-swift`, `mlx-swift-lm`, `swift-transformers`, XCTest

---

## Investigation Summary

- Current compile failure is reproducible with `./build.sh test`.
- Current resolved `mlx-swift-lm` checkout is `7e2b710` (`3.31.3-3-g7e2b710`).
- `project.yml` currently uses:

```yaml
mlx-swift-lm:
  url: https://github.com/ml-explore/mlx-swift-lm
  branch: main
```

- Ora code still targets the older API:

```swift
container = try await LLMModelFactory.shared.loadContainer(configuration: configuration)
container = try await VLMModelFactory.shared.loadContainer(configuration: configuration)
private var modelContainer: MLXEmbedders.ModelContainer?
return try await MLXEmbedders.loadModelContainer(configuration: modelConfiguration)
```

- The checked out 3.x docs explicitly say the embedder API changed:

```md
- ModelContainer -> EmbedderModelContainer and EmbedderModelContext
- MLXEmbedders.loadModelContainer (free function) -> EmbedderModelFactory.shared.loadContainer
- loading APIs now require from:/using:
```

- `mlx-swift-lm` tag `2.31.3` still exposes the old contracts Ora uses, including:

```swift
public func loadContainer(
    configuration: ModelConfiguration
) async throws -> ModelContainer

public func loadModelContainer(
    hub: HubApi = defaultHubApi,
    configuration: ModelConfiguration,
    progressHandler: @Sendable @escaping (Progress) -> Void = { _ in }
) async throws -> ModelContainer
```

## Recommendation

**Recommended release fix: pin `mlx-swift-lm` to `2.31.3` now.**

Why this path:
- smallest change surface
- matches the API Ora was written against
- avoids introducing new loader/downloader bridge code right before release
- reduces future breakage from tracking `main`
- keeps the 3.x migration as a deliberate follow-up instead of a release blocker

**Do not do the 3.x migration as part of the release unblock unless the pin fails.**

---

## Files to Modify

- `project.yml` - pin `mlx-swift-lm` to a stable compatible version instead of `branch: main`
- `docs/superpowers/plans/2026-04-25-mlx-api-fix.md` - this plan file only

## New Files

- None required for the release unblock

---

### Task 1: Capture the red state and confirm root cause

**Files:**
- Modify: none
- Test: `.artifacts/xcodebuild.test.log`

- [ ] **Step 1: Run the failing suite to capture the current blocker**

Run:
```bash
./build.sh test
```

Expected: FAIL during compile with errors equivalent to:
```text
Ora/LLM/LLMService.swift:101: missing arguments for parameters 'from', 'using'
Ora/LLM/LLMService.swift:103: missing arguments for parameters 'from', 'using'
Ora/Memory/EmbeddingService.swift:75: no type named 'ModelContainer' in module 'MLXEmbedders'
Ora/Memory/EmbeddingService.swift:174: module 'MLXEmbedders' has no member named 'ModelConfiguration'
```

- [ ] **Step 2: Confirm the dependency drift in the checkout**

Run:
```bash
git -C build/SourcePackages/checkouts/mlx-swift-lm describe --tags --always
```

Expected: output equivalent to:
```text
3.31.3-3-g7e2b710
```

- [ ] **Step 3: Confirm that `project.yml` is the cause of the drift**

Verify this stanza exists:
```yaml
mlx-swift-lm:
  url: https://github.com/ml-explore/mlx-swift-lm
  branch: main
```

Acceptance:
- We have a confirmed red state.
- We have confirmed that Ora is building against a drifting 3.x snapshot.
- We have confirmed that the codebase still expects 2.x loader contracts.

---

### Task 2: Apply the minimal release-safe dependency fix

**Files:**
- Modify: `project.yml`
- Test: full compile via `./build.sh test`

- [ ] **Step 1: Replace the floating branch pin with an exact compatible version**

Change:
```yaml
mlx-swift-lm:
  url: https://github.com/ml-explore/mlx-swift-lm
  branch: main
```

To:
```yaml
mlx-swift-lm:
  url: https://github.com/ml-explore/mlx-swift-lm
  exactVersion: "2.31.3"
```

Why `exactVersion` instead of `from`:
- release build reproducibility
- prevents silent re-breakage from future upstream changes
- keeps CI/local/dev aligned

- [ ] **Step 2: Regenerate the project and refresh package resolution**

Run:
```bash
./build.sh clean
```

Expected:
```text
- DerivedData removed
- Ora.xcodeproj regenerated
- package resolution refreshed against 2.31.3
```

- [ ] **Step 3: Verify the new checkout version**

Run:
```bash
git -C build/SourcePackages/checkouts/mlx-swift-lm describe --tags --always
```

Expected:
```text
2.31.3
```

Acceptance:
- `project.yml` no longer tracks `mlx-swift-lm` `main`
- package resolution points at `2.31.3`
- no app source files changed yet

---

### Task 3: Turn the build green again

**Files:**
- Modify: none
- Test: `Ora/LLM/LLMService.swift`, `Ora/Memory/EmbeddingService.swift` compile as-is

- [ ] **Step 1: Run the full test command after the pin**

Run:
```bash
./build.sh test
```

Expected:
```text
✅ Tests: <N>/<N> passed
```

If it still fails, capture the new first failure only and stop. Do **not** start a 3.x migration on the same branch without explicitly deciding to switch strategies.

- [ ] **Step 2: If full suite is too slow to iterate, confirm compile on the directly affected slices first**

Run:
```bash
xcodebuild test \
  -project Ora.xcodeproj \
  -scheme Ora \
  -only-testing:OraTests/LLM/LLMServiceTests \
  -only-testing:OraTests/EmbeddingServiceTests
```

Expected:
```text
** TEST SUCCEEDED **
```

Acceptance:
- `LLMService.swift` compiles without changing call sites
- `EmbeddingService.swift` compiles without changing call sites
- no MLX API mismatch errors remain

---

### Task 4: Validate the affected runtime paths, not just compilation

**Files:**
- Modify: none
- Test: `OraTests/LLM/LLMServiceTests.swift`
- Test: `OraTests/EmbeddingServiceTests.swift`
- Test: `OraTests/MemoryIndexTests.swift`
- Test: `OraTests/BackgroundTasks/SummaryGeneratorTests.swift`

- [ ] **Step 1: Run focused LLM and embedding tests**

Run:
```bash
xcodebuild test \
  -project Ora.xcodeproj \
  -scheme Ora \
  -only-testing:OraTests/LLM/LLMServiceTests \
  -only-testing:OraTests/EmbeddingServiceTests \
  -only-testing:OraTests/MemoryIndexTests \
  -only-testing:OraTests/BackgroundTasks/SummaryGeneratorTests
```

Expected:
```text
** TEST SUCCEEDED **
```

- [ ] **Step 2: Manually smoke test the local model load path**

Run:
```bash
./build.sh run
```

Manual checks:
- app launches
- local text LLM prepares successfully
- a simple text prompt gets a response
- if a vision-capable model is installed, image input still works
- no immediate MLX loader crash on first inference

- [ ] **Step 3: Manually smoke test memory retrieval path**

Manual checks:
- ask a query that should trigger memory retrieval
- confirm there is no embedding-model loader crash
- confirm the assistant still answers even if memory retrieval returns no hits

- [ ] **Step 4: Manually smoke test background summary path**

Manual checks:
- queue a background research task
- allow it to complete
- confirm summary generation still works
- confirm no regression in `generateOneShot()` path

Acceptance:
- runtime model loading works, not just the compile step
- memory retrieval does not break on live embedding usage
- background summarization still works on the pinned dependency

---

### Task 5: Lock the release branch down and document the follow-up

**Files:**
- Modify: `project.yml`
- Modify: optional release notes / PR description only
- Test: final `./build.sh test`

- [ ] **Step 1: Run one final clean validation**

Run:
```bash
./build.sh clean
./build.sh test
./build.sh
```

Expected:
```text
✅ Tests: <N>/<N> passed
```

- [ ] **Step 2: Commit only the dependency pin once validation is green**

Run:
```bash
git add project.yml
git commit -m "fix: pin mlx-swift-lm to 2.31.3"
```

- [ ] **Step 3: Record the deferred 3.x migration explicitly**

PR / handoff note should say:
```md
Release unblock uses `mlx-swift-lm` 2.31.3 because Ora still targets the 2.x loading API.
A separate follow-up should migrate to the 3.x `from:/using:` loader contracts and the new embedder container types.
```

Acceptance:
- release branch is green
- dependency source is deterministic
- deferred migration work is visible and not lost

---

## Dependencies

- Task 1 must happen before any change.
- Task 2 must finish before Task 3 can validate the build.
- Task 3 must pass before Task 4 runtime validation.
- Task 5 only happens after Task 3 and Task 4 are green.

## Risks

- `2.31.3` may expose a secondary incompatibility not seen in the initial failure; if so, stop and reassess before broad code edits.
- A floating `mlx-swift` version may still resolve to a newer compatible patch/minor; verify resolver output after the pin.
- Manual runtime checks matter because the current compile failure prevented the suite from reaching MLX execution paths.

---

## Contingency Plan: only if the version pin does not work

If pinning to `2.31.3` still leaves Ora broken, switch to a **separate branch** for a 3.x migration. Do not mix it into the release unblock branch.

### 3.x Migration Scope

**Files likely to modify:**
- `project.yml`
- `Ora/LLM/LLMService.swift`
- `Ora/Memory/EmbeddingService.swift`
- `Ora/Utilities/MLXTokenizerBridge.swift` *(new)*
- `Ora/Utilities/MLXTokenizerLoader.swift` *(new)*
- `Ora/Utilities/MLXHubDownloader.swift` *(new, if staying on existing `HubApi` rather than adding MLXHuggingFace integration)*
- `OraTests/EmbeddingServiceTests.swift`
- `OraTests/LLM/LLMServiceTests.swift`
- `OraTests/Utilities/MLXTokenizerBridgeTests.swift` *(new)*
- `OraTests/Utilities/MLXHubDownloaderTests.swift` *(new)*

### 3.x Migration Design

**Tokenizer bridge helper**
```swift
import MLXLMCommon
import Tokenizers

struct TransformersTokenizerBridge: MLXLMCommon.Tokenizer {
    private let upstream: any Tokenizers.Tokenizer

    init(_ upstream: any Tokenizers.Tokenizer) {
        self.upstream = upstream
    }

    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        upstream.encode(text: text, addSpecialTokens: addSpecialTokens)
    }

    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        upstream.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens)
    }

    func convertTokenToId(_ token: String) -> Int? {
        upstream.convertTokenToId(token)
    }

    func convertIdToToken(_ id: Int) -> String? {
        upstream.convertIdToToken(id)
    }

    var bosToken: String? { upstream.bosToken }
    var eosToken: String? { upstream.eosToken }
    var unknownToken: String? { upstream.unknownToken }

    func applyChatTemplate(
        messages: [[String: any Sendable]],
        tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?
    ) throws -> [Int] {
        do {
            return try upstream.applyChatTemplate(
                messages: messages,
                tools: tools,
                additionalContext: additionalContext
            )
        } catch Tokenizers.TokenizerError.missingChatTemplate {
            throw MLXLMCommon.TokenizerError.missingChatTemplate
        }
    }
}
```

**Tokenizer loader helper**
```swift
import Foundation
import MLXLMCommon
import Tokenizers

struct TransformersTokenizerLoader: TokenizerLoader {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        let tokenizer = try await Tokenizers.AutoTokenizer.from(modelFolder: directory)
        return TransformersTokenizerBridge(tokenizer)
    }
}
```

**Hub downloader helper using existing `Hub` dependency**
```swift
import Foundation
import Hub
import MLXLMCommon

struct HubAPIDownloader: Downloader {
    let hubApi: HubApi

    init(hubApi: HubApi = .shared) {
        self.hubApi = hubApi
    }

    func download(
        id: String,
        revision: String?,
        matching patterns: [String],
        useLatest: Bool,
        progressHandler: @Sendable @escaping (Progress) -> Void
    ) async throws -> URL {
        try await hubApi.snapshot(
            from: Hub.Repo(id: id),
            revision: revision ?? "main",
            matching: patterns,
            progressHandler: progressHandler
        )
    }
}
```

**LLMService 3.x loader change**
```swift
let tokenizerLoader = TransformersTokenizerLoader()

switch backend {
case .mlxLLM:
    container = try await LLMModelFactory.shared.loadContainer(
        from: modelPath,
        using: tokenizerLoader
    )
case .mlxVLM:
    container = try await VLMModelFactory.shared.loadContainer(
        from: modelPath,
        using: tokenizerLoader
    )
}
```

**EmbeddingService 3.x loader change**
```swift
private var modelContainer: EmbedderModelContainer?

private func prepareModelContainer() async throws -> EmbedderModelContainer {
    try await EmbedderModelFactory.shared.loadContainer(
        from: HubAPIDownloader(),
        using: TransformersTokenizerLoader(),
        configuration: ModelConfiguration(id: self.configuration.modelIdentifier)
    )
}
```

### 3.x Migration Acceptance

- all compile errors are removed without pinning back to 2.x
- new bridge tests pass
- full test suite passes
- local LLM, VLM, embeddings, and background summarization are smoke-tested manually

---

## Self-Review

- Spec coverage: this plan covers root-cause confirmation, release-safe implementation, full validation, and fallback migration path.
- Placeholder scan: no TBD/TODO steps remain.
- Type consistency: release path uses only dependency pinning; fallback path consistently uses `EmbedderModelContainer`, `EmbedderModelFactory`, `TokenizerLoader`, and `Downloader`.

---

Plan complete and saved to `docs/superpowers/plans/2026-04-25-mlx-api-fix.md`. Two execution options:

**1. Subagent-Driven (recommended)** - I dispatch a fresh subagent per task, review between tasks, fast iteration

**2. Inline Execution** - Execute tasks in this session using executing-plans, batch execution with checkpoints

**Which approach?**
