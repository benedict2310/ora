# BG.02 - Worker Abstraction

**Epic:** Background Tasks
**Status:** Ready for Implementation
**Priority:** P1 (High)
**Estimated Effort:** 3 days
**Dependencies:** BG.01
**Target:** macOS 26 (Tahoe)

## Summary

Implement the phase-1 in-process worker that fetches explicit URLs and extracts clean text for later summarization. The worker contract must be pluggable so future isolation strategies can replace the in-process implementation without changing the queue or research tools.

## Architecture Context and Reuse Guidance

- The queue actor from BG.01 should own worker dispatch.
- BG.02 should not add new package dependencies. Keep the v1 extractor in-repo.
- Network safety is applied through BG.03’s `SafeURLSession`; do not let the worker talk to raw `URLSession` directly once BG.03 lands.
- New files under `Ora/BackgroundTasks/Workers/` are auto-included by `project.yml`.

## Resolved Decisions

- No SwiftSoup dependency in v1.
- `research.start` is URL-based; the worker does not discover sources on its own.
- Multiple URLs are fetched sequentially.
- Partial failure is allowed: one failed page does not fail the whole task unless every page fails.

## File Touch List

- `Ora/BackgroundTasks/Workers/BackgroundWorker.swift`
  Purpose: shared worker protocol.
- `Ora/BackgroundTasks/Workers/WorkerResult.swift`
  Purpose: codable result types returned by workers.
- `Ora/BackgroundTasks/Workers/URLSessionWorker.swift`
  Purpose: phase-1 worker implementation.
- `Ora/BackgroundTasks/Workers/HTMLTextExtractor.swift`
  Purpose: in-repo HTML-to-text extraction without third-party dependencies.
- `Ora/BackgroundTasks/Workers/WorkerError.swift`
  Purpose: typed worker failures for queue/audit surfaces.
- `Ora/BackgroundTasks/BackgroundTaskManager.swift`
  Purpose: inject and execute the worker.
- `OraTests/BackgroundTasks/URLSessionWorkerTests.swift`
  Purpose: fetch/cancellation/partial-failure coverage.
- `OraTests/BackgroundTasks/HTMLTextExtractorTests.swift`
  Purpose: extraction quality coverage.

## Implementation Steps

1. Define `BackgroundWorker`.
   ```swift
   protocol BackgroundWorker: Sendable {
       func execute(
           taskID: UUID,
           input: BackgroundTaskInputs,
           policy: BackgroundTaskPolicy
       ) async throws -> WorkerResult
   }
   ```

2. Define `WorkerResult`.
   Required fields:
   - `pages: [PageResult]`
   - `metadata: WorkerMetadata`
   - `failedURLs: [FailedPage]`

   `PageResult` should include:
   - `url`
   - `finalURL`
   - `title`
   - `text`
   - `contentType`
   - `wordCount`
   - `fetchedAt`
   - optional `rawHTML`

3. Implement `HTMLTextExtractor`.
   Minimum behavior:
   - remove `script`, `style`, and `noscript` blocks
   - extract `<title>`
   - strip remaining tags
   - decode common HTML entities
   - collapse whitespace/newlines
   - preserve enough paragraph breaks to make summaries readable

4. Implement `URLSessionWorker`.
   - Use injected fetch client from BG.03.
   - Fetch URLs sequentially.
   - Convert HTML/text responses into `PageResult`.
   - Record per-URL failure details without aborting the whole task unless every URL fails.

5. Wire worker execution into `BackgroundTaskManager`.
   The manager should mark task state based on the aggregate worker result.

## Tests and Validation

- `test_execute_singleHTMLURL_returnsPageResult`
- `test_execute_multipleURLs_returnsSequentialResults`
- `test_execute_partialFailure_keepsSuccessfulPages`
- `test_execute_allFailures_throws`
- `test_execute_cancellationStopsRemainingFetches`
- `test_extract_titleAndBodyText`
- `test_extract_removesScriptsAndStyles`
- `test_extract_decodesEntities`
- `test_extract_collapsesWhitespace`
- `test_extract_emptyHTML_returnsEmptyText`

Manual validation:
- Fetch two real docs pages and confirm extracted text is readable enough for summarization.
- Cancel a running multi-URL task and confirm later URLs are never requested.

## Acceptance Criteria

- [ ] `BackgroundWorker` exists and is injectable from `BackgroundTaskManager`.
- [ ] `URLSessionWorker` returns structured, codable `WorkerResult` data for HTML and plain-text responses.
- [ ] Extraction is implemented in-repo; BG.02 does not add a new package dependency.
- [ ] Multiple URLs are processed sequentially.
- [ ] Per-page failures are preserved without losing successful pages.
- [ ] Worker cancellation stops further work quickly enough for queue cancellation to feel immediate.

## Risks and Open Questions

- v1 extraction quality is intentionally “clean text” rather than full readability scoring. If that proves too weak, add a dedicated parser in a follow-up story after explicit dependency approval.
- **Decompressed body size:** The 5MB limit in BG.03 applies to transfer size. A gzip-compressed response could decompress to much more. The worker should validate decompressed size during streaming and abort if it exceeds the limit. Check `Content-Length` header against `maxResponseBytes` as an early guard.
- **HTML extraction timeout:** `HTMLTextExtractor` processing on adversarial HTML (deeply nested tags, huge attribute strings) could consume excessive CPU. Add a processing timeout separate from the network timeout (e.g., 10s).
