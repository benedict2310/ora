# F.09 - Model Download Implementation

**Epic:** Foundations
**Status:** Not Started
**Priority:** P0 (Critical Path)
**Estimated Effort:** 1 day
**Dependencies:** F.03 (Model Manager), F.04 (First Run Setup)
**Target:** macOS 26 (Tahoe)

---

## 1. Objective

Implement robust, resumable, and parallel downloading for all AI models (ASR, LLM, TTS) by wiring `DefaultModelDownloader` to concrete download strategies.

This story bridges the gap between the `ModelManager` architecture (F.03) and the Setup Wizard UI (F.04) by providing the actual network implementation.

### Architecture Alignment

*   **ASR (Parakeet):** Uses `ParakeetBootstrap` (FluidAudio SDK) as defined in `A.02`.
*   **LLM (Qwen 2.5):** Uses `HuggingFaceDownloader` (custom implementation) to fetch files compatible with `MLXLMCommon.load` (folder with `config.json`, `tokenizer.json`, `.safetensors`).
*   **TTS (Kokoro):** Uses `HuggingFaceDownloader` to fetch files compatible with Kokoro MLX.

---

## 2. Implementation Strategy

### 2.1 Dependencies

**File:** `project.yml`

Add `mlx-swift` to the project. This is required not just for future inference but to ensure we are downloading models compatible with its loader.

```yaml
packages:
  FluidAudio:
    url: https://github.com/FluidInference/FluidAudio
    from: "0.8.0"
  MLX:
    url: https://github.com/ml-explore/mlx-swift
    from: "0.10.0"

targets:
  Ora:
    dependencies:
      - package: FluidAudio
        product: FluidAudio
      - package: MLX
        product: MLX
      - package: MLX
        product: MLXRandom
      - package: MLX
        product: MLXNN
      - package: MLX
        product: MLXOptimizers
```

### 2.2 HuggingFace Downloader Utility

**File:** `Ora/Utilities/HuggingFaceDownloader.swift`

A dedicated actor/class responsible for downloading individual files from HuggingFace with:
*   **Progress Reporting:** Granular byte-level progress for UI.
*   **Resumability:** Uses `Range` headers if a partial file exists (critical for 5GB models).
*   **Validation:** Checks HTTP 200/206 status codes.

```swift
protocol FileDownloader: Sendable {
    func download(
        url: URL,
        to destination: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws
}
```

*Note: For v1, we implement a direct `URLSession` delegate-based downloader to ensure we control the progress stream and file placement exactly where `ModelPaths` expects them.*

### 2.3 Model Downloader Refactoring

**File:** `Ora/Models/ModelDownloading.swift`

Refactor `DefaultModelDownloader` to use a Strategy Pattern, decoupling the "Coordinator" from the "Mechanism".

```swift
// Strategy Interface
protocol ModelDownloadStrategy: Sendable {
    func download(
        model: ModelIdentifier,
        to directory: URL,
        progress: @escaping @Sendable (ModelDownloadProgress) -> Void
    ) async throws
}

// Concrete Strategies
struct FluidAudioStrategy: ModelDownloadStrategy { ... }
struct HuggingFaceStrategy: ModelDownloadStrategy { ... }

// Updated DefaultModelDownloader
final class DefaultModelDownloader: ModelDownloader {
    // Selects strategy based on ModelCategory
    // ASR -> FluidAudioStrategy
    // LLM/TTS -> HuggingFaceStrategy
}
```

### 2.4 Parakeet Integration

**File:** `Ora/Models/Strategies/FluidAudioStrategy.swift`

*   Connects to `ParakeetBootstrap.shared.downloadModels()`.
*   Since FluidAudio handles the download internally, this strategy wraps that call.
*   *Constraint:* FluidAudio v0.8.1 might not expose granular byte progress. The strategy should emit fake or coarse-grained progress (0% -> 100%) if granular data isn't available, to prevent the UI from appearing frozen.

---

## 3. Acceptance Criteria

*   [ ] **AC-1:** `project.yml` includes `mlx-swift` dependency.
*   [ ] **AC-2:** `HuggingFaceDownloader` correctly downloads large files (e.g., `model.safetensors`) to the destination.
*   [ ] **AC-3:** `DefaultModelDownloader` delegates ASR downloads to `ParakeetBootstrap`.
*   [ ] **AC-4:** `DefaultModelDownloader` delegates LLM/TTS downloads to `HuggingFaceDownloader`.
*   [ ] **AC-5:** Setup Wizard UI shows moving progress bars for Qwen (5GB) and Kokoro (500MB).
*   [ ] **AC-6:** Downloads are resumable; killing the app mid-download and restarting resumes from the last byte (or at least doesn't corrupt the file).
*   [ ] **AC-7:** Verification (`DefaultModelDownloader.verify`) passes after successful download.

---

## 4. Implementation Checklist

1.  **Project Config:** Update `project.yml` and run `xcodegen`.
2.  **Utility:** Create `Ora/Utilities/HuggingFaceDownloader.swift` with `URLSession` delegate.
3.  **Strategies:**
    *   Create `Ora/Models/Strategies/FluidAudioStrategy.swift`
    *   Create `Ora/Models/Strategies/HuggingFaceStrategy.swift`
4.  **Refactor:** Update `DefaultModelDownloader` to use these strategies.
5.  **Tests:** Add unit tests for `HuggingFaceDownloader` (mocking URLProtocol) and integration tests for `DefaultModelDownloader`.

---

## 5. Risk Assessment

*   **Risk:** `ParakeetBootstrap` dependency cycle.
    *   *Mitigation:* `FluidAudioStrategy` will be in the `Models` module but can import `Ora` types if needed, or we keep it simple since it's a monolith. The strategy just needs to call the bootstrap.
*   **Risk:** HuggingFace URL structure changes.
    *   *Mitigation:* Use the standard `/resolve/main/` endpoint format which is stable.

---

## 6. Verification Plan

*   **Manual:** Run the app, delete any existing models, and watch the Setup Wizard flow.
*   **Automated:** Unit tests for the downloader logic.

---

## Implementation Plan

### Files to Create
- `Ora/Utilities/HuggingFaceDownloader.swift` - URLSession delegate-based file downloader with resumability and progress
- `Ora/Models/Strategies/FluidAudioStrategy.swift` - Strategy wrapper for ParakeetBootstrap downloads
- `Ora/Models/Strategies/HuggingFaceStrategy.swift` - Strategy for LLM/TTS downloads using HuggingFaceDownloader

### Files to Modify
- `project.yml` - Add mlx-swift dependency for future LLM inference
- `Ora/Models/ModelDownloading.swift` - Refactor to use strategy pattern, remove placeholder implementations
- `Ora/Models/ModelTypes.swift` - Add any required file list updates for models

### Tests to Add
- `OraTests/HuggingFaceDownloaderTests.swift` - Unit tests for download utility with mocked URLProtocol
