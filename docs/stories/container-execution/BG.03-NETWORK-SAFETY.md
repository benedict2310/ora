# BG.03 - Network Safety Policy

**Epic:** Background Tasks
**Status:** Complete
**Priority:** P1 (High)
**Estimated Effort:** 1.5 days
**Dependencies:** BG.02
**Target:** macOS 26 (Tahoe)

## Summary

Add a host-side safety layer that blocks unsafe URLs before the worker ever fetches them. v1 must prevent obvious SSRF paths, private-network access, oversized downloads, unsafe content types, and redirect-based bypasses.

## Verification Notes

- Verified on 2026-03-16 against [SafeURLSession.swift](/Users/bene/Dev-Source-NoBackup/ora/Ora/BackgroundTasks/Safety/SafeURLSession.swift) and [URLSafetyValidator.swift](/Users/bene/Dev-Source-NoBackup/ora/Ora/BackgroundTasks/Safety/URLSafetyValidator.swift).
- Focused tests passed in `.artifacts/BGTests-2.xcresult`, including `SafeURLSessionTests` and `URLSafetyValidatorTests`.
- The safety layer is present and used by [URLSessionWorker.swift](/Users/bene/Dev-Source-NoBackup/ora/Ora/BackgroundTasks/Workers/URLSessionWorker.swift).

## Architecture Context and Reuse Guidance

- BG.03 should be a wrapper around `URLSession`, not a second worker implementation.
- Keep validation logic isolated and injectable so unit tests do not depend on real DNS or real network access.
- Use Foundation / system networking APIs only.

## Resolved Decisions

- Allowed schemes: `http`, `https`.
- Validate hostnames before fetch and redirect targets during fetch.
- Explicitly block loopback, RFC1918, link-local, unique-local IPv6, and cloud metadata IPs.
- Default allowed content types: `text/html`, `text/plain`, `application/json`, `application/xml`, `text/xml`.
- Default max response size: `5 MB`.
- Default max request count per task: `10`.

## File Touch List

- `Ora/BackgroundTasks/Safety/NetworkSafetyPolicy.swift`
  Purpose: codable policy values used by queue and worker.
- `Ora/BackgroundTasks/Safety/URLSafetyValidator.swift`
  Purpose: scheme/host/IP/content-type validation helpers.
- `Ora/BackgroundTasks/Safety/URLResolver.swift`
  Purpose: injectable hostname resolution abstraction for tests.
- `Ora/BackgroundTasks/Safety/SafeURLSession.swift`
  Purpose: policy-enforcing fetch client with redirect and size checks.
- `Ora/BackgroundTasks/Safety/NetworkSafetyError.swift`
  Purpose: typed failures for logs/audit/user-facing summaries.
- `Ora/BackgroundTasks/Workers/URLSessionWorker.swift`
  Purpose: switch worker fetches to `SafeURLSession`.
- `OraTests/BackgroundTasks/URLSafetyValidatorTests.swift`
- `OraTests/BackgroundTasks/SafeURLSessionTests.swift`

## Implementation Steps

1. Define `NetworkSafetyPolicy` as part of `BackgroundTaskPolicy`.
   Include:
   - `maxResponseBytes`
   - `maxRequests`
   - `allowedDomains: [String]?`
   - `allowedContentTypes: [String]`
   - `requestTimeoutSeconds`

2. Add `URLResolver`.
   Requirements:
   - injectable protocol
   - production implementation uses `getaddrinfo` or equivalent system resolution
   - test implementation can return controlled IPs

3. Implement `URLSafetyValidator`.
   Must validate:
   - scheme
   - host presence
   - literal IPs
   - resolved IPs for hostnames
   - domain allowlist
   - response content type

4. Implement `SafeURLSession`.
   Requirements:
   - **one ephemeral session per task** (not shared across tasks) with `httpCookieStorage = nil` and `urlCredentialStorage = nil` to prevent cross-task cookie/credential leakage
   - request counter per task
   - response-size enforcement during streaming/download (use `URLSession.bytes(for:delegate:)` for incremental byte counting)
   - redirect target validation before following redirects
   - **maximum redirect chain length: 5** (set via `URLSessionConfiguration`). Clarify whether redirect hops count toward `maxRequests`.
   - generic or empty `User-Agent` header (do not identify Ora)
   - disable `Referer` headers (`httpShouldSetCookies = false`, set `Referer` to empty in request headers)

5. Inject `SafeURLSession` into `URLSessionWorker`.

## Tests and Validation

- `test_validate_rejectsNonHTTPSchemesExceptHTTP`
- `test_validate_rejectsLoopback`
- `test_validate_rejectsRFC1918Ranges`
- `test_validate_rejectsLinkLocalAndUniqueLocalIPv6`
- `test_validate_rejectsCloudMetadataAddress`
- `test_validate_allowedDomains_blocksUnexpectedHost`
- `test_fetch_rejectsOversizedResponse`
- `test_fetch_rejectsUnexpectedContentType`
- `test_fetch_rejectsUnsafeRedirectTarget`
- `test_fetch_enforcesPerTaskRequestLimit`

Manual validation:
- Attempt `http://127.0.0.1/...` and confirm rejection before request.
- Attempt a redirect chain to a blocked IP and confirm it is rejected.

## Acceptance Criteria

- [x] Unsafe schemes and hosts are rejected before body download begins.
- [x] Hostnames resolving to blocked IP ranges are rejected.
- [x] Redirects are revalidated through the same policy.
- [x] Response-size and content-type limits are enforced by `SafeURLSession`.
- [x] Request-count limits are enforced per task.
- [x] The worker uses `SafeURLSession`, not raw `URLSession`.

## Risks and Open Questions

- **DNS rebinding (known v1 limitation):** v1 validates the resolved IP at DNS resolution time but does not pin it for the TCP connection. An attacker controlling a DNS server could return a safe IP during validation, then flip to a private IP before the actual connection. Mitigations for v2: use `URLSessionTaskDelegate`'s `urlSession(_:task:didFinishCollecting:)` to inspect the resolved IP via connection metrics, or use `NWConnection` with explicit endpoint pinning. For v1, additionally block cloud metadata IPs (`169.254.169.254`, `fd00:ec2::254`) with higher specificity as a partial defense.
- **Error message leakage:** Worker and safety errors surfaced to the LLM or user may contain internal file paths, resolved IPs, or hostnames. Define a user-facing error message layer that strips internal details; log full details at `.debug` level only.
