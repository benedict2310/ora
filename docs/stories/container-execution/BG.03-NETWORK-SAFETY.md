# BG.03 - Network Safety Policy

**Epic:** Background Tasks
**Status:** Not Started
**Priority:** P1 (High)
**Estimated Effort:** 1 day
**Dependencies:** BG.02
**Target:** macOS 26 (Tahoe)
**Design Reference:** BG.00

---

## 1. Objective

Prevent unsafe network behavior from background workers by enforcing URL validation, IP range blocking, response size limits, and rate limiting — all on the host side before any request reaches the network.

## 2. User Story

As a **user**, I want Ora to **only fetch safe, public URLs** so that **background tasks cannot access my local network, private services, or download excessively large files**.

## 3. Scope

### In Scope

- Host-side URL validation before worker dispatch
- Block RFC1918 / link-local / loopback IP ranges
- Block non-HTTP(S) URL schemes (`file://`, `ftp://`, custom schemes)
- Per-request response size limit (5MB default)
- Per-request timeout (30s default, 120s max)
- Content-type allowlist (text/html, application/json, text/plain, application/xml)
- Optional per-task domain allowlist
- Rate limiting: max 10 HTTP requests per task
- DNS resolution validation (resolve hostname, check IP is not private before connecting)

### Out of Scope

- Container-level network policy (Phase 3)
- XPC Service sandbox network restrictions (Phase 2)
- TLS certificate pinning
- Cookie/session management (workers use ephemeral sessions)
- Proxy configuration

## 4. Architecture Alignment

### Component Placement

```
Ora/BackgroundTasks/
  ├── Safety/
  │   ├── NetworkSafetyPolicy.swift     // Policy definition + validation
  │   ├── URLValidator.swift            // URL scheme, IP range, domain checks
  │   └── SafeURLSession.swift          // URLSession wrapper enforcing policy
  └── ... (existing from BG.01, BG.02)
```

### Validation Flow

```
BackgroundTaskManager.enqueue(task)
  │
  ├── For each URL in task.inputs.urls:
  │     │
  │     ├── URLValidator.validate(url, policy: task.policy)
  │     │   ├── Check scheme (https:// or http:// only)
  │     │   ├── Check hostname (not empty, not IP literal in private range)
  │     │   ├── DNS resolve → check all resolved IPs are public
  │     │   └── Check domain allowlist (if specified)
  │     │
  │     └── If validation fails → reject task with descriptive error
  │
  └── Dispatch to worker with SafeURLSession (enforces runtime limits)
```

### IP Range Blocking

Block all requests that would resolve to:

| Range | CIDR | Purpose |
|:------|:-----|:--------|
| Loopback | `127.0.0.0/8`, `::1` | Localhost |
| Private A | `10.0.0.0/8` | Private network |
| Private B | `172.16.0.0/12` | Private network |
| Private C | `192.168.0.0/16` | Private network |
| Link-local | `169.254.0.0/16`, `fe80::/10` | Link-local |
| AWS metadata | `169.254.169.254` | Cloud metadata service |
| Docker bridge | `172.17.0.0/16` | Container networking |

### Integration with Worker

```swift
// SafeURLSession wraps URLSession with policy enforcement
actor SafeURLSession {
    private let policy: NetworkSafetyPolicy
    private let session: URLSession  // ephemeral

    func fetch(url: URL) async throws -> (Data, URLResponse) {
        // 1. Validate URL (scheme, hostname)
        try URLValidator.validate(url, policy: policy)

        // 2. DNS resolve and check IPs
        try await URLValidator.validateResolvedIPs(for: url)

        // 3. Fetch with size limit delegate
        let (data, response) = try await session.data(from: url)

        // 4. Validate content type
        try URLValidator.validateContentType(response, policy: policy)

        // 5. Check response size
        guard data.count <= policy.maxResponseBytes else {
            throw NetworkSafetyError.responseTooLarge(data.count, limit: policy.maxResponseBytes)
        }

        return (data, response)
    }
}
```

## 5. Implementation Plan (Draft)

### 5.1 Files to Create

- `Ora/BackgroundTasks/Safety/NetworkSafetyPolicy.swift` — Policy struct with configurable limits
- `Ora/BackgroundTasks/Safety/URLValidator.swift` — Static validation methods (scheme, IP, domain, content type)
- `Ora/BackgroundTasks/Safety/SafeURLSession.swift` — Policy-enforcing URLSession wrapper
- `Ora/BackgroundTasks/Safety/NetworkSafetyError.swift` — Typed error enum
- `OraTests/BackgroundTasks/URLValidatorTests.swift` — Validation unit tests
- `OraTests/BackgroundTasks/SafeURLSessionTests.swift` — Integration tests with URLProtocol mocking

### 5.2 Files to Modify

- `Ora/BackgroundTasks/Workers/URLSessionWorker.swift` — Use `SafeURLSession` instead of raw `URLSession`
- `Ora/BackgroundTasks/BackgroundTaskPolicy.swift` — Add `NetworkSafetyPolicy` fields

### 5.3 Tests to Add

- `OraTests/BackgroundTasks/URLValidatorTests.swift`:
  - `test_validate_httpsURL_passes`
  - `test_validate_httpURL_passes`
  - `test_validate_fileURL_rejects`
  - `test_validate_ftpURL_rejects`
  - `test_validate_customScheme_rejects`
  - `test_validate_localhostIP_rejects`
  - `test_validate_privateRangeA_rejects`
  - `test_validate_privateRangeB_rejects`
  - `test_validate_privateRangeC_rejects`
  - `test_validate_linkLocal_rejects`
  - `test_validate_awsMetadata_rejects`
  - `test_validate_publicIP_passes`
  - `test_validate_domainAllowlist_rejectsUnlisted`
  - `test_validate_domainAllowlist_allowsListed`
  - `test_validateContentType_htmlPasses`
  - `test_validateContentType_jsonPasses`
  - `test_validateContentType_imageFails`
  - `test_validateContentType_binaryFails`
- `OraTests/BackgroundTasks/SafeURLSessionTests.swift`:
  - `test_fetch_validURL_returnsData`
  - `test_fetch_oversizedResponse_throws`
  - `test_fetch_rateLimitExceeded_throws`

### 5.4 Dependencies/Config

- None (uses Foundation networking APIs)

## 6. Acceptance Criteria

- [ ] AC-1: URLs with non-HTTP(S) schemes are rejected before any network request
- [ ] AC-2: URLs resolving to RFC1918, loopback, or link-local IPs are rejected
- [ ] AC-3: AWS metadata endpoint (169.254.169.254) is explicitly blocked
- [ ] AC-4: Response size exceeding 5MB (default) aborts the request
- [ ] AC-5: Content-type not in allowlist is rejected
- [ ] AC-6: Per-task domain allowlist restricts requests to specified domains only
- [ ] AC-7: Rate limit (10 requests/task default) is enforced
- [ ] AC-8: All validation errors include descriptive messages for debugging/audit
- [ ] AC-9: DNS resolution check catches hostname-based SSRF (e.g., `localhost.attacker.com` resolving to 127.0.0.1)

## 7. Verification Plan

### Automated Tests

- [ ] URL scheme validation tests (all blocked schemes)
- [ ] IP range tests for all private/reserved ranges
- [ ] Content-type allowlist tests
- [ ] Response size limit tests (mock with URLProtocol)
- [ ] Rate limit enforcement test
- [ ] DNS resolution validation test (mock DNS)

### Manual Tests

- [ ] Attempt to fetch a localhost URL — verify rejection
- [ ] Attempt to fetch a private network IP — verify rejection
- [ ] Fetch a large file (>5MB) — verify abort at limit
- [ ] Fetch a binary file — verify content-type rejection

## 8. Performance / Reliability Considerations

- DNS resolution adds latency per request (~10-50ms); acceptable for background tasks
- IP validation is O(1) per address (CIDR range check)
- Rate limiting uses a simple counter per task (no sliding window needed)

## 9. Risks & Mitigations

- **DNS rebinding attacks** — Validate IP after DNS resolution, before HTTP connection. Re-validate on redirect
- **Redirect to private IP** — `SafeURLSession` validates redirect target URLs through the same policy
- **IPv6 bypass** — Include IPv6 private ranges (`::1`, `fe80::/10`, `fc00::/7`) in block list
- **TOC/TOU race in DNS** — Mitigated by URLSession's connection-level checks; for Phase 2/3, use connect-time IP validation

## 10. Open Questions

- Should we support HTTP (not HTTPS) URLs? (Proposed: yes, some content is HTTP-only; warn but don't block)
- Should we allow configuring the blocked IP ranges? (Proposed: no — always block private ranges; only domain allowlist is configurable)

---

## Implementation Summary

(TBD after implementation.)

## Code Review Findings

(TBD by review agent.)

## Completion Status

(TBD after merge.)
