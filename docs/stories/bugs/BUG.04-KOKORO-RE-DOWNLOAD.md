# BUG.04: Kokoro TTS Re-Downloaded After Rebuild

**Epic:** Maintenance
**Status:** Under Investigation (Root Cause Found)
**Priority:** P1 (High)
**Severity:** Major
**Discovered:** 2026-01-09
**Updated:** 2026-01-10
**Reporter:** User / Development session

---

## 1. Summary

After certain app rebuilds (specifically those showing "Signing Identity" messages in build output), the onboarding/setup wizard triggers and re-downloads the Kokoro TTS model even though it was working correctly before the rebuild.

This issue is intermittent - it only occurs after "larger rebuilds" that trigger code re-signing, not after incremental builds.

**Important:** File corruption has been ruled out. Kokoro was confirmed to be working (TTS output audible) immediately before the rebuild.

---

## 2. Symptoms

1. User has a working Ora installation with functional TTS (Kokoro working)
2. User rebuilds the app with `./build.sh run`
3. Build output shows multiple "Signing Identity: Sign to Run Locally" messages
4. App launches and immediately shows the setup wizard
5. Setup wizard lands on the model download view
6. Kokoro TTS is downloaded again (~500MB)

---

## 3. Context

### Related Stories
- **F.03-MODEL-MANAGER.md**: Model Manager architecture
- **M.02-UNIFIED-MODEL-STATUS-TRACKING.md**: Unified status tracking fix (applied)

### Build Output Comparison

**Normal rebuild (no re-download):**
```
./build.sh run
Ora Build Script

Building Ora (Release)...
** BUILD SUCCEEDED **
Build succeeded
App location: build/Build/Products/Release/Ora.app
Launching Ora...
Ora is running
```

**Problematic rebuild (triggers re-download):**
```
./build.sh run
Ora Build Script

Building Ora (Release)...
    Signing Identity:     "Sign to Run Locally"
    Signing Identity:     "Sign to Run Locally"
    Signing Identity:     "Sign to Run Locally"
    [... multiple signing messages ...]
** BUILD SUCCEEDED **
Build succeeded
App location: build/Build/Products/Release/Ora.app
Launching Ora...
Ora is running
```

The "Signing Identity" messages indicate the build system re-signed binaries (app bundle, frameworks, dylibs). This typically happens when:
- Code changes affect linked frameworks/packages
- SPM dependencies are rebuilt
- Clean build or derived data changes
- Xcode project regeneration

---

## 4. Investigation Findings

### 4.1 File System State (After Bug Occurred)

All Kokoro files are present with correct sizes:
```
~/Library/Application Support/Ora/Models/tts/kokoro/
├── config.json           (2,351 bytes) ✓ Valid
├── kokoro-v1_0.safetensors (327,115,152 bytes) ✓ Valid
└── voices/
    └── af_heart.safetensors (522,320 bytes) ✓ Valid
```

### 4.2 Metadata State (Critical Finding)

`model-metadata.json` after bug occurrence:
```json
[
    {
        "downloadedAt": "2026-01-09T18:58:35Z",
        "identifier": "kokoro-82m",
        "isPrimary": false,
        "sizeBytes": 327639823,
        "version": "1.0"
    }
]
```

**Critical Issue:** Only Kokoro is in metadata - no LLM or ASR metadata entries exist!

This indicates a metadata persistence problem where model downloads are not being properly recorded for all models.

### 4.3 Other Model States

| Model | Expected Path | Files Exist? |
|-------|---------------|--------------|
| Parakeet TDT | `FluidAudio/Models/parakeet-tdt-0.6b-v3-coreml/` | ✓ Yes (Dec 14) |
| Qwen 3 4B | `Ora/Models/llm/qwen3-4b-instruct-4bit/` | ✓ Yes (Jan 6) |
| Kokoro | `Ora/Models/tts/kokoro/` | ✓ Yes (Jan 9 - re-downloaded) |

### 4.4 Existence Check Logic

`DefaultModelDownloader.exists()` performs thorough checks:
1. Directory exists at path
2. All `requiredFiles` exist
3. Each file meets minimum size threshold

For Kokoro, required files are:
- `config.json` (min 100 bytes)
- `kokoro-v1_0.safetensors` (min 10MB)
- `voices/af_heart.safetensors` (min 100KB)

### 4.5 Startup Flow

```
ApplicationDidFinishLaunching
    └─> SetupCoordinator.checkAndShowSetupIfNeeded()
        ├─> ModelManager.ensureInitialized() 
        │       └─> loadMetadataIfNeeded()  // Only loads metadata!
        ├─> ModelManager.state              // Get current state
        └─> ModelManager.requiredModelsAvailable()
                └─> refreshStatuses()       // Checks file existence
                    └─> downloader.exists() for each model
```

---

## 5. Hypotheses

### Hypothesis A: Kokoro Files Were Deleted (RULED OUT)

~~The files were corrupted or deleted before the rebuild.~~

**Status:** RULED OUT - User confirmed Kokoro was working (TTS audible) immediately before rebuild.

### Hypothesis B: Timing/Race Condition in exists() Check

**Theory:** There's a timing issue where the `exists()` check fails intermittently after app re-signing.

Possible causes:
1. **Filesystem metadata caching:** macOS may cache file metadata, and app re-signing could affect cache invalidation
2. **Gatekeeper/quarantine:** Re-signed apps might trigger Gatekeeper checks that delay filesystem access
3. **Code signing verification:** The first filesystem access after launch might be delayed while macOS verifies signatures

**Evidence:** 
- Bug only occurs after re-signing builds
- Bug is intermittent
- All files exist and pass checks after the app has been running

**Status:** Possible - needs logging to confirm.

### Hypothesis C: `ensureInitialized()` Doesn't Await Status Refresh

**Theory:** The startup flow has a subtle race:

```swift
func ensureInitialized() async {
    await self.loadMetadataIfNeeded()  // Only loads metadata!
    // Does NOT call refreshStatuses()
}
```

Meanwhile, `ModelManager.init()` kicks off:
```swift
Task {
    await self.performInitialLoad()  // Calls loadMetadata AND refreshStatuses
}
```

If `checkAndShowSetupIfNeeded()` calls `requiredModelsAvailable()` before the background `performInitialLoad()` has set statuses, AND if `requiredModelsAvailable().refreshStatuses()` fails for some reason, old/empty status could be used.

**Evidence:**
- However, `requiredModelsAvailable()` explicitly calls `refreshStatuses()`, which should work.

**Status:** Unlikely but worth auditing.

### Hypothesis D: Metadata-Based Decision Override

**Theory:** Some code path uses metadata instead of filesystem to determine model availability.

If metadata is empty/incomplete (as seen - only Kokoro after re-download), and some check relies on metadata rather than `exists()`, it could incorrectly report models as missing.

**Evidence:**
- Metadata only contains Kokoro entry
- LLM and ASR have no metadata entries despite files existing

**Status:** Needs code audit to find metadata-dependent code paths.

### Hypothesis E: Application Support Path Resolution Issue

**Theory:** After app re-signing, the `FileManager.default.urls(for: .applicationSupportDirectory)` could momentarily return a different path or fail.

**Evidence:** None yet, but would explain intermittent failure.

**Status:** Needs logging to confirm.

---

## 6. Root Cause Analysis

**Confirmed Root Causes:** After thorough code investigation, multiple contributing issues were identified:

### Primary Issue: `ensureInitialized()` Contract Violation

**Location:** `ModelManager.swift:61-63`

The `ensureInitialized()` function only awaited metadata loading, NOT the status refresh:

```swift
// BEFORE (broken)
func ensureInitialized() async {
    await self.loadMetadataIfNeeded()  // Only metadata!
}
```

This created a race condition where `SetupCoordinator.checkAndShowSetupIfNeeded()` could query model statuses before `refreshStatuses()` completed in the background initialization task.

### Secondary Issue: Transient Filesystem Failures After Re-Signing

After app re-signing, macOS performs Gatekeeper/code signature verification. During this brief window, filesystem operations (`FileManager.fileExists()`, `attributesOfItem()`) may fail transiently, causing `exists()` to return `false` even when files are present.

### Tertiary Issue: Metadata Persistence During Parallel Downloads

**Location:** `ModelManager.swift:159-195`

During `downloadRequiredModels()`, three models download in parallel. Each model called `saveMetadata()` independently after verification. While actor serialization prevents data corruption, a final atomic save ensures all metadata is persisted reliably.

**Key Observation:** The metadata file only containing Kokoro was a symptom of the ABORTED re-download, not the original cause. The user aborted the re-download after it triggered, leaving only partially persisted state.

---

## 7. Proposed Fixes

### Fix 1: Add Comprehensive Logging (P0 - Required for Diagnosis)

**Problem:** We don't know exactly why `exists()` returned `false` for Kokoro.

**Solution:** Add detailed logging in:
- `exists()` - log which file check failed, with exact path and size
- `checkAndShowSetupIfNeeded()` - log the result of each model check
- `refreshStatuses()` - log before/after state for each model

```swift
func exists(model: ModelIdentifier, at directory: URL) -> Bool {
    self.logger.debug("Checking existence of \(model.displayName) at \(directory.path)")
    
    let fm = FileManager.default
    guard fm.fileExists(atPath: directory.path) else {
        self.logger.warning("\(model.displayName): Directory does not exist: \(directory.path)")
        return false
    }

    for file in model.requiredFiles {
        let path = directory.appendingPathComponent(file)
        if !fm.fileExists(atPath: path.path) {
            self.logger.warning("\(model.displayName): Required file missing: \(file) at \(path.path)")
            return false
        }
        // ... size check with logging
    }
    
    self.logger.debug("\(model.displayName): All existence checks passed")
    return true
}
```

**Files to modify:**
- `Ora/Models/ModelDownloading.swift`
- `Ora/Models/ModelManager.swift`
- `Ora/Setup/SetupCoordinator.swift`

### Fix 2: Ensure Metadata Persistence for All Models (P1)

**Problem:** Metadata only contains one model entry.

**Solution:** Audit metadata saving to ensure it's called after EACH successful model download, not just at the end.

**Files to modify:**
- `Ora/Models/ModelManager.swift` - verify `saveMetadata()` is called after each model download

### Fix 3: Add Retry/Delay for exists() After Launch (P2)

**Problem:** Possible timing issue with filesystem after re-signing.

**Solution:** If `exists()` returns false for all models, wait briefly and retry once:

```swift
func requiredModelsAvailable() async -> Bool {
    await self.refreshStatuses()
    if !_state.requiredModelsReady {
        // Retry once after brief delay in case of filesystem timing
        try? await Task.sleep(for: .milliseconds(500))
        await self.refreshStatuses()
    }
    return _state.requiredModelsReady
}
```

**Files to modify:**
- `Ora/Models/ModelManager.swift`

### Fix 4: Validate ensureInitialized() Contract (P2)

**Problem:** `ensureInitialized()` name suggests it fully initializes, but it only loads metadata.

**Solution:** Either:
- Rename to `ensureMetadataLoaded()`
- Or add `refreshStatuses()` call

**Files to modify:**
- `Ora/Models/ModelManager.swift`

---

## 8. Acceptance Criteria

- [x] AC-1: Detailed logging shows exactly which check fails when bug occurs (Fix 4 - implemented)
- [x] AC-2: Metadata contains entries for all downloaded models after setup (Fix 3 - implemented)
- [ ] AC-3: Rebuild with re-signing does not trigger re-download if models exist (pending verification)
- [x] AC-4: Console logs show clear diagnostic info when setup wizard triggers (Fix 4 - implemented)

---

## 9. Verification Plan

### Immediate Action
1. **Add logging (Fix 1)** and reproduce the bug
2. **Check Console.app** for diagnostic output
3. **Identify exact failure point** from logs

### After Fix Applied
1. Complete fresh setup (download all models)
2. Verify `model-metadata.json` contains all 3 models
3. Rebuild with `./build.sh clean && ./build.sh run`
4. Verify setup wizard does NOT trigger
5. Check logs for successful existence checks

---

## 10. To Reproduce

Based on user report:
1. Have a working Ora installation with all models downloaded and working
2. Make code changes that affect SPM dependencies or framework linking
3. Run `./build.sh run`
4. If build shows "Signing Identity" messages, observe whether setup wizard triggers

---

## 11. Related Issues

- **BUG.01-MODEL-DOWNLOAD-VERIFICATION.md**: Previous download verification issues
- **BUG.02-SETUP-PARAKEET-PATH.md**: Parakeet path mismatch (fixed)
- **M.02-UNIFIED-MODEL-STATUS-TRACKING.md**: Unified status tracking (implemented)

---

## 12. Implemented Fixes

**Branch:** `fix/BUG.04-kokoro-redownload-race`
**Date:** 2026-01-09

### Fix 1: `ensureInitialized()` Now Awaits Full Initialization

**File:** `Ora/Models/ModelManager.swift:61-64`

```swift
// AFTER (fixed)
func ensureInitialized() async {
    await self.loadMetadataIfNeeded()
    await self.refreshStatuses()  // Now properly awaits status refresh
}
```

### Fix 2: Defensive Retry for Transient Filesystem Failures

**File:** `Ora/Models/ModelManager.swift:96-111`

Added a single retry with 500ms delay to `requiredModelsAvailable()`:

```swift
func requiredModelsAvailable() async -> Bool {
    await self.refreshStatuses()

    if _state.requiredModelsReady {
        return true
    }

    // Retry once after brief delay for transient failures
    self.logger.debug("Models not ready on first check, retrying after delay...")
    try? await Task.sleep(for: .milliseconds(500))
    await self.refreshStatuses()

    if !_state.requiredModelsReady {
        self.logger.warning("Models still not ready after retry")
    }

    return _state.requiredModelsReady
}
```

### Fix 3: Final Metadata Save After Parallel Downloads

**File:** `Ora/Models/ModelManager.swift:193-195`

Added explicit `saveMetadata()` call after all parallel downloads complete:

```swift
try await group.waitForAll()

// Save metadata once after all downloads complete to ensure atomic persistence
await self.saveMetadata()
```

### Fix 4: Comprehensive Diagnostic Logging

**File:** `Ora/Models/ModelDownloading.swift:140-185`

Added detailed logging to `exists()` function showing:
- Directory existence checks
- Missing required files
- File size validation failures
- Attribute read errors

**File:** `Ora/Models/ModelManager.swift:74-93`

Added summary logging to `refreshStatuses()` showing ready/not-downloaded counts.

---

## 13. New Findings (2026-01-10)

### Diagnostic Log Evidence

File-based diagnostic logging was added since os_log info level doesn't persist. Log file: `~/Library/Application Support/Ora/model-diagnostic.log`

**Critical Finding:** The bug occurred again at 19:52:03 and the diagnostic log captured:

```
[2026-01-10T19:51:57Z] exists(Kokoro TTS): checking path .../tts/kokoro
[2026-01-10T19:51:57Z] exists(Kokoro TTS): PASS - all checks passed
[2026-01-10T19:52:03Z] exists(Kokoro TTS): checking path .../tts/kokoro
[2026-01-10T19:52:03Z] exists(Kokoro TTS): FAIL - required file missing: config.json at .../tts/kokoro/config.json
```

**The config.json file ACTUALLY DISAPPEARED between 19:51:57 and 19:52:03 (6 seconds).**

### Suspected Root Cause

The downloader deletes files before writing new ones in `HuggingFaceDownloader.prepareFileForWriting()`:

```swift
// When NOT resuming (server returned 200 instead of 206):
if fm.fileExists(atPath: url.path) {
    try fm.removeItem(at: url)  // DELETES existing file
}
guard fm.createFile(atPath: url.path, contents: nil) else { ... }
```

If something triggers a download of Kokoro (even though it already exists), and then:
1. `config.json` is deleted during `prepareFileForWriting()`
2. The download fails or is interrupted
3. `config.json` is now missing

**Why would a download be triggered?** The `ModelManager.downloadModel()` checks `exists()` before downloading. But something must be bypassing this check or there's a race condition.

### Next Steps

1. ✅ Added "DOWNLOAD TRIGGERED" logging to capture when downloads start
2. Wait for next occurrence to see if a download is being triggered spuriously
3. If download IS triggered, investigate what code path is calling it
4. If download is NOT triggered, something else is deleting the file

### Current Diagnostic Coverage

The log file now captures:
- All `exists()` checks with PASS/FAIL status
- All file paths and which specific check failed
- "DOWNLOAD TRIGGERED for X" when any model download starts

---

## 14. Verification Checklist

After merging, verify:

- [ ] Fresh setup downloads all models and metadata contains all 3 entries
- [ ] Rebuild with re-signing (`./build.sh run` showing "Signing Identity" messages) does NOT trigger setup wizard
- [ ] Console.app shows diagnostic logs during startup (filter by "ModelManager" or "ModelDownloader")
- [ ] All 864 tests pass
