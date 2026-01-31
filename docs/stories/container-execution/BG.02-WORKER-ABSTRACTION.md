# BG.02 - Worker Abstraction

**Epic:** Background Tasks
**Status:** Not Started
**Priority:** P1 (High)
**Estimated Effort:** 3 days
**Dependencies:** BG.01
**Target:** macOS 26 (Tahoe)
**Design Reference:** BG.00

---

## 1. Objective

Define a `BackgroundWorker` protocol with a pluggable isolation strategy, and implement the Phase 1 in-process worker using `URLSession` and HTML readability extraction. Future phases (XPC Service, Apple Container) slot in by conforming to the same protocol.

## 2. User Story

As a **user**, I want Ora to **fetch web pages and extract readable content** so that I can **get summarized research results from online sources**.

## 3. Scope

### In Scope

- `BackgroundWorker` protocol defining the worker contract (JSON in → JSON out)
- `URLSessionWorker`: Phase 1 in-process implementation
  - HTTP GET with configurable timeout and size limit
  - HTML → readable text extraction (SwiftSoup or equivalent)
  - Structured JSON output (title, text, metadata, source URL)
  - Support for fetching multiple URLs per task
- Worker lifecycle: start → progress → complete/fail
- Hard timeout enforcement via `Task` cancellation
- Content-type validation (reject binary, images, etc.)
- Integration with `BackgroundTaskManager` for dispatching

### Out of Scope

- XPC Service worker (Phase 2 — future)
- Apple Container worker (Phase 3 — future)
- Browser automation / JavaScript rendering
- PDF parsing (future extension)
- Network safety policy details (BG.03 — applied before worker dispatch)

## 4. Architecture Alignment

### Component Placement

```
Ora/BackgroundTasks/
  ├── Workers/
  │   ├── BackgroundWorker.swift        // Protocol
  │   ├── URLSessionWorker.swift        // Phase 1: in-process
  │   └── WorkerResult.swift            // Structured output type
  └── ... (existing from BG.01)
```

### Worker Protocol

```swift
/// Contract for background task workers.
/// Phase 1: in-process URLSession. Phase 2: XPC. Phase 3: Apple Container.
protocol BackgroundWorker: Sendable {
    /// Execute the task and return structured results.
    /// - Parameter input: Task inputs (URLs, query, options)
    /// - Parameter policy: Execution policy (timeout, size limits)
    /// - Returns: Structured extraction results
    /// - Throws: On timeout, network error, or extraction failure
    func execute(
        input: BackgroundTaskInputs,
        policy: BackgroundTaskPolicy
    ) async throws -> WorkerResult
}
```

### Worker Result Schema

```swift
struct WorkerResult: Sendable, Codable {
    let pages: [PageResult]
    let metadata: WorkerMetadata

    struct PageResult: Sendable, Codable {
        let url: String
        let title: String?
        let text: String           // Readability-extracted text
        let byline: String?
        let excerpt: String?
        let wordCount: Int
        let fetchedAt: Date
    }

    struct WorkerMetadata: Sendable, Codable {
        let totalPages: Int
        let successfulPages: Int
        let failedPages: Int
        let totalBytes: Int
        let executionTimeSeconds: Double
    }
}
```

### Integration with BackgroundTaskManager

```
BackgroundTaskManager.enqueue(task)
  │
  ├── Validates inputs (BG.01)
  ├── Applies network safety policy (BG.03)
  │
  └── Dispatches to worker:
      let worker = URLSessionWorker()  // Phase 1
      let result = try await worker.execute(input: task.inputs, policy: task.policy)
      │
      └── ArtifactStore.save(result, for: task)  // BG.04
```

### Concurrency

- Each worker runs in its own `Task` (managed by `BackgroundTaskManager`)
- `URLSession` is configured per-worker (ephemeral, no cookies, no cache)
- Multiple URLs within a task are fetched sequentially (not parallel) to respect rate limits
- Worker `Task` is canceled on timeout via parent task cancellation

### Existing Patterns

- Follows the same actor-based pattern as `ToolHost` (execute method, validation, result type)
- Result type mirrors `ToolResult` structure (structured data + human summary)
- Error handling matches `ToolHostError` pattern (typed errors with descriptive messages)

## 5. Implementation Plan (Draft)

### 5.1 Files to Create

- `Ora/BackgroundTasks/Workers/BackgroundWorker.swift` — Protocol definition
- `Ora/BackgroundTasks/Workers/URLSessionWorker.swift` — Phase 1: HTTP fetch + HTML extraction
- `Ora/BackgroundTasks/Workers/WorkerResult.swift` — Structured output types
- `Ora/BackgroundTasks/Workers/HTMLExtractor.swift` — Readability extraction (SwiftSoup wrapper)
- `Ora/BackgroundTasks/Workers/WorkerError.swift` — Typed error enum
- `OraTests/BackgroundTasks/URLSessionWorkerTests.swift` — Unit tests with URLProtocol mocking

### 5.2 Files to Modify

- `Ora/BackgroundTasks/BackgroundTaskManager.swift` — Add worker dispatch logic
- `project.yml` — Add SwiftSoup SPM dependency (or equivalent HTML parser)

### 5.3 Tests to Add

- `OraTests/BackgroundTasks/URLSessionWorkerTests.swift`:
  - `test_fetchSingleURL_returnsExtractedText`
  - `test_fetchMultipleURLs_returnsAllResults`
  - `test_timeout_throwsTimeoutError`
  - `test_oversizedResponse_throwsSizeLimitError`
  - `test_invalidContentType_throwsContentTypeError`
  - `test_networkError_throwsNetworkError`
  - `test_htmlExtraction_extractsReadableContent`
  - `test_htmlExtraction_handlesNoContent`
  - `test_cancellation_stopsInFlightRequest`
- `OraTests/BackgroundTasks/HTMLExtractorTests.swift`:
  - `test_extract_simpleHTML_returnsText`
  - `test_extract_complexPage_removesNavAndAds`
  - `test_extract_emptyBody_returnsEmpty`
  - `test_extract_plainText_returnsAsIs`

### 5.4 Dependencies/Config

- `project.yml` — Add HTML parsing dependency:
  - Option A: [SwiftSoup](https://github.com/scinfu/SwiftSoup) (most popular, JSoup port)
  - Option B: Custom lightweight parser (fewer dependencies but more effort)
  - Recommendation: SwiftSoup — mature, well-tested, pure Swift

## 6. Acceptance Criteria

- [ ] AC-1: `BackgroundWorker` protocol is defined with `execute(input:policy:)` method
- [ ] AC-2: `URLSessionWorker` fetches HTTP(S) URLs and returns structured `WorkerResult`
- [ ] AC-3: HTML content is extracted to readable text (title, body text, byline, word count)
- [ ] AC-4: Response size limit is enforced (default 5MB; request aborted if exceeded)
- [ ] AC-5: Per-request timeout is enforced (default 30s)
- [ ] AC-6: Task-level timeout is enforced (default 120s for entire task)
- [ ] AC-7: Non-HTML content types are handled gracefully (plain text returned as-is; binary rejected)
- [ ] AC-8: Worker is fully cancelable (responds to `Task.isCancelled` within 1s)
- [ ] AC-9: `URLSession` is ephemeral (no cookies, no persistent cache)
- [ ] AC-10: Multiple URLs per task are fetched sequentially with individual error handling (one failure doesn't abort all)

## 7. Verification Plan

### Automated Tests

- [ ] URLProtocol-mocked HTTP tests for success, timeout, size limit, content type
- [ ] HTML extraction tests with real-world HTML fixtures
- [ ] Cancellation propagation test
- [ ] Multi-URL partial failure test

### Manual Tests

- [ ] Fetch a real web page (e.g., Swift blog post) and verify readable text extraction
- [ ] Fetch a page that takes >30s and verify timeout
- [ ] Fetch a binary file (image) and verify rejection
- [ ] Cancel a running task and verify worker stops

## 8. Performance / Reliability Considerations

- URLSession configured with 30s per-request timeout; total task timeout 120s
- Response body limited to 5MB via `URLSessionDataDelegate` byte counting
- Ephemeral session: no disk cache, no cookies (privacy)
- HTML extraction should complete in under 1 second for typical web pages
- Memory: peak usage during fetch is bounded by response size limit (5MB)

## 9. Risks & Mitigations

- **SwiftSoup dependency size** — SwiftSoup is pure Swift (~200KB); acceptable. Alternative: use NSAttributedString HTML init but it's MainActor-bound and less reliable
- **Redirect loops** — URLSession's default redirect limit (20) is sufficient; additionally cap total redirects at 5
- **Encoding issues** — Detect encoding from HTTP Content-Type header; fall back to UTF-8
- **Memory spike on large HTML** — Stream response body; abort if size limit exceeded before full download

## 10. Open Questions

- Should we support following links within a page (crawling depth beyond 1)? (Proposed: no for v1)
- Should we cache fetched content for re-use across tasks? (Proposed: no — ephemeral is simpler and more private)
- Which HTML parser to use? (Proposed: SwiftSoup — needs project owner approval for new dependency)

---

## Implementation Summary

(TBD after implementation.)

## Code Review Findings

(TBD by review agent.)

## Completion Status

(TBD after merge.)
