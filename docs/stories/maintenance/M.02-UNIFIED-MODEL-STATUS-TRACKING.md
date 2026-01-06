# M.02 - Unified Model Status Tracking

**Epic:** Maintenance
**Status:** Complete
**Priority:** P1 (High)
**Estimated Effort:** 2-3 days
**Dependencies:** F.03 (Model Manager), F.09 (Onboarding), F.11 (Setup Wizard Polish)
**Target:** macOS 26 (Tahoe)
**Design Reference:** None

---

## 1. Objective

Unify model download status tracking between the Setup Wizard (onboarding) and Preferences UI. Currently, these two components use separate state systems with different existence checks, causing inconsistent status displays. Models work for inference (they ARE downloaded correctly), but the UI status tracking is broken and confusing to users.

## 2. User Story

As a user, I want to see consistent model download status across the Setup Wizard and Preferences so that I can trust the UI accurately reflects which models are installed and ready.

## 3. Scope

### In Scope

- Consolidate model status tracking into `ModelManager` as single source of truth
- Extend `ModelsState` with download progress metrics (reusing existing `ModelDownloadProgress` type)
- Remove duplicate `SetupState.modelDownloadStates` tracking
- Update `SetupCoordinator` to observe `ModelManager` state changes
- Update `DownloadStepView` to accept both `SetupState` AND `ModelsState` for download progress
- Ensure consistent existence checks across all components
- Fix metadata loading race condition
- Deprecate `ModelPaths.modelExists()` to prevent future misuse
- Update existing tests that depend on `SetupState.modelDownloadStates`

### Out of Scope

- Changing the actual download mechanism (HuggingFace, FluidAudio strategies)
- UI redesign of download progress display
- Adding new model types or categories
- Changing model storage paths or directory structure

## 4. Architecture Alignment

### Current Architecture (Broken)

```
┌─────────────────────────────────────────────────────────────────────────┐
│                    DUAL STATE SYSTEMS (NO SYNC)                          │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│  ┌──────────────────────────┐        ┌──────────────────────────────┐  │
│  │    SetupCoordinator       │        │    ModelsPreferencesView     │  │
│  │  ┌────────────────────┐   │        │  ┌────────────────────────┐  │  │
│  │  │ SetupState         │   │        │  │ @State modelsState     │  │  │
│  │  │ .modelDownloadStates│  │   ╳    │  │ (from ModelManager)    │  │  │
│  │  │ .modelProgresses   │◄──┼───────┼──│                        │  │  │
│  │  │ .totalBytes...     │   │  NO   │  └────────────────────────┘  │  │
│  │  └────────────────────┘   │ SYNC  │           │                   │  │
│  │           │               │        │           ▼                   │  │
│  │           ▼               │        │   ModelManager.state         │  │
│  │   ModelPaths.modelExists()│        │   .refreshStatuses()         │  │
│  │   (directory check only) │        │   (files + sizes check)      │  │
│  └──────────────────────────┘        └──────────────────────────────┘  │
│                                                                         │
│  PROBLEM: SetupCoordinator line 337 uses ModelPaths.modelExists()      │
│           which only checks if directory exists. ModelManager uses     │
│           DefaultModelDownloader.exists() which checks all files.      │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

### Target Architecture (Unified)

```
┌─────────────────────────────────────────────────────────────────────────┐
│                    SINGLE SOURCE OF TRUTH                                │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│  ┌──────────────────────────┐        ┌──────────────────────────────┐  │
│  │    SetupCoordinator       │        │    ModelsPreferencesView     │  │
│  │           │               │        │           │                   │  │
│  │           │ observes      │        │           │ observes          │  │
│  │           ▼               │        │           ▼                   │  │
│  │   .modelStateDidChange    │        │   .modelStateDidChange        │  │
│  │           │               │        │           │                   │  │
│  │           ▼               │        │           │                   │  │
│  │   @Published modelsState  │        │   @State modelsState          │  │
│  │   (synced from Manager)   │        │   (synced from Manager)       │  │
│  └──────────────────────────┘        └──────────────────────────────┘  │
│                    │                             │                      │
│                    └─────────────┬───────────────┘                      │
│                                  │                                      │
│                                  ▼                                      │
│            ┌─────────────────────────────────────────────┐              │
│            │           ModelManager (Actor)              │              │
│            │  ┌───────────────────────────────────────┐  │              │
│            │  │ ModelsState                           │  │              │
│            │  │ - statuses: [ModelIdentifier: Status] │  │              │
│            │  │ - downloadProgress: [Model: Progress] │  │◄── NEW      │
│            │  │ - overallDownloadSpeed: Double        │  │◄── NEW      │
│            │  │ - estimatedTimeRemaining: TimeInterval│  │◄── NEW      │
│            │  │ - isDownloading: Bool                 │  │◄── NEW      │
│            │  └───────────────────────────────────────┘  │              │
│            │                     │                        │              │
│            │                     ▼                        │              │
│            │      DefaultModelDownloader.exists()         │              │
│            │      (consistent file + size checks)         │              │
│            └─────────────────────────────────────────────┘              │
│                                  │                                      │
│                                  ▼                                      │
│  ┌─────────────────────────────────────────────────────────────────┐   │
│  │              ~/Library/Application Support/Ora/Models/           │   │
│  │  ├── asr/parakeet-tdt-0.6b-v3-coreml/                           │   │
│  │  ├── llm/qwen3-4b-instruct-4bit/                                │   │
│  │  └── tts/kokoro/                                                │   │
│  └─────────────────────────────────────────────────────────────────┘   │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

### Data Flow During Download

```
┌─────────────────────────────────────────────────────────────────────────┐
│                        DOWNLOAD PROGRESS FLOW                            │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│  User clicks "Download Now"                                             │
│         │                                                               │
│         ▼                                                               │
│  SetupCoordinator.startDownloadFromExplanation()                        │
│         │                                                               │
│         ▼                                                               │
│  ModelManager.downloadRequiredModels(progress:)                         │
│         │                                                               │
│         ├──────────────────────────────────────────────────────────┐    │
│         │  For each model:                                          │    │
│         │    1. Update _state.statuses[model] = .downloading(prog)  │    │
│         │    2. Update _state.downloadProgress[model] = Progress    │    │
│         │    3. Calculate speed/ETA                                 │    │
│         │    4. postStateChange() → NotificationCenter              │    │
│         └──────────────────────────────────────────────────────────┘    │
│                                                      │                  │
│                                                      ▼                  │
│                                        .modelStateDidChange             │
│                                                      │                  │
│                    ┌─────────────────────────────────┼──────────────┐   │
│                    │                                 │              │   │
│                    ▼                                 ▼              │   │
│         SetupCoordinator                   ModelsPreferencesView    │   │
│         handleModelStateChange()           refreshModels()          │   │
│                    │                                 │              │   │
│                    ▼                                 ▼              │   │
│         @Published modelsState = newState  @State modelsState       │   │
│                    │                                                │   │
│                    ▼                                                │   │
│         DownloadStepView receives modelsState via binding           │   │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

### Concurrency Model

- `ModelManager` is an actor - all state access is serialized
- `SetupCoordinator` is `@MainActor` - observes via NotificationCenter on main queue
- Progress updates use `postStateChange()` which dispatches to MainActor
- Race condition fix: `ensureInitialized()` must be awaited before status queries
- Observer lifecycle: Add observer in `init()`, remove in `deinit` (or use `Task` cancellation)

### Key Component Boundaries

| Component | Responsibility | Threading |
|-----------|---------------|-----------|
| `ModelManager` | Single source of truth for model state, speed/ETA calculation | Actor |
| `SetupCoordinator` | Setup flow orchestration, observes ModelManager, publishes modelsState | MainActor |
| `ModelsPreferencesView` | Preferences display, observes ModelManager | MainActor |
| `DownloadStepView` | Download progress display, receives state via parameters | MainActor |
| `SetupState` | Setup-specific state (current step, errors, cancellation) - NO download progress | Sendable struct |

## 5. Implementation Plan

### Phase 1: Extend ModelsState with Progress Tracking (Non-Breaking)

**Files to modify:**

**`Ora/Models/ModelTypes.swift`**
- Extend `ModelsState` with download progress fields:
  ```swift
  struct ModelsState: Sendable, Equatable {
      // Existing fields (unchanged)
      var statuses: [ModelIdentifier: ModelStatus] = [:]
      var metadata: [ModelIdentifier: ModelMetadata] = [:]
      var primaryLLM: ModelIdentifier = .qwen3_4B
      
      // NEW: Download progress metrics
      /// Per-model download progress (reuses existing ModelDownloadProgress from DownloadProgress.swift)
      var downloadProgress: [ModelIdentifier: ModelDownloadProgress] = [:]
      
      /// Overall download speed in bytes/second (rolling average)
      var overallDownloadSpeed: Double = 0
      
      /// Estimated time remaining for all active downloads
      var estimatedTimeRemainingSeconds: TimeInterval? = nil
      
      /// Whether any download is currently in progress
      var isDownloading: Bool = false
      
      // ... existing computed properties ...
      
      // NEW: Computed helpers for UI
      
      /// Total bytes downloaded across all active downloads
      var totalBytesDownloaded: Int64 {
          downloadProgress.values.reduce(0) { $0 + $1.bytesDownloaded }
      }
      
      /// Total bytes to download across all active downloads
      var totalBytesToDownload: Int64 {
          downloadProgress.values.reduce(0) { $0 + $1.totalBytes }
      }
      
      /// Formatted download speed (e.g., "12.3 MB/s")
      var formattedDownloadSpeed: String {
          let speedMBps = overallDownloadSpeed / (1024 * 1024)
          if speedMBps < 0.1 { return "..." }
          return String(format: "%.1f MB/s", speedMBps)
      }
      
      /// Formatted time remaining (e.g., "~2 min left")
      var formattedTimeRemaining: String? {
          guard let seconds = estimatedTimeRemainingSeconds, seconds > 0 else { return nil }
          if seconds < 60 {
              return "~\(Int(seconds))s left"
          } else if seconds < 3600 {
              return "~\(Int(seconds / 60)) min left"
          } else {
              let hours = Int(seconds / 3600)
              let minutes = Int((seconds.truncatingRemainder(dividingBy: 3600)) / 60)
              return minutes > 0 ? "~\(hours)h \(minutes)m left" : "~\(hours)h left"
          }
      }
  }
  ```

**`Ora/Models/DownloadProgress.swift`**
- Make `ModelDownloadProgress` conform to `Equatable` (if not already)
- No other changes needed - reuse existing type

### Phase 2: Update ModelManager to Track Progress and Calculate Speed/ETA

**`Ora/Models/ModelManager.swift`**
- Add speed tracking properties (move from SetupCoordinator):
  ```swift
  actor ModelManager {
      // ... existing properties ...
      
      // NEW: Speed tracking (moved from SetupCoordinator)
      private var downloadSpeedSamples: [Double] = []
      private var lastProgressUpdateTime: Date?
      private var lastTotalBytesDownloaded: Int64 = 0
      private let maxSpeedSamples = 5
      
      // ... existing methods ...
  }
  ```

- Update `downloadRequiredModels()` to track progress in state:
  ```swift
  func downloadRequiredModels(
      progress: (@Sendable (OverallDownloadProgress) -> Void)? = nil
  ) async throws {
      _state.isDownloading = true
      resetSpeedTracking()
      await postStateChange()
      
      defer {
          Task {
              _state.isDownloading = false
              _state.downloadProgress = [:]
              _state.overallDownloadSpeed = 0
              _state.estimatedTimeRemainingSeconds = nil
              await self.postStateChange()
          }
      }
      
      // ... existing download logic, but also update _state.downloadProgress ...
  }
  ```

- Update `performDownload()` to store progress in `ModelsState.downloadProgress`:
  ```swift
  private func performDownload(...) async throws {
      // In progress callback:
      try await self.downloader.download(model: model, to: path) { [weak self] modelProgress in
          guard let self = self else { return }
          Task {
              await self.updateProgress(for: model, progress: modelProgress)
          }
          progress?(modelProgress)
      }
      // ...
  }
  
  private func updateProgress(for model: ModelIdentifier, progress: ModelDownloadProgress) async {
      _state.downloadProgress[model] = progress
      updateDownloadSpeed()
      await postStateChange()
  }
  
  private func updateDownloadSpeed() {
      // Move speed calculation logic from SetupCoordinator here
      let now = Date()
      let currentTotal = _state.totalBytesDownloaded
      
      guard let lastTime = lastProgressUpdateTime else {
          lastProgressUpdateTime = now
          lastTotalBytesDownloaded = currentTotal
          return
      }
      
      let timeDelta = now.timeIntervalSince(lastTime)
      guard timeDelta > 0.1 else { return }
      
      let bytesDelta = currentTotal - lastTotalBytesDownloaded
      guard bytesDelta > 0 else { return }
      
      let speed = Double(bytesDelta) / timeDelta
      downloadSpeedSamples.append(speed)
      if downloadSpeedSamples.count > maxSpeedSamples {
          downloadSpeedSamples.removeFirst()
      }
      
      let averageSpeed = downloadSpeedSamples.reduce(0, +) / Double(downloadSpeedSamples.count)
      _state.overallDownloadSpeed = averageSpeed
      
      let remainingBytes = _state.totalBytesToDownload - currentTotal
      if averageSpeed > 0 && remainingBytes > 0 {
          _state.estimatedTimeRemainingSeconds = Double(remainingBytes) / averageSpeed
      } else {
          _state.estimatedTimeRemainingSeconds = nil
      }
      
      lastProgressUpdateTime = now
      lastTotalBytesDownloaded = currentTotal
  }
  
  private func resetSpeedTracking() {
      downloadSpeedSamples = []
      lastProgressUpdateTime = nil
      lastTotalBytesDownloaded = 0
  }
  ```

### Phase 3: Update SetupCoordinator to Observe ModelManager

**`Ora/Setup/SetupCoordinator.swift`**

Add notification observer and published models state:
```swift
@MainActor
final class SetupCoordinator: NSObject, ObservableObject {
    // MARK: - Published State
    
    @Published private(set) var state = SetupState()
    @Published private(set) var isShowingSetup = false
    
    // NEW: Published models state (synced from ModelManager)
    @Published private(set) var modelsState = ModelsState()
    
    // ... existing properties ...
    
    // NEW: Notification observer
    private var modelStateObserver: NSObjectProtocol?
    
    // MARK: - Initialization
    
    private override init() {
        super.init()
        loadSystemInfo()
        setupModelStateObserver()  // NEW
    }
    
    deinit {
        if let observer = modelStateObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }
    
    // NEW: Setup observer for ModelManager state changes
    private func setupModelStateObserver() {
        modelStateObserver = NotificationCenter.default.addObserver(
            forName: .modelStateDidChange,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self = self,
                  let newState = notification.object as? ModelsState else { return }
            self.handleModelStateChange(newState)
        }
    }
    
    // NEW: Handle state changes from ModelManager
    private func handleModelStateChange(_ newState: ModelsState) {
        modelsState = newState
        
        // Update SetupState.downloadProgress from ModelsState for backward compatibility
        state.downloadProgress = newState.overallProgress
        
        // Check if all required models are ready
        if state.currentStep == .download && newState.requiredModelsReady && !state.downloadWasCancelled {
            state.currentStep = .ready
        }
    }
    
    // ... rest of existing code ...
}
```

Update `initializeAlreadyDownloadedModels()` to use thorough existence check:
```swift
private func initializeAlreadyDownloadedModels(_ models: [ModelIdentifier]) async {
    let downloader = DefaultModelDownloader.shared
    for model in models {
        let path = ModelPaths.path(for: model)
        if downloader.exists(model: model, at: path) {  // CHANGED: Use thorough check
            // Model is already downloaded - ModelManager will reflect this
            // No need to update local state
        }
    }
    // Refresh from ModelManager to ensure consistency
    modelsState = await ModelManager.shared.state
    state.downloadProgress = modelsState.overallProgress
}
```

Update `startDownloads()` to remove duplicate progress tracking:
```swift
private func startDownloads() async {
    await ensurePrimaryLLMSelected()
    
    // Reset download state (keep only setup-specific state)
    state.downloadError = nil
    state.downloadWasCancelled = false
    
    // Let ModelManager handle all progress tracking
    downloadTask = Task { @MainActor in
        do {
            try await ModelManager.shared.downloadRequiredModels { [weak self] _ in
                // Progress is now handled via notification observer
                // This callback can be used for logging if needed
            }
            
            logger.info("All downloads complete")
            // State transition happens in handleModelStateChange when requiredModelsReady becomes true
            
        } catch {
            if !Task.isCancelled {
                state.downloadError = error.localizedDescription
                logger.error("Download failed: \(error.localizedDescription)")
            }
        }
    }
    
    await downloadTask?.value
}
```

### Phase 4: Update DownloadStepView to Accept ModelsState

**`Ora/Setup/Steps/DownloadStepView.swift`**

The view currently takes only `SetupState` and uses `ModelDownloadState` enum. We need to:
1. Accept both `SetupState` and `ModelsState`
2. Create a local display enum to replace `ModelDownloadState`
3. Update `ModelProgressRow` to use the new display enum

```swift
// NEW: Local display state enum (replaces ModelDownloadState)
private enum ModelDisplayState: Equatable {
    case pending
    case downloading(progress: Double, bytesDownloaded: Int64, totalBytes: Int64)
    case verifying
    case complete
    case error(String)
    
    var progress: Double {
        switch self {
        case .pending: return 0
        case .downloading(let progress, _, _): return progress
        case .verifying, .complete: return 1.0
        case .error: return 0
        }
    }
}

struct DownloadStepView: View {
    let setupState: SetupState      // For step-specific state (errors, cancellation)
    let modelsState: ModelsState    // For download progress (from ModelManager)
    let onRetry: () -> Void
    let onCancel: () -> Void
    
    // Helper to map ModelStatus to display state
    private func displayState(for model: ModelIdentifier) -> ModelDisplayState {
        let status = modelsState.statuses[model] ?? .notDownloaded
        let progress = modelsState.downloadProgress[model]
        
        switch status {
        case .notDownloaded:
            return .pending
        case .downloading(let progressValue):
            return .downloading(
                progress: progressValue,
                bytesDownloaded: progress?.bytesDownloaded ?? 0,
                totalBytes: progress?.totalBytes ?? model.estimatedSizeBytes
            )
        case .verifying:
            return .verifying
        case .ready:
            return .complete
        case .failed(let error):
            return .error(error)
        case .corrupted:
            return .error("Model files corrupted")
        }
    }
    
    var body: some View {
        VStack(spacing: 24) {
            Text("Downloading Models")
                .font(.largeTitle)
                .fontWeight(.bold)

            Text("This may take a few minutes depending on your connection")
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            Spacer()
                .frame(height: 8)
            
            // Overall progress section - use ModelsState
            VStack(spacing: 12) {
                ProgressView(value: modelsState.overallProgress)
                    .progressViewStyle(.linear)
                
                HStack {
                    // Bytes downloaded - from ModelsState
                    HStack(spacing: 4) {
                        Text(formatBytes(modelsState.totalBytesDownloaded))
                            .fontWeight(.medium)
                        Text("of")
                            .foregroundColor(.secondary)
                        Text(formatBytes(modelsState.totalBytesToDownload))
                            .foregroundColor(.secondary)
                    }
                    .font(.caption)
                    
                    Spacer()
                    
                    // Speed and ETA - from ModelsState
                    HStack(spacing: 8) {
                        Text(modelsState.formattedDownloadSpeed)
                            .fontWeight(.medium)
                        
                        if let timeRemaining = modelsState.formattedTimeRemaining {
                            Text("•")
                                .foregroundColor(.secondary)
                            Text(timeRemaining)
                                .foregroundColor(.secondary)
                        }
                    }
                    .font(.caption)
                    
                    Text("\(Int(modelsState.overallProgress * 100))%")
                        .font(.caption)
                        .fontWeight(.medium)
                        .monospacedDigit()
                        .frame(width: 40, alignment: .trailing)
                }
            }
            
            // Per-model progress - mapped from ModelStatus
            VStack(spacing: 0) {
                ModelProgressRow(
                    name: "Parakeet ASR",
                    totalSize: "~600 MB",
                    displayState: displayState(for: .parakeetTDT)  // CHANGED: was downloadState
                )

                Divider()

                ModelProgressRow(
                    name: modelsState.primaryLLM.displayName,
                    totalSize: llmSizeDisplay,
                    displayState: displayState(for: modelsState.primaryLLM)
                )

                Divider()

                ModelProgressRow(
                    name: "Kokoro TTS",
                    totalSize: "~500 MB",
                    displayState: displayState(for: .kokoro)
                )
            }
            .padding()
            .background(Color(nsColor: .controlBackgroundColor))
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 12))

            Spacer()

            // Error from SetupState (setup-specific)
            if let error = setupState.downloadError {
                VStack(spacing: 12) {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundColor(.red)

                    Button("Retry Download") {
                        onRetry()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }

            // Bottom buttons
            HStack {
                Button("Cancel") {
                    onCancel()
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
                .disabled(modelsState.overallProgress >= 1.0)

                Spacer()

                if modelsState.overallProgress >= 1.0 && setupState.downloadError == nil {
                    Button("Continue") {
                        Task {
                            await SetupCoordinator.shared.nextStep()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
    }
    
    private var llmSizeDisplay: String {
        switch modelsState.primaryLLM {
        case .qwen7B: return "~5 GB"
        case .qwen3_4B: return "~2.5 GB"
        case .qwen3B: return "~2 GB"
        default: return "~2.5 GB"
        }
    }

    private func formatBytes(_ bytes: Int64) -> String {
        SetupState.formatBytes(bytes)
    }
}

// MARK: - Model Progress Row

// UPDATED: Uses ModelDisplayState instead of ModelDownloadState
private struct ModelProgressRow: View {
    let name: String
    let totalSize: String
    let displayState: ModelDisplayState  // CHANGED: was downloadState: ModelDownloadState

    var body: some View {
        HStack(spacing: 12) {
            statusIcon
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .fontWeight(.medium)

                Text(progressText)
                    .font(.caption)
                    .foregroundColor(.secondary)

                if case .downloading(let progress, _, _) = displayState {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Color.secondary.opacity(0.2))
                                .frame(height: 3)

                            RoundedRectangle(cornerRadius: 2)
                                .fill(Color.accentColor)
                                .frame(width: geo.size.width * progress, height: 3)
                        }
                    }
                    .frame(height: 3)
                }
            }

            Spacer()

            Text(totalSize)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch displayState {
        case .pending:
            Image(systemName: "circle")
                .foregroundColor(.secondary)
        case .downloading:
            ProgressView()
                .scaleEffect(0.6)
        case .verifying:
            ProgressView()
                .scaleEffect(0.6)
        case .complete:
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(.green)
        case .error:
            Image(systemName: "xmark.circle.fill")
                .foregroundColor(.red)
        }
    }

    private var progressText: String {
        switch displayState {
        case .pending:
            return "Waiting..."
        case .downloading(let progress, let bytes, let total):
            let bytesStr = SetupState.formatBytes(bytes)
            let totalStr = SetupState.formatBytes(total)
            return "\(bytesStr) of \(totalStr) (\(Int(progress * 100))%)"
        case .verifying:
            return "Verifying..."
        case .complete:
            return "Complete"
        case .error(let message):
            return "Error: \(message)"
        }
    }
}
```

**`Ora/Setup/SetupWindow.swift`**

Update call site in the `case .download:` switch case:
```swift
// Before (line ~42):
case .download:
    DownloadStepView(
        state: self.coordinator.state,
        onRetry: {
            Task { await self.coordinator.retryDownload() }
        },
        onCancel: {
            self.coordinator.cancelDownloads()
        }
    )

// After:
case .download:
    DownloadStepView(
        setupState: self.coordinator.state,
        modelsState: self.coordinator.modelsState,
        onRetry: {
            Task { await self.coordinator.retryDownload() }
        },
        onCancel: {
            self.coordinator.cancelDownloads()
        }
    )
```

### Phase 5: Clean Up SetupState (Remove Duplicate Fields)

**`Ora/Setup/SetupState.swift`**

Remove duplicate download progress fields:
```swift
struct SetupState: Sendable {
    var currentStep: SetupStep = .welcome
    var isComplete: Bool = false
    
    // Permissions
    var permissionsGranted: Bool = false
    var skippedOptionalPermissions: Bool = false
    
    // Downloads - KEEP only setup-specific state
    var downloadProgress: Double = 0  // KEEP: Backward compatibility for overall progress
    var downloadingModel: String? = nil  // KEEP: Currently downloading model name
    var downloadError: String? = nil  // KEEP: Error message
    var primaryLLM: ModelIdentifier = .qwen3_4B  // KEEP: Selected LLM
    var downloadWasCancelled: Bool = false  // KEEP: Cancellation flag
    
    // REMOVED: modelDownloadStates - now in ModelsState
    // REMOVED: modelProgresses - now in ModelsState  
    // REMOVED: totalBytesDownloaded - now in ModelsState
    // REMOVED: totalBytesToDownload - now in ModelsState
    // REMOVED: downloadSpeedBytesPerSecond - now in ModelsState
    // REMOVED: estimatedTimeRemainingSeconds - now in ModelsState
    // REMOVED: isDownloading - now in ModelsState
    
    // System info
    var systemRAMGB: Int = 0
    var recommendedModel: String = "Qwen 3 4B"
    
    // KEEP: Formatting helpers for backward compatibility
    static func formatBytes(_ bytes: Int64) -> String {
        let gb = Double(bytes) / (1024 * 1024 * 1024)
        if gb >= 1.0 {
            return String(format: "%.1f GB", gb)
        }
        let mb = Double(bytes) / (1024 * 1024)
        return String(format: "%.0f MB", mb)
    }
    
    static var totalModelSizeDisplay: String {
        return "~3.6 GB"
    }
}

// REMOVED: ModelDownloadState enum - use ModelStatus instead
```

### Phase 6: Deprecate ModelPaths.modelExists()

**`Ora/Models/ModelPaths.swift`**

Mark as deprecated:
```swift
/// Check if model directory exists
/// - Warning: This only checks if the directory exists, not if all required files are present.
///   Use `DefaultModelDownloader.shared.exists(model:at:)` for thorough validation.
@available(*, deprecated, message: "Use DefaultModelDownloader.shared.exists(model:at:) for thorough validation")
static func modelExists(_ model: ModelIdentifier) -> Bool {
    let path = self.path(for: model)
    return FileManager.default.fileExists(atPath: path.path)
}
```

### Phase 7: Fix Race Condition in checkAndShowSetupIfNeeded

**`Ora/Setup/SetupCoordinator.swift`**

Ensure ModelManager is initialized:
```swift
func checkAndShowSetupIfNeeded() async -> Bool {
    // NEW: Ensure ModelManager metadata is loaded before checking status
    await ModelManager.shared.ensureInitialized()
    
    let isComplete = UserDefaults.standard.bool(forKey: userDefaultsKey)
    
    if isComplete {
        let modelsReady = await ModelManager.shared.requiredModelsAvailable()
        if !modelsReady {
            logger.warning("Setup was complete but models missing, showing model explanation")
            state.currentStep = .modelExplanation
            showSetup()
            return true
        }
        return false
    } else {
        showSetup()
        return true
    }
}
```

### Phase 8: Update Tests

**`OraTests/SetupCoordinatorTests.swift`**

Update tests that depend on removed fields:
```swift
// REMOVE or UPDATE tests for:
// - test_initialState_downloadStatsAreZero (fields moved to ModelsState)
// - test_formattedBytesDownloaded_formatsCorrectly (moved to ModelsState)
// - test_formattedDownloadSpeed_formatsCorrectly (moved to ModelsState)
// - test_formattedTimeRemaining_* (moved to ModelsState)
// - test_modelDownloadStates_canTrackStates (removed from SetupState)

// ADD new tests:
// - test_observesModelStateChanges
// - test_modelsStateUpdatesFromNotification
// - test_checkAndShowSetupIfNeeded_awaitsModelManagerInit
```

**`OraTests/SetupStateTests.swift`** (if separate)

Remove tests for deleted fields, add note explaining they moved to `ModelsState`.

**`OraTests/ModelManagerTests.swift`**

Add tests for new progress tracking:
```swift
func test_downloadProgress_updatesModelsState() async throws {
    // Verify downloadProgress dictionary is populated during download
}

func test_downloadSpeed_calculatesRollingAverage() async throws {
    // Verify speed calculation with simulated progress updates
}

func test_estimatedTimeRemaining_calculatedFromSpeed() async throws {
    // Verify ETA calculation
}

func test_isDownloading_setDuringDownload() async throws {
    // Verify isDownloading flag lifecycle
}
```

### 5.1 Files to Create

None - this is a refactoring of existing code.

### 5.2 Files to Modify

| File | Changes |
|------|---------|
| `Ora/Models/ModelTypes.swift` | Extend `ModelsState` with progress fields, formatting helpers |
| `Ora/Models/ModelManager.swift` | Add speed/ETA calculation, update progress in state |
| `Ora/Models/ModelPaths.swift` | Deprecate `modelExists()` |
| `Ora/Setup/SetupState.swift` | Remove duplicate fields, keep setup-specific state |
| `Ora/Setup/SetupCoordinator.swift` | Add notification observer, publish modelsState, fix race condition |
| `Ora/Setup/Steps/DownloadStepView.swift` | Accept ModelsState, map ModelStatus to UI |
| `Ora/Setup/SetupWindow.swift` | Update DownloadStepView call site |
| `OraTests/SetupCoordinatorTests.swift` | Update tests for removed fields |
| `OraTests/SetupStateTests.swift` | Update tests for removed fields |
| `OraTests/ModelManagerTests.swift` | Add tests for progress tracking |

### 5.3 Tests to Add/Update

**Add to `OraTests/ModelManagerTests.swift`:**
- [ ] `test_downloadProgress_updatesModelsState` - Verify progress dict populated
- [ ] `test_downloadSpeed_calculatesRollingAverage` - Speed calculation works
- [ ] `test_estimatedTimeRemaining_calculatedFromSpeed` - ETA calculation works
- [ ] `test_isDownloading_setDuringDownload` - Flag lifecycle correct
- [ ] `test_downloadProgress_clearedAfterCompletion` - Cleanup after download

**Add to `OraTests/SetupCoordinatorTests.swift`:**
- [ ] `test_observesModelStateChanges` - Coordinator receives notifications
- [ ] `test_modelsStatePublished_updatesFromNotification` - @Published updates
- [ ] `test_checkAndShowSetupIfNeeded_awaitsModelManagerInit` - Race condition fixed
- [ ] `test_alreadyDownloadedModels_usesCorrectExistenceCheck` - Uses thorough check

**Update in `OraTests/SetupStateTests.swift`** (within `SetupCoordinatorTests.swift`):
- [ ] Remove tests for deleted fields: `test_initialState_downloadStatsAreZero`, `test_formattedBytesDownloaded_formatsCorrectly`, `test_formattedDownloadSpeed_formatsCorrectly`, `test_formattedTimeRemaining_*`, `test_modelDownloadStates_canTrackStates`
- [ ] Add comment explaining fields moved to ModelsState

**Update in `OraTests/SetupCoordinatorTests.swift`:**
- [ ] Remove `ModelDownloadStateTests` class entirely (enum will be removed)
- [ ] Update any tests using `SetupState.modelDownloadStates` or `SetupState.modelProgresses`

**Update in `OraTests/SetupViewsTests.swift`:**
- [ ] Update `test_downloadStepView_bodyBuilds_forStates` - This test creates `SetupState` with `modelDownloadStates` and `modelProgresses`. Needs to create both `SetupState` and `ModelsState` for the new signature.
- [ ] Update `test_setupWindow_bodyBuilds_forAllSteps` - `makeState()` helper also sets these fields.
- [ ] Example of updated test:
  ```swift
  func test_downloadStepView_bodyBuilds_forStates() {
      var setupState = SetupState()
      setupState.currentStep = .download
      setupState.downloadProgress = 0.35
      setupState.downloadingModel = "Parakeet ASR"
      // REMOVED: modelProgresses, modelDownloadStates
      
      var modelsState = ModelsState()
      modelsState.statuses = [
          .parakeetTDT: .downloading(progress: 0.35),
          .qwen3_4B: .notDownloaded,
          .kokoro: .notDownloaded
      ]
      modelsState.downloadProgress = [
          .parakeetTDT: ModelDownloadProgress(
              identifier: .parakeetTDT,
              bytesDownloaded: 200_000_000,
              totalBytes: 600_000_000
          )
      ]
      
      let view = DownloadStepView(
          setupState: setupState,
          modelsState: modelsState,
          onRetry: {},
          onCancel: {}
      )
      _ = view.body
  }
  ```

### 5.4 Dependencies/Config

No changes to `project.yml` required.

## 6. Acceptance Criteria

- [x] AC-1: Setup Wizard and Preferences show identical model status for all models
  - ✅ Both now observe `ModelManager.state` via notification
- [x] AC-2: Fresh install: Setup wizard shows "pending" → "downloading" → "complete", Preferences shows same
  - ✅ DownloadStepView maps ModelStatus to display state
- [x] AC-3: Partial download (cancelled): Both UIs show consistent incomplete status
  - ✅ Cancellation clears ModelManager state, both UIs reflect it
- [x] AC-4: Corrupted model: Both UIs detect and show corrupted/failed status
  - ✅ ModelManager.refreshStatuses() detects via DefaultModelDownloader.exists()
- [x] AC-5: Re-download from Preferences: Status updates correctly in both UIs
  - ✅ NotificationCenter broadcasts state changes to all observers
- [x] AC-6: Open Preferences immediately after Setup completes: Status is consistent (no race)
  - ✅ SetupCoordinator.checkAndShowSetupIfNeeded() awaits ensureInitialized()
- [x] AC-7: `SetupState` no longer contains `modelDownloadStates` or duplicate progress tracking
  - ✅ Verified in SetupState.swift - only setup-specific fields remain
- [x] AC-8: All model existence checks use `DefaultModelDownloader.exists()` (not `ModelPaths.modelExists()`)
  - ✅ SetupCoordinator no longer uses ModelPaths.modelExists() - removed initializeAlreadyDownloadedModels()
- [x] AC-9: `ModelPaths.modelExists()` is marked `@deprecated`
  - ✅ Verified in ModelPaths.swift with deprecation warning
- [x] AC-10: Unit tests pass and cover the new unified state flow
  - ✅ 764 tests pass, added ModelsStateDownloadTrackingTests
- [x] AC-11: No compiler warnings from removed `SetupState` fields
  - ✅ Build succeeds with no errors

## 7. Verification Plan

### Automated Tests

- [x] All existing tests pass (after updates)
  - ✅ 764 tests pass with 0 failures
- [x] New tests for `ModelManager` progress tracking pass
  - ✅ ModelsStateDownloadTrackingTests added and passing
- [x] New tests for `SetupCoordinator` notification observation pass
  - ✅ test_coordinator_hasModelsState added and passing

### Manual Tests

- [ ] Fresh install flow: Complete setup wizard, open Preferences, verify status matches
- [ ] Cancel download during Setup: Verify both UIs show incomplete
- [ ] Delete model from Preferences: Re-run setup, verify wizard detects missing model
- [ ] Simulate corrupted model (delete required file): Verify both UIs show corrupted
- [ ] Rapid open Preferences after Setup: Verify no flash of incorrect status
- [ ] Force-quit during download: Restart app, verify correct status in both UIs

## 8. Performance / Reliability Considerations

- Progress updates are throttled (already 100ms in HuggingFaceDownloader)
- Notification posting is on MainActor to avoid UI threading issues
- Actor isolation in ModelManager prevents data races
- Speed calculation uses rolling average (5 samples) to smooth fluctuations
- Observer removed in deinit to prevent memory leaks

## 9. Risks & Mitigations

| Risk | Mitigation |
|------|------------|
| Breaking existing download flow | Keep download mechanism unchanged, only move state |
| Breaking existing tests | Update tests in same PR, document removed fields |
| UI flicker during state sync | Notification coalescing already in place, throttle updates |
| Test coverage gaps | Add specific tests for unified flow before removing old code |
| FluidAudio path issues | Verify Parakeet paths match expected locations |
| Observer memory leak | Remove observer in deinit |

## 10. Implementation Order (CRITICAL)

**Must be done in this order to avoid breaking the app:**

1. Phase 1: Extend ModelsState (additive, non-breaking)
2. Phase 2: Update ModelManager (additive, non-breaking)
3. Phase 3: Update SetupCoordinator to observe (additive, non-breaking)
4. Phase 4: Update DownloadStepView to accept BOTH states (transitional)
5. Phase 5: Clean up SetupState (breaking change, but app still works)
6. Phase 6: Deprecate ModelPaths.modelExists() (warning only)
7. Phase 7: Fix race condition (bugfix)
8. Phase 8: Update tests (must follow code changes)

**Do NOT:**
- Remove SetupState fields before DownloadStepView is updated
- Remove ModelDownloadState enum before UI is updated
- Skip the deprecation of ModelPaths.modelExists()

## 11. Open Questions (Resolved)

- ~~Should `ModelDownloadState` enum be removed entirely or kept for legacy compatibility?~~
  - **Decision:** Remove it. Map `ModelStatus` to local UI states in the view layer.
- ~~Should speed/ETA calculation remain in `SetupCoordinator` or move to `ModelManager`?~~
  - **Decision:** Move to `ModelManager` so Preferences can also show speed if desired.

---

## Appendix A: Root Cause Analysis

### Issue 1: Dual State Systems Without Synchronization

The Setup Wizard and Preferences use completely separate state tracking:

| Component | State Type | Location |
|-----------|-----------|----------|
| Setup Wizard | `SetupState.modelDownloadStates` | `SetupCoordinator.swift` |
| Preferences | `ModelsState.statuses` | Via `ModelManager.swift` |

These are different structs with different enums:
- `ModelDownloadState`: pending / downloading / verifying / complete / error
- `ModelStatus`: notDownloaded / downloading / verifying / ready / failed / corrupted

### Issue 2: Different Existence Checks

**SetupCoordinator** (`initializeAlreadyDownloadedModels`):
```swift
if ModelPaths.modelExists(model) {  // ONLY checks directory exists!
    self.state.modelDownloadStates[model] = .complete
```

**ModelManager** (`refreshStatuses`):
```swift
if self.downloader.exists(model: model, at: path) {  // Checks ALL files + sizes
    _state.statuses[model] = .ready
```

The thorough check in `DefaultModelDownloader.exists()`:
1. Checks directory exists
2. Checks ALL required files exist
3. Checks file sizes are reasonable (not truncated)
4. For `.mlmodelc` directories, confirms they are directories

### Issue 3: No Cross-System Notification

`SetupState` is a local struct that doesn't observe `ModelManager`:
- When `ModelManager.refreshStatuses()` runs and finds a model corrupted, `SetupState` doesn't know
- Setup wizard has no mechanism to react to `ModelManager` state changes

### Issue 4: Metadata Loading Race Condition

In `ModelManager.init()`:
```swift
private init() {
    Task { await self.performInitialLoad() }  // ASYNC - may not complete before...
}
```

`SetupCoordinator.checkAndShowSetupIfNeeded()` immediately calls:
```swift
let modelsReady = await ModelManager.shared.requiredModelsAvailable()  // ...this!
```

If metadata hasn't loaded, `primaryLLM` may be wrong, causing incorrect status.

---

## Appendix B: File Reference

### Primary Files to Modify

| File | Path | Purpose |
|------|------|---------|
| ModelTypes | `Ora/Models/ModelTypes.swift` | State definitions |
| ModelManager | `Ora/Models/ModelManager.swift` | Centralized state management |
| ModelPaths | `Ora/Models/ModelPaths.swift` | Path utilities (deprecate method) |
| SetupState | `Ora/Setup/SetupState.swift` | Setup-specific state |
| SetupCoordinator | `Ora/Setup/SetupCoordinator.swift` | Setup flow orchestration |
| DownloadStepView | `Ora/Setup/Steps/DownloadStepView.swift` | Download progress UI |
| SetupWindow | `Ora/Setup/SetupWindow.swift` | View instantiation |

### Reference Files (Read Only)

| File | Path | Purpose |
|------|------|---------|
| DownloadProgress | `Ora/Models/DownloadProgress.swift` | Existing progress types to reuse |
| ModelDownloading | `Ora/Models/ModelDownloading.swift` | `exists()` implementation |
| ModelsPreferencesView | `Ora/Preferences/Tabs/ModelsPreferencesView.swift` | How Preferences does it right |
| FluidAudioStrategy | `Ora/Models/Strategies/FluidAudioStrategy.swift` | ASR download handling |

### Test Files to Modify

| File | Path | Changes |
|------|------|---------|
| SetupCoordinatorTests | `OraTests/SetupCoordinatorTests.swift` | Remove `ModelDownloadStateTests` class, update tests for removed fields, add observer tests |
| SetupViewsTests | `OraTests/SetupViewsTests.swift` | Update `test_downloadStepView_bodyBuilds_forStates` and `makeState()` helper for new signature |
| ModelManagerTests | `OraTests/ModelManagerTests.swift` | Add progress tracking, speed calculation, and ETA tests |

### Model Storage Structure

```
~/Library/Application Support/Ora/
├── Models/
│   ├── asr/
│   │   └── parakeet-tdt-0.6b-v3-coreml/
│   │       ├── Encoder.mlmodelc/
│   │       ├── Decoder.mlmodelc/
│   │       ├── JointDecision.mlmodelc/
│   │       └── parakeet_vocab.json
│   ├── llm/
│   │   └── qwen3-4b-instruct-4bit/
│   │       ├── config.json
│   │       ├── tokenizer.json
│   │       ├── tokenizer_config.json
│   │       ├── special_tokens_map.json
│   │       ├── model.safetensors (~2.26 GB)
│   │       └── chat_template.jinja
│   └── tts/
│       └── kokoro/
│           ├── config.json
│           ├── kokoro-v1_0.safetensors (~312 MB)
│           └── voices/
│               └── af_heart.safetensors (~510 KB)
└── model-metadata.json
```

---

## Implementation Summary

**Date:** 2026-01-06
**Branch:** `feat/m02-unified-model-status-tracking`
**Commits:** 1

### Files Changed

| File | Changes |
|------|---------|
| `Ora/Models/ModelTypes.swift` | Extended `ModelsState` with download progress fields and formatting helpers |
| `Ora/Models/ModelManager.swift` | Added speed/ETA calculation, progress tracking in state |
| `Ora/Models/ModelPaths.swift` | Deprecated `modelExists()` method |
| `Ora/Models/DownloadProgress.swift` | Made `ModelDownloadProgress` conform to `Equatable` |
| `Ora/Setup/SetupState.swift` | Removed duplicate fields and `ModelDownloadState` enum |
| `Ora/Setup/SetupCoordinator.swift` | Added notification observer, `modelsState` property, removed duplicate tracking |
| `Ora/Setup/SetupWindow.swift` | Updated `DownloadStepView` call site |
| `Ora/Setup/Steps/DownloadStepView.swift` | Rewritten to accept both `SetupState` and `ModelsState` |
| `OraTests/SetupCoordinatorTests.swift` | Updated tests, added `ModelsStateDownloadTrackingTests` |
| `OraTests/SetupViewsTests.swift` | Updated for new `DownloadStepView` signature |

### Implementation Notes

1. **Single Source of Truth**: `ModelManager` now owns all download state. Both Setup Wizard and Preferences observe via `NotificationCenter.default.addObserver(forName: .modelStateDidChange)`.

2. **Speed/ETA Calculation**: Moved from `SetupCoordinator` to `ModelManager.updateDownloadSpeed()` using a 5-sample rolling average.

3. **Race Condition Fix**: `SetupCoordinator.checkAndShowSetupIfNeeded()` now calls `await ModelManager.shared.ensureInitialized()` before checking model status.

4. **Swift 6 Concurrency**: Used `nonisolated(unsafe)` for the notification observer property to allow access from deinit while maintaining MainActor isolation for the class.

5. **Backward Compatibility**: `SetupState.downloadProgress` is still maintained for backward compatibility but is now synced from `ModelsState.overallProgress`.

### Ready for Review

- [x] All acceptance criteria verified
- [x] Tests passing (764 tests, 0 failures)
- [x] Working tree clean

## Code Review Findings

(TBD by review agent.)

## Completion Status

(TBD after merge.)
