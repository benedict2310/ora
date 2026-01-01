# BUG: Model Download Verification Missing - Corrupted Models Accepted

**Epic:** Foundations
**Status:** Open
**Priority:** P0 (Critical)
**Severity:** Critical - Causes complete feature failure
**Discovered:** 2026-01-01
**Reporter:** Investigation during LLM gibberish debug session

---

## 1. Bug Summary

The model download system accepts corrupted or incomplete downloads as valid. Models that fail to fully download are used by the app, causing complete feature failure (gibberish LLM output, TTS failures, etc.).

## 2. Root Cause

The download verification system only checks if **required files exist**, not if they are **complete and valid**. This allows truncated downloads to pass verification.

### Evidence

The Qwen 2.5 7B model was downloaded with severe corruption:
- **Expected size:** 4086 MB (`model.safetensors`)
- **Actual size:** 111 MB (only 2.7% of expected)
- **Result:** Model passed verification, app used corrupted model, LLM produced gibberish

### Why This Happened

1. **Download interruption**: Network failure, timeout, or user cancellation during download
2. **Resume failure**: Resume may have failed silently, leaving partial file
3. **No size verification**: `verify()` only checks `FileManager.fileExists()`, not file size
4. **No checksum verification**: No SHA256 or other integrity checks

## 3. Affected Code

### `Ora/Models/ModelDownloading.swift`

The `DefaultModelDownloader.verify()` method only checks file existence:

```swift
func verify(model: ModelIdentifier, at directory: URL) async -> Bool {
    let fm = FileManager.default

    for file in model.requiredFiles {
        let filePath = directory.appendingPathComponent(file)
        // ❌ ONLY checks existence, not size or integrity
        if !fm.fileExists(atPath: filePath.path) {
            return false
        }
    }
    return true  // ❌ Passes even with truncated files
}
```

### `Ora/Models/Strategies/HuggingFaceStrategy.swift`

The download strategy:
- Uses estimated sizes for progress only, not verification
- Has `knownFiles()` but no `expectedFileSizes()`
- No post-download verification of actual bytes written

### `Ora/Utilities/HuggingFaceDownloader.swift`

The downloader:
- ✅ Tracks bytes written during download
- ❌ Does not verify final size matches `Content-Length`
- ❌ Does not report final size for verification
- ❌ Resume logic may silently fail (416 handling assumes complete)

## 4. Impact

### User Experience
- App appears to work (setup completes successfully)
- LLM produces complete gibberish instead of responses
- TTS may fail or produce garbage audio
- User has no indication the model is corrupted
- Debugging is extremely difficult (appears to be code bug)

### Time Wasted
- This bug caused hours of debugging investigating tokenization
- Initial hypothesis (chat template encoding) was incorrect
- Only discovered via inference test that showed random tokens

## 5. Required Fix

### 5.1 Add Expected File Sizes to ModelIdentifier

```swift
/// Expected sizes for critical files (in bytes)
/// Used to verify downloads are complete
var expectedFileSizes: [String: Int64] {
    switch self {
    case .qwen7B:
        return [
            "model.safetensors": 4_283_801_600,  // ~4.0 GB
            "tokenizer.json": 7_031_673,
            "config.json": 787,
        ]
    case .qwen3B:
        return [
            "model.safetensors": 1_800_000_000,  // ~1.7 GB
            // ...
        ]
    // ... other models
    }
}
```

### 5.2 Implement Size Verification in verify()

```swift
func verify(model: ModelIdentifier, at directory: URL) async -> Bool {
    let fm = FileManager.default
    let expectedSizes = model.expectedFileSizes

    for file in model.requiredFiles {
        let filePath = directory.appendingPathComponent(file)
        
        // Check existence
        guard fm.fileExists(atPath: filePath.path) else {
            logger.warning("Verification failed: missing \(file)")
            return false
        }
        
        // Check size for files with expected sizes
        if let expectedSize = expectedSizes[file] {
            do {
                let attrs = try fm.attributesOfItem(atPath: filePath.path)
                let actualSize = attrs[.size] as? Int64 ?? 0
                
                // Allow 1% tolerance for minor variations
                let tolerance = Int64(Double(expectedSize) * 0.01)
                if abs(actualSize - expectedSize) > tolerance {
                    logger.error("Verification failed: \(file) size mismatch. Expected: \(expectedSize), Actual: \(actualSize)")
                    return false
                }
            } catch {
                logger.error("Verification failed: cannot read attributes for \(file)")
                return false
            }
        }
    }

    logger.debug("Verification passed for \(model.displayName)")
    return true
}
```

### 5.3 Add Post-Download Verification

In `HuggingFaceStrategy.download()`, after all files are downloaded:

```swift
// Verify download integrity
let verificationPassed = await DefaultModelDownloader.shared.verify(model: model, at: directory)
if !verificationPassed {
    // Clean up partial download
    try? FileManager.default.removeItem(at: directory)
    throw ModelError.downloadFailed(model, "Download verification failed - files may be corrupted")
}
```

### 5.4 Verify Content-Length Match in HuggingFaceDownloader

After streaming download completes, verify bytes match:

```swift
// After download loop completes
let expectedBytes = totalBytes
if expectedBytes > 0 && bytesWritten != expectedBytes {
    logger.error("Download incomplete: expected \(expectedBytes), got \(bytesWritten)")
    try? FileManager.default.removeItem(at: destination)
    throw DownloadError.incompleteDownload(expected: expectedBytes, actual: bytesWritten)
}
```

### 5.5 Add Model Sanity Check at Load Time

In `LLMService.prepare()`, run a quick inference probe:

```swift
// After model loads, run sanity check
let sanityTokens = try context.tokenizer.applyChatTemplate(messages: [
    ["role": "user", "content": "Hi"]
])
let result = try MLXLMCommon.generate(
    promptTokens: sanityTokens,
    parameters: GenerateParameters(maxTokens: 5, temperature: 0.0),
    model: context.model,
    tokenizer: context.tokenizer,
    didGenerate: { _ in .stop }
)
// If result contains only garbage tokens, model is likely corrupted
```

## 6. Testing Requirements

### Unit Tests
- [ ] `test_verify_rejectsFileTooSmall` - File exists but wrong size
- [ ] `test_verify_acceptsCorrectSize` - File exists with correct size
- [ ] `test_download_failsOnIncompleteTransfer` - Simulate network failure
- [ ] `test_download_verifiesAfterComplete` - Verify runs post-download

### Integration Tests
- [ ] Download model, interrupt, resume, verify final size
- [ ] Corrupt a model file, verify detection at load time

### Manual Testing
- [ ] Delete model, re-download, verify completes
- [ ] Say "hello" and get coherent response

## 7. Files to Modify

| File | Change |
|------|--------|
| `Ora/Models/ModelTypes.swift` | Add `expectedFileSizes` computed property |
| `Ora/Models/ModelDownloading.swift` | Update `verify()` to check sizes |
| `Ora/Models/Strategies/HuggingFaceStrategy.swift` | Add post-download verification |
| `Ora/Utilities/HuggingFaceDownloader.swift` | Verify Content-Length match, add new error type |
| `Ora/LLM/LLMService.swift` | Add model sanity check at load time |
| `OraTests/Models/ModelDownloaderTests.swift` | Add size verification tests |

## 8. Acceptance Criteria

- [ ] `verify()` rejects files that are significantly smaller than expected
- [ ] Download fails gracefully if transfer is incomplete
- [ ] Corrupted models are detected before use
- [ ] User sees clear error message if model is corrupted
- [ ] Partial downloads are cleaned up, not left as "valid"

## 9. Related Issues

- LLM gibberish output (symptom of this bug)
- Potential TTS failures (same root cause)
- ASR could be affected (uses different strategy but same pattern)

## 10. Notes

This bug is particularly insidious because:
1. The app appears to work normally during setup
2. The failure mode (gibberish) looks like a code bug, not data corruption
3. There's no user-visible indication the model is bad
4. Debugging led down wrong paths (tokenization, chat templates)

The fix should prioritize **early detection** (at download time) over **late detection** (at inference time), but both layers are valuable defense-in-depth.
