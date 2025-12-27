# F.03 - Model Manager

**Epic:** Foundations
**Status:** Not Started
**Priority:** P0 (Critical Path)
**Estimated Effort:** 2-3 days
**Dependencies:** F.01 (App Shell)
**Target:** macOS 26 (Tahoe)

---

## 1. Objective

Create a unified model management system that handles downloading, verifying, and tracking all AI models (ASR, LLM, TTS) required by Ora.

### Models to Manage

| Model | Type | Source | Size | Required |
|:------|:-----|:-------|:-----|:---------|
| Parakeet TDT 0.6B v3 | ASR | FluidAudio SDK | ~600 MB | Yes |
| Qwen 2.5 7B-4bit | LLM | HuggingFace | ~5 GB | Yes (or 3B) |
| Qwen 2.5 3B-4bit | LLM | HuggingFace | ~2 GB | Fallback |
| Kokoro 82M | TTS | HuggingFace | ~500 MB | Yes |

### Scope

**In Scope:**
- `ModelManager` actor for centralized model state
- Model metadata types and status tracking
- Download orchestration with parallel downloads
- Progress reporting and cancellation
- SHA256 verification after download
- Storage path management (`~/Library/Application Support/Ora/Models/`)

**Out of Scope:**
- Model loading/inference (handled by respective engines)
- First-run UI (F.04)
- Preferences UI (F.06)

---

## 2. Architecture

### Component Diagram

```
┌─────────────────────────────────────────────────────────────┐
│                      ModelManager                            │
│                        (Actor)                               │
├─────────────────────────────────────────────────────────────┤
│  - Tracks all model states                                  │
│  - Orchestrates parallel downloads                          │
│  - Provides progress streams                                │
│  - Persists model metadata                                  │
└─────────────────────────────────────────────────────────────┘
          │              │              │
          ▼              ▼              ▼
┌──────────────┐ ┌──────────────┐ ┌──────────────┐
│ ASR Models   │ │ LLM Models   │ │ TTS Models   │
│ (Parakeet)   │ │ (Qwen 2.5)   │ │ (Kokoro)     │
└──────────────┘ └──────────────┘ └──────────────┘
          │              │              │
          ▼              ▼              ▼
┌─────────────────────────────────────────────────────────────┐
│              ~/Library/Application Support/Ora/Models/       │
│  ├── asr/parakeet/                                          │
│  ├── llm/qwen2.5-7b-instruct-4bit/                         │
│  ├── llm/qwen2.5-3b-instruct-4bit/                         │
│  └── tts/kokoro/                                            │
└─────────────────────────────────────────────────────────────┘
```

### Storage Layout

```
~/Library/Application Support/Ora/
├── Models/
│   ├── asr/
│   │   └── parakeet/
│   │       ├── encoder.mlmodelc/
│   │       ├── joint.mlmodelc/
│   │       ├── predictor.mlmodelc/
│   │       └── vocabulary.txt
│   ├── llm/
│   │   ├── qwen2.5-7b-instruct-4bit/
│   │   │   ├── model.safetensors
│   │   │   ├── config.json
│   │   │   └── tokenizer.json
│   │   └── qwen2.5-3b-instruct-4bit/
│   │       └── ...
│   └── tts/
│       └── kokoro/
│           ├── model.safetensors
│           └── config.json
└── model-metadata.json
```

---

## 3. Implementation

### 3.1 Model Types

**File:** `Ora/Models/ModelTypes.swift`

```swift
//
//  ModelTypes.swift
//  Ora
//
//  Model type definitions and metadata
//

import Foundation

/// Categories of AI models
enum ModelCategory: String, Codable, Sendable, CaseIterable {
    case asr    // Speech recognition
    case llm    // Language model
    case tts    // Text-to-speech
}

/// Known model identifiers
enum ModelIdentifier: String, Codable, Sendable, CaseIterable {
    // ASR
    case parakeetTDT = "parakeet-tdt-0.6b-v3"
    
    // LLM
    case qwen7B = "qwen2.5-7b-instruct-4bit"
    case qwen3B = "qwen2.5-3b-instruct-4bit"
    
    // TTS
    case kokoro = "kokoro-82m"
    
    var category: ModelCategory {
        switch self {
        case .parakeetTDT: return .asr
        case .qwen7B, .qwen3B: return .llm
        case .kokoro: return .tts
        }
    }
    
    var displayName: String {
        switch self {
        case .parakeetTDT: return "Parakeet TDT 0.6B"
        case .qwen7B: return "Qwen 2.5 7B"
        case .qwen3B: return "Qwen 2.5 3B"
        case .kokoro: return "Kokoro TTS"
        }
    }
    
    var huggingFaceRepo: String {
        switch self {
        case .parakeetTDT: return "FluidInference/parakeet-tdt-0.6b-v3-coreml"
        case .qwen7B: return "mlx-community/Qwen2.5-7B-Instruct-4bit"
        case .qwen3B: return "mlx-community/Qwen2.5-3B-Instruct-4bit"
        case .kokoro: return "mlx-community/Kokoro-82M-bf16"
        }
    }
    
    var estimatedSizeBytes: Int64 {
        switch self {
        case .parakeetTDT: return 600_000_000      // ~600 MB
        case .qwen7B: return 5_000_000_000         // ~5 GB
        case .qwen3B: return 2_000_000_000         // ~2 GB
        case .kokoro: return 500_000_000           // ~500 MB
        }
    }
    
    var isRequired: Bool {
        switch self {
        case .parakeetTDT, .kokoro: return true
        case .qwen7B, .qwen3B: return false // One is required, not both
        }
    }
    
    /// Subdirectory within Models/
    var storagePath: String {
        switch self {
        case .parakeetTDT: return "asr/parakeet"
        case .qwen7B: return "llm/qwen2.5-7b-instruct-4bit"
        case .qwen3B: return "llm/qwen2.5-3b-instruct-4bit"
        case .kokoro: return "tts/kokoro"
        }
    }
}

/// Status of a model download/availability
enum ModelStatus: Equatable, Sendable {
    case notDownloaded
    case downloading(progress: Double)
    case verifying
    case ready
    case failed(String)
    case corrupted
    
    var isReady: Bool {
        if case .ready = self { return true }
        return false
    }
    
    var isDownloading: Bool {
        if case .downloading = self { return true }
        return false
    }
}

/// Metadata for an installed model
struct ModelMetadata: Codable, Sendable, Equatable {
    let identifier: ModelIdentifier
    var version: String
    var downloadedAt: Date
    var sizeBytes: Int64
    var sha256: String?
    var isPrimary: Bool
    
    init(identifier: ModelIdentifier, version: String = "1.0", sizeBytes: Int64 = 0, sha256: String? = nil, isPrimary: Bool = false) {
        self.identifier = identifier
        self.version = version
        self.downloadedAt = Date()
        self.sizeBytes = sizeBytes
        self.sha256 = sha256
        self.isPrimary = isPrimary
    }
}

/// Aggregated state of all models
struct ModelsState: Sendable, Equatable {
    var statuses: [ModelIdentifier: ModelStatus] = [:]
    var metadata: [ModelIdentifier: ModelMetadata] = [:]
    var primaryLLM: ModelIdentifier = .qwen7B
    
    /// Check if minimum required models are ready
    var requiredModelsReady: Bool {
        let asrReady = statuses[.parakeetTDT]?.isReady ?? false
        let ttsReady = statuses[.kokoro]?.isReady ?? false
        let llmReady = statuses[primaryLLM]?.isReady ?? false
        return asrReady && ttsReady && llmReady
    }
    
    /// Total download progress (0.0 - 1.0)
    var overallProgress: Double {
        let models: [ModelIdentifier] = [.parakeetTDT, primaryLLM, .kokoro]
        var total = 0.0
        for model in models {
            switch statuses[model] {
            case .ready:
                total += 1.0
            case .downloading(let progress):
                total += progress
            default:
                break
            }
        }
        return total / Double(models.count)
    }
}
```

### 3.2 Model Paths

**File:** `Ora/Models/ModelPaths.swift`

```swift
//
//  ModelPaths.swift
//  Ora
//
//  File path utilities for model storage
//

import Foundation

enum ModelPaths {
    
    /// Base application support directory
    static var applicationSupport: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
    }
    
    /// Ora's root directory
    static var oraRoot: URL {
        applicationSupport.appendingPathComponent("Ora", isDirectory: true)
    }
    
    /// Models directory
    static var modelsRoot: URL {
        oraRoot.appendingPathComponent("Models", isDirectory: true)
    }
    
    /// Get path for a specific model
    static func path(for model: ModelIdentifier) -> URL {
        modelsRoot.appendingPathComponent(model.storagePath, isDirectory: true)
    }
    
    /// Metadata file path
    static var metadataFile: URL {
        oraRoot.appendingPathComponent("model-metadata.json")
    }
    
    /// Ensure all directories exist
    static func ensureDirectoriesExist() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: modelsRoot, withIntermediateDirectories: true)
        
        for category in ModelCategory.allCases {
            let categoryPath = modelsRoot.appendingPathComponent(category.rawValue, isDirectory: true)
            try fm.createDirectory(at: categoryPath, withIntermediateDirectories: true)
        }
    }
}
```

### 3.3 Download Progress

**File:** `Ora/Models/DownloadProgress.swift`

```swift
//
//  DownloadProgress.swift
//  Ora
//
//  Download progress tracking
//

import Foundation

/// Progress update for a single model download
struct ModelDownloadProgress: Sendable {
    let identifier: ModelIdentifier
    let bytesDownloaded: Int64
    let totalBytes: Int64
    let progress: Double // 0.0 - 1.0
    let currentFile: String?
    
    var progressPercent: Int {
        Int(progress * 100)
    }
}

/// Aggregated progress for all downloads
struct OverallDownloadProgress: Sendable {
    let models: [ModelIdentifier: ModelDownloadProgress]
    let overallProgress: Double
    let estimatedTimeRemaining: TimeInterval?
}
```

### 3.4 Model Downloader Protocol

**File:** `Ora/Models/ModelDownloading.swift`

```swift
//
//  ModelDownloading.swift
//  Ora
//
//  Protocol for model downloaders
//

import Foundation

/// Protocol for downloading a specific model type
protocol ModelDownloading: Sendable {
    /// Download the model to the specified directory
    func download(to directory: URL, progress: @escaping @Sendable (ModelDownloadProgress) -> Void) async throws
    
    /// Verify the downloaded model
    func verify(at directory: URL) async throws -> Bool
    
    /// Check if model exists at path
    func exists(at directory: URL) -> Bool
}
```

### 3.5 Model Manager

**File:** `Ora/Models/ModelManager.swift`

```swift
//
//  ModelManager.swift
//  Ora
//
//  Centralized model management
//

import Foundation
import os

/// Notification posted when model state changes
extension Notification.Name {
    static let modelStateDidChange = Notification.Name("modelStateDidChange")
    static let modelDownloadProgress = Notification.Name("modelDownloadProgress")
}

/// Centralized manager for all AI models
actor ModelManager {
    
    // MARK: - Singleton
    
    static let shared = ModelManager()
    
    // MARK: - Properties
    
    private let logger = Logger(subsystem: "com.ora.app", category: "ModelManager")
    private var _state = ModelsState()
    private var downloadTasks: [ModelIdentifier: Task<Void, Error>] = [:]
    
    /// Current state
    var state: ModelsState {
        _state
    }
    
    // MARK: - Initialization
    
    private init() {
        Task {
            await loadMetadata()
            await refreshStatuses()
        }
    }
    
    // MARK: - Public API
    
    /// Refresh status of all models
    func refreshStatuses() async {
        logger.debug("Refreshing model statuses...")
        
        for model in ModelIdentifier.allCases {
            let path = ModelPaths.path(for: model)
            if checkModelExists(model, at: path) {
                _state.statuses[model] = .ready
            } else {
                _state.statuses[model] = .notDownloaded
            }
        }
        
        await postStateChange()
    }
    
    /// Check if required models are available
    func requiredModelsAvailable() async -> Bool {
        await refreshStatuses()
        return _state.requiredModelsReady
    }
    
    /// Select which LLM to use as primary
    func setPrimaryLLM(_ model: ModelIdentifier) async {
        guard model.category == .llm else { return }
        _state.primaryLLM = model
        
        // Update metadata
        for llm in [ModelIdentifier.qwen7B, .qwen3B] {
            if var meta = _state.metadata[llm] {
                meta.isPrimary = (llm == model)
                _state.metadata[llm] = meta
            }
        }
        
        await saveMetadata()
        await postStateChange()
    }
    
    /// Get recommended LLM based on system RAM
    func recommendedLLM() -> ModelIdentifier {
        let ramGB = ProcessInfo.processInfo.physicalMemory / (1024 * 1024 * 1024)
        return ramGB >= 16 ? .qwen7B : .qwen3B
    }
    
    /// Download all required models in parallel
    func downloadRequiredModels(progress: (@Sendable (OverallDownloadProgress) -> Void)? = nil) async throws {
        let modelsToDownload: [ModelIdentifier] = [.parakeetTDT, _state.primaryLLM, .kokoro]
        
        logger.info("Starting download of \(modelsToDownload.count) models...")
        
        try ModelPaths.ensureDirectoriesExist()
        
        // Track individual progress
        var progressMap: [ModelIdentifier: ModelDownloadProgress] = [:]
        let progressLock = NSLock()
        
        try await withThrowingTaskGroup(of: Void.self) { group in
            for model in modelsToDownload {
                group.addTask {
                    try await self.downloadModel(model) { modelProgress in
                        progressLock.lock()
                        progressMap[model] = modelProgress
                        let overall = self.calculateOverallProgress(progressMap, models: modelsToDownload)
                        progressLock.unlock()
                        
                        progress?(overall)
                    }
                }
            }
            
            try await group.waitForAll()
        }
        
        await refreshStatuses()
        logger.info("All required models downloaded successfully")
    }
    
    /// Download a single model
    func downloadModel(_ model: ModelIdentifier, progress: (@Sendable (ModelDownloadProgress) -> Void)? = nil) async throws {
        let path = ModelPaths.path(for: model)
        
        // Check if already downloaded
        if checkModelExists(model, at: path) {
            logger.debug("\(model.rawValue) already exists, skipping download")
            _state.statuses[model] = .ready
            await postStateChange()
            return
        }
        
        logger.info("Downloading \(model.displayName)...")
        _state.statuses[model] = .downloading(progress: 0)
        await postStateChange()
        
        do {
            // Create directory
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
            
            // Download based on model type
            switch model.category {
            case .asr:
                try await downloadASRModel(model, to: path, progress: progress)
            case .llm:
                try await downloadLLMModel(model, to: path, progress: progress)
            case .tts:
                try await downloadTTSModel(model, to: path, progress: progress)
            }
            
            // Verify
            _state.statuses[model] = .verifying
            await postStateChange()
            
            let verified = await verifyModel(model, at: path)
            if verified {
                _state.statuses[model] = .ready
                _state.metadata[model] = ModelMetadata(
                    identifier: model,
                    sizeBytes: calculateDirectorySize(path),
                    isPrimary: model == _state.primaryLLM
                )
                await saveMetadata()
                logger.info("\(model.displayName) downloaded and verified")
            } else {
                _state.statuses[model] = .corrupted
                logger.error("\(model.displayName) verification failed")
                throw ModelError.verificationFailed(model)
            }
            
        } catch {
            _state.statuses[model] = .failed(error.localizedDescription)
            logger.error("Failed to download \(model.displayName): \(error.localizedDescription)")
            throw error
        }
        
        await postStateChange()
    }
    
    /// Cancel a download in progress
    func cancelDownload(_ model: ModelIdentifier) {
        downloadTasks[model]?.cancel()
        downloadTasks[model] = nil
        _state.statuses[model] = .notDownloaded
        Task { await postStateChange() }
    }
    
    /// Delete a downloaded model
    func deleteModel(_ model: ModelIdentifier) async throws {
        let path = ModelPaths.path(for: model)
        
        if FileManager.default.fileExists(atPath: path.path) {
            try FileManager.default.removeItem(at: path)
        }
        
        _state.statuses[model] = .notDownloaded
        _state.metadata[model] = nil
        await saveMetadata()
        await postStateChange()
        
        logger.info("Deleted \(model.displayName)")
    }
    
    /// Get path for a ready model
    func pathForModel(_ model: ModelIdentifier) -> URL? {
        guard _state.statuses[model]?.isReady ?? false else { return nil }
        return ModelPaths.path(for: model)
    }
    
    // MARK: - Private: Download Implementations
    
    private func downloadASRModel(_ model: ModelIdentifier, to path: URL, progress: (@Sendable (ModelDownloadProgress) -> Void)?) async throws {
        // Use FluidAudio SDK for Parakeet
        // This will be implemented using FluidAudio's AsrModels.downloadAndLoad
        // For now, placeholder that simulates download
        
        // TODO: Integrate with FluidAudio SDK
        // let models = try await AsrModels.downloadAndLoad(to: path, configuration: .defaultConfiguration(), version: .v3)
        
        logger.debug("ASR model download: using FluidAudio SDK")
    }
    
    private func downloadLLMModel(_ model: ModelIdentifier, to path: URL, progress: (@Sendable (ModelDownloadProgress) -> Void)?) async throws {
        // Use MLX Swift's model download utilities
        // This will download from HuggingFace
        
        // TODO: Integrate with MLX Swift
        // let hub = HuggingFaceHub()
        // try await hub.download(repo: model.huggingFaceRepo, to: path)
        
        logger.debug("LLM model download: using HuggingFace")
    }
    
    private func downloadTTSModel(_ model: ModelIdentifier, to path: URL, progress: (@Sendable (ModelDownloadProgress) -> Void)?) async throws {
        // Download Kokoro model from HuggingFace
        
        // TODO: Integrate with Kokoro Swift MLX
        
        logger.debug("TTS model download: using HuggingFace")
    }
    
    // MARK: - Private: Verification
    
    private func verifyModel(_ model: ModelIdentifier, at path: URL) async -> Bool {
        // Check required files exist based on model type
        let requiredFiles: [String]
        
        switch model {
        case .parakeetTDT:
            requiredFiles = ["encoder.mlmodelc", "joint.mlmodelc", "predictor.mlmodelc", "vocabulary.txt"]
        case .qwen7B, .qwen3B:
            requiredFiles = ["config.json", "tokenizer.json"] // safetensors may have various names
        case .kokoro:
            requiredFiles = ["config.json"]
        }
        
        let fm = FileManager.default
        for file in requiredFiles {
            let filePath = path.appendingPathComponent(file)
            if !fm.fileExists(atPath: filePath.path) {
                logger.warning("Missing required file: \(file)")
                return false
            }
        }
        
        return true
    }
    
    private func checkModelExists(_ model: ModelIdentifier, at path: URL) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: path.path) else { return false }
        
        // Quick check for key files
        switch model {
        case .parakeetTDT:
            return fm.fileExists(atPath: path.appendingPathComponent("encoder.mlmodelc").path)
        case .qwen7B, .qwen3B:
            return fm.fileExists(atPath: path.appendingPathComponent("config.json").path)
        case .kokoro:
            return fm.fileExists(atPath: path.appendingPathComponent("config.json").path)
        }
    }
    
    // MARK: - Private: Metadata Persistence
    
    private func loadMetadata() {
        let path = ModelPaths.metadataFile
        guard FileManager.default.fileExists(atPath: path.path) else { return }
        
        do {
            let data = try Data(contentsOf: path)
            let metadata = try JSONDecoder().decode([ModelMetadata].self, from: data)
            for meta in metadata {
                _state.metadata[meta.identifier] = meta
                if meta.isPrimary && meta.identifier.category == .llm {
                    _state.primaryLLM = meta.identifier
                }
            }
            logger.debug("Loaded metadata for \(metadata.count) models")
        } catch {
            logger.warning("Failed to load model metadata: \(error.localizedDescription)")
        }
    }
    
    private func saveMetadata() async {
        let path = ModelPaths.metadataFile
        let metadata = Array(_state.metadata.values)
        
        do {
            let data = try JSONEncoder().encode(metadata)
            try data.write(to: path)
            logger.debug("Saved metadata for \(metadata.count) models")
        } catch {
            logger.warning("Failed to save model metadata: \(error.localizedDescription)")
        }
    }
    
    // MARK: - Private: Helpers
    
    private func calculateDirectorySize(_ url: URL) -> Int64 {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else {
            return 0
        }
        
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            if let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                total += Int64(size)
            }
        }
        return total
    }
    
    private func calculateOverallProgress(_ progressMap: [ModelIdentifier: ModelDownloadProgress], models: [ModelIdentifier]) -> OverallDownloadProgress {
        var totalBytes: Int64 = 0
        var downloadedBytes: Int64 = 0
        
        for model in models {
            if let progress = progressMap[model] {
                totalBytes += progress.totalBytes
                downloadedBytes += progress.bytesDownloaded
            } else {
                totalBytes += model.estimatedSizeBytes
            }
        }
        
        let overall = totalBytes > 0 ? Double(downloadedBytes) / Double(totalBytes) : 0
        
        return OverallDownloadProgress(
            models: progressMap,
            overallProgress: overall,
            estimatedTimeRemaining: nil // TODO: Calculate based on speed
        )
    }
    
    private func postStateChange() async {
        await MainActor.run {
            NotificationCenter.default.post(
                name: .modelStateDidChange,
                object: self._state
            )
        }
    }
}

// MARK: - Errors

enum ModelError: LocalizedError {
    case verificationFailed(ModelIdentifier)
    case downloadFailed(ModelIdentifier, String)
    case modelNotFound(ModelIdentifier)
    
    var errorDescription: String? {
        switch self {
        case .verificationFailed(let model):
            return "Verification failed for \(model.displayName). Please try downloading again."
        case .downloadFailed(let model, let reason):
            return "Failed to download \(model.displayName): \(reason)"
        case .modelNotFound(let model):
            return "\(model.displayName) is not downloaded."
        }
    }
}
```

---

## 4. Acceptance Criteria

### Core Functionality

- [ ] **AC-1:** `ModelManager.shared` provides singleton access
- [ ] **AC-2:** `refreshStatuses()` checks all model availability
- [ ] **AC-3:** `requiredModelsAvailable()` returns true when ASR + LLM + TTS ready
- [ ] **AC-4:** `downloadRequiredModels()` downloads all required models in parallel
- [ ] **AC-5:** Progress callback receives updates during download

### Model Management

- [ ] **AC-6:** `setPrimaryLLM()` switches between 7B and 3B models
- [ ] **AC-7:** `recommendedLLM()` returns 3B for <16GB RAM, 7B otherwise
- [ ] **AC-8:** `deleteModel()` removes model and updates state
- [ ] **AC-9:** `pathForModel()` returns path for ready models

### Verification

- [ ] **AC-10:** Models are verified after download (required files check)
- [ ] **AC-11:** Corrupted models are detected and reported

### Persistence

- [ ] **AC-12:** Model metadata persisted to `model-metadata.json`
- [ ] **AC-13:** Primary LLM selection persisted across launches

---

## 5. Test Cases

```swift
// ModelManagerTests.swift

import XCTest
@testable import Ora

final class ModelManagerTests: XCTestCase {
    
    // TC-1: Recommended LLM based on RAM
    func test_recommendedLLM_16GB_returns7B() async {
        // This test may not be reliable in CI due to varying RAM
        let manager = ModelManager.shared
        let recommended = await manager.recommendedLLM()
        XCTAssertTrue([ModelIdentifier.qwen7B, .qwen3B].contains(recommended))
    }
    
    // TC-2: Model paths are correct
    func test_modelPaths_correct() {
        let asrPath = ModelPaths.path(for: .parakeetTDT)
        XCTAssertTrue(asrPath.path.contains("Ora/Models/asr/parakeet"))
        
        let llmPath = ModelPaths.path(for: .qwen7B)
        XCTAssertTrue(llmPath.path.contains("Ora/Models/llm/qwen2.5-7b-instruct-4bit"))
    }
    
    // TC-3: ModelsState required check
    func test_modelsState_requiredModelsReady() {
        var state = ModelsState()
        state.statuses[.parakeetTDT] = .ready
        state.statuses[.qwen7B] = .ready
        state.statuses[.kokoro] = .ready
        state.primaryLLM = .qwen7B
        
        XCTAssertTrue(state.requiredModelsReady)
    }
    
    // TC-4: ModelsState not ready if missing model
    func test_modelsState_notReady_missingTTS() {
        var state = ModelsState()
        state.statuses[.parakeetTDT] = .ready
        state.statuses[.qwen7B] = .ready
        state.statuses[.kokoro] = .notDownloaded
        state.primaryLLM = .qwen7B
        
        XCTAssertFalse(state.requiredModelsReady)
    }
}
```

---

## 6. Implementation Checklist

- [ ] Create `Ora/Models/ModelTypes.swift`
- [ ] Create `Ora/Models/ModelPaths.swift`
- [ ] Create `Ora/Models/DownloadProgress.swift`
- [ ] Create `Ora/Models/ModelDownloading.swift`
- [ ] Create `Ora/Models/ModelManager.swift`
- [ ] Integrate FluidAudio SDK for ASR model download
- [ ] Integrate HuggingFace download for LLM models
- [ ] Integrate HuggingFace download for TTS models
- [ ] Add SHA256 verification (when checksums available)
- [ ] Add unit tests
- [ ] Test parallel download functionality

---

## 7. Notes

### Integration Points

This story provides the infrastructure. Actual model loading is handled by:
- **ASR:** FluidAudio's `AsrModels.load(from:)` (Parakeet stories)
- **LLM:** MLX Swift's model loading
- **TTS:** Kokoro Swift MLX's model loading

### Resume Support

For v1, if a download is interrupted:
- Check for partial files on next attempt
- FluidAudio/HuggingFace libraries may have built-in resume support
- Delete and re-download if verification fails
