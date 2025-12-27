# F.04 - First-Run Setup

**Epic:** Foundations
**Status:** Not Started
**Priority:** P0 (Critical Path)
**Estimated Effort:** 2-3 days
**Dependencies:** F.01 (App Shell), F.02 (Permissions), F.03 (Model Manager)
**Target:** macOS 26 (Tahoe)
**Design Reference:** [Liquid Glass UI Guide](../../references/liquid-glass-ui.md)

---

## 1. Objective

Create the first-run onboarding experience that guides users through permissions and model downloads before the app is usable.

### Flow Overview

```
┌─────────────┐    ┌─────────────┐    ┌─────────────┐    ┌─────────────┐
│   Welcome   │───▶│ Permissions │───▶│  Download   │───▶│    Ready    │
│   (Step 1)  │    │  (Step 2)   │    │  (Step 3)   │    │  (Step 4)   │
└─────────────┘    └─────────────┘    └─────────────┘    └─────────────┘
```

### Scope

**In Scope:**
- `SetupCoordinator` to manage onboarding state
- `SetupWindow` (SwiftUI) with step-based navigation
- Welcome step: System info, RAM recommendation
- Permissions step: Request required + optional permissions
- Download step: Parallel model downloads with progress
- Ready step: Hotkey tutorial and completion

**Out of Scope:**
- Preferences window (F.06)
- Overlay window (F.07)
- Actual model inference

---

## 2. Architecture

### Component Diagram

```
┌─────────────────────────────────────────────────────────────┐
│                     SetupCoordinator                         │
│                      (@MainActor)                            │
├─────────────────────────────────────────────────────────────┤
│  - Tracks current step                                      │
│  - Validates step completion                                │
│  - Coordinates with PermissionsManager + ModelManager       │
│  - Persists setup completion state                          │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────┐
│                      SetupWindow                             │
│                       (SwiftUI)                              │
├─────────────────────────────────────────────────────────────┤
│  ┌──────────────────────────────────────────────────────┐   │
│  │                    Content Area                       │   │
│  │  - WelcomeStepView                                   │   │
│  │  - PermissionsStepView                               │   │
│  │  - DownloadStepView                                  │   │
│  │  - ReadyStepView                                     │   │
│  └──────────────────────────────────────────────────────┘   │
│  ┌──────────────────────────────────────────────────────┐   │
│  │              Navigation (Back / Next)                 │   │
│  └──────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
```

---

## 3. Implementation

### 3.1 Setup State

**File:** `Ora/Setup/SetupState.swift`

```swift
//
//  SetupState.swift
//  Ora
//
//  First-run setup state management
//

import Foundation

/// Steps in the setup flow
enum SetupStep: Int, CaseIterable, Sendable {
    case welcome = 0
    case permissions = 1
    case download = 2
    case ready = 3
    
    var title: String {
        switch self {
        case .welcome: return "Welcome"
        case .permissions: return "Permissions"
        case .download: return "Download Models"
        case .ready: return "Ready"
        }
    }
    
    var canGoBack: Bool {
        switch self {
        case .welcome: return false
        case .permissions: return true
        case .download: return false // Can't go back during download
        case .ready: return false
        }
    }
}

/// Aggregated setup state
struct SetupState: Sendable {
    var currentStep: SetupStep = .welcome
    var isComplete: Bool = false
    
    // Permissions
    var permissionsGranted: Bool = false
    var skippedOptionalPermissions: Bool = false
    
    // Downloads
    var downloadProgress: Double = 0
    var downloadingModel: String? = nil
    var downloadError: String? = nil
    
    // System info
    var systemRAMGB: Int = 0
    var recommendedModel: String = "Qwen 2.5 7B"
}
```

### 3.2 Setup Coordinator

**File:** `Ora/Setup/SetupCoordinator.swift`

```swift
//
//  SetupCoordinator.swift
//  Ora
//
//  Coordinates the first-run setup flow
//

import Foundation
import SwiftUI
import os

/// Manages the first-run setup experience
@MainActor
final class SetupCoordinator: ObservableObject {
    
    // MARK: - Published State
    
    @Published private(set) var state = SetupState()
    @Published private(set) var isShowingSetup = false
    
    // MARK: - Properties
    
    private let logger = Logger(subsystem: "com.ora.app", category: "SetupCoordinator")
    private let userDefaultsKey = "com.ora.setupComplete"
    
    // MARK: - Singleton
    
    static let shared = SetupCoordinator()
    
    // MARK: - Initialization
    
    private init() {
        loadSystemInfo()
    }
    
    // MARK: - Public API
    
    /// Check if setup is needed and show if required
    func checkAndShowSetupIfNeeded() {
        let isComplete = UserDefaults.standard.bool(forKey: userDefaultsKey)
        
        if isComplete {
            // Verify models are still available
            Task {
                let modelsReady = await ModelManager.shared.requiredModelsAvailable()
                if !modelsReady {
                    logger.warning("Setup was complete but models missing, restarting setup")
                    await MainActor.run {
                        self.state.currentStep = .download
                        self.showSetup()
                    }
                }
            }
        } else {
            showSetup()
        }
    }
    
    /// Show the setup window
    func showSetup() {
        isShowingSetup = true
        logger.info("Showing setup window at step: \(self.state.currentStep.title)")
    }
    
    /// Dismiss setup (only when complete)
    func dismissSetup() {
        guard state.isComplete else {
            logger.warning("Cannot dismiss setup before completion")
            return
        }
        isShowingSetup = false
    }
    
    /// Move to next step
    func nextStep() async {
        switch state.currentStep {
        case .welcome:
            state.currentStep = .permissions
            
        case .permissions:
            // Validate required permissions
            let permState = await PermissionsManager.shared.state
            if permState.requiredPermissionsGranted {
                state.permissionsGranted = true
                state.currentStep = .download
                // Start downloads automatically
                await startDownloads()
            } else {
                logger.warning("Required permissions not granted")
            }
            
        case .download:
            // Only proceed if downloads complete
            let modelsReady = await ModelManager.shared.requiredModelsAvailable()
            if modelsReady {
                state.currentStep = .ready
            }
            
        case .ready:
            completeSetup()
        }
    }
    
    /// Go back to previous step
    func previousStep() {
        guard state.currentStep.canGoBack else { return }
        
        if let previousIndex = SetupStep(rawValue: state.currentStep.rawValue - 1) {
            state.currentStep = previousIndex
        }
    }
    
    /// Request a specific permission
    func requestPermission(_ type: PermissionType) async {
        _ = await PermissionsManager.shared.request(type)
        await refreshPermissionsState()
    }
    
    /// Request all required permissions
    func requestRequiredPermissions() async {
        _ = await PermissionsManager.shared.requestRequired()
        await refreshPermissionsState()
    }
    
    /// Retry failed download
    func retryDownload() async {
        state.downloadError = nil
        await startDownloads()
    }
    
    /// Postpone setup (show minimal UI)
    func postponeSetup() {
        isShowingSetup = false
        // App remains in limited state until setup completes
        logger.info("Setup postponed by user")
    }
    
    // MARK: - Private
    
    private func loadSystemInfo() {
        let ramBytes = ProcessInfo.processInfo.physicalMemory
        state.systemRAMGB = Int(ramBytes / (1024 * 1024 * 1024))
        state.recommendedModel = state.systemRAMGB >= 16 ? "Qwen 2.5 7B" : "Qwen 2.5 3B"
    }
    
    private func refreshPermissionsState() async {
        await PermissionsManager.shared.refreshAll()
        let permState = await PermissionsManager.shared.state
        state.permissionsGranted = permState.requiredPermissionsGranted
    }
    
    private func startDownloads() async {
        state.downloadProgress = 0
        state.downloadError = nil
        
        do {
            try await ModelManager.shared.downloadRequiredModels { [weak self] progress in
                Task { @MainActor in
                    self?.state.downloadProgress = progress.overallProgress
                    // Find currently downloading model
                    for (model, modelProgress) in progress.models {
                        if modelProgress.progress < 1.0 {
                            self?.state.downloadingModel = model.displayName
                            break
                        }
                    }
                }
            }
            
            state.downloadProgress = 1.0
            state.downloadingModel = nil
            logger.info("All downloads complete")
            
            // Auto-advance to ready
            state.currentStep = .ready
            
        } catch {
            state.downloadError = error.localizedDescription
            logger.error("Download failed: \(error.localizedDescription)")
        }
    }
    
    private func completeSetup() {
        state.isComplete = true
        UserDefaults.standard.set(true, forKey: userDefaultsKey)
        isShowingSetup = false
        logger.info("Setup completed successfully")
        
        // Notify app that setup is done
        NotificationCenter.default.post(name: .setupDidComplete, object: nil)
    }
}

// MARK: - Notifications

extension Notification.Name {
    static let setupDidComplete = Notification.Name("setupDidComplete")
}
```

### 3.3 Setup Window

**File:** `Ora/Setup/SetupWindow.swift`

```swift
//
//  SetupWindow.swift
//  Ora
//
//  Main setup window container
//

import SwiftUI

struct SetupWindow: View {
    @ObservedObject var coordinator: SetupCoordinator
    
    var body: some View {
        VStack(spacing: 0) {
            // Progress indicator
            SetupProgressView(currentStep: coordinator.state.currentStep)
                .padding(.top, 20)
                .padding(.horizontal, 40)
            
            Divider()
                .padding(.top, 20)
            
            // Content area
            Group {
                switch coordinator.state.currentStep {
                case .welcome:
                    WelcomeStepView(state: coordinator.state)
                case .permissions:
                    PermissionsStepView(coordinator: coordinator)
                case .download:
                    DownloadStepView(state: coordinator.state, onRetry: {
                        Task { await coordinator.retryDownload() }
                    })
                case .ready:
                    ReadyStepView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(40)
            
            Divider()
            
            // Navigation buttons
            SetupNavigationView(coordinator: coordinator)
                .padding(20)
        }
        .frame(width: 600, height: 500)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

// MARK: - Progress Indicator

struct SetupProgressView: View {
    let currentStep: SetupStep
    
    var body: some View {
        HStack(spacing: 8) {
            ForEach(SetupStep.allCases, id: \.rawValue) { step in
                HStack(spacing: 8) {
                    Circle()
                        .fill(step.rawValue <= currentStep.rawValue ? Color.accentColor : Color.secondary.opacity(0.3))
                        .frame(width: 10, height: 10)
                    
                    Text(step.title)
                        .font(.caption)
                        .foregroundColor(step.rawValue <= currentStep.rawValue ? .primary : .secondary)
                    
                    if step != SetupStep.allCases.last {
                        Rectangle()
                            .fill(step.rawValue < currentStep.rawValue ? Color.accentColor : Color.secondary.opacity(0.3))
                            .frame(height: 2)
                            .frame(maxWidth: 40)
                    }
                }
            }
        }
    }
}

// MARK: - Navigation

struct SetupNavigationView: View {
    @ObservedObject var coordinator: SetupCoordinator
    
    var body: some View {
        HStack {
            // Back button
            if coordinator.state.currentStep.canGoBack {
                Button("Back") {
                    coordinator.previousStep()
                }
                .keyboardShortcut(.escape, modifiers: [])
            }
            
            Spacer()
            
            // Postpone (only on welcome/permissions)
            if coordinator.state.currentStep == .welcome || coordinator.state.currentStep == .permissions {
                Button("Later") {
                    coordinator.postponeSetup()
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
            }
            
            // Next/Done button
            Button(nextButtonTitle) {
                Task {
                    await coordinator.nextStep()
                }
            }
            .keyboardShortcut(.return, modifiers: [])
            .buttonStyle(.borderedProminent)
            .disabled(!canProceed)
        }
    }
    
    private var nextButtonTitle: String {
        switch coordinator.state.currentStep {
        case .welcome: return "Get Started"
        case .permissions: return "Continue"
        case .download: return "Continue"
        case .ready: return "Done"
        }
    }
    
    private var canProceed: Bool {
        switch coordinator.state.currentStep {
        case .welcome:
            return true
        case .permissions:
            return coordinator.state.permissionsGranted
        case .download:
            return coordinator.state.downloadProgress >= 1.0 && coordinator.state.downloadError == nil
        case .ready:
            return true
        }
    }
}
```

### 3.4 Welcome Step

**File:** `Ora/Setup/Steps/WelcomeStepView.swift`

```swift
//
//  WelcomeStepView.swift
//  Ora
//
//  Welcome step of setup
//

import SwiftUI

struct WelcomeStepView: View {
    let state: SetupState
    
    var body: some View {
        VStack(spacing: 24) {
            // App icon
            Image(systemName: "waveform.circle.fill")
                .font(.system(size: 80))
                .foregroundStyle(.tint)
            
            // Welcome text
            Text("Welcome to Ora")
                .font(.largeTitle)
                .fontWeight(.bold)
            
            Text("Your private voice assistant that runs entirely on your Mac.")
                .font(.title3)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            
            Spacer()
                .frame(height: 20)
            
            // System info
            VStack(alignment: .leading, spacing: 12) {
                SystemInfoRow(
                    icon: "memorychip",
                    title: "System Memory",
                    value: "\(state.systemRAMGB) GB RAM"
                )
                
                SystemInfoRow(
                    icon: "cpu",
                    title: "Recommended Model",
                    value: state.recommendedModel
                )
                
                SystemInfoRow(
                    icon: "keyboard",
                    title: "Activation Hotkey",
                    value: "⌥ Space (Option + Space)"
                )
            }
            .padding()
            .background(Color(nsColor: .controlBackgroundColor))
            .cornerRadius(8)
            
            Spacer()
            
            // Privacy note
            Label("All processing happens on your device. No data is sent to the cloud.", systemImage: "lock.shield")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
}

struct SystemInfoRow: View {
    let icon: String
    let title: String
    let value: String
    
    var body: some View {
        HStack {
            Image(systemName: icon)
                .frame(width: 24)
                .foregroundColor(.accentColor)
            
            Text(title)
                .foregroundColor(.secondary)
            
            Spacer()
            
            Text(value)
                .fontWeight(.medium)
        }
    }
}
```

### 3.5 Permissions Step

**File:** `Ora/Setup/Steps/PermissionsStepView.swift`

```swift
//
//  PermissionsStepView.swift
//  Ora
//
//  Permissions request step
//

import SwiftUI

struct PermissionsStepView: View {
    @ObservedObject var coordinator: SetupCoordinator
    @State private var permissionsState = PermissionsState()
    
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("Permissions")
                .font(.largeTitle)
                .fontWeight(.bold)
            
            Text("Ora needs a few permissions to work properly.")
                .foregroundColor(.secondary)
            
            VStack(spacing: 16) {
                // Required permissions
                Text("Required")
                    .font(.headline)
                    .frame(maxWidth: .infinity, alignment: .leading)
                
                PermissionRow(
                    type: .microphone,
                    status: permissionsState.microphone,
                    onRequest: { await coordinator.requestPermission(.microphone) }
                )
                
                PermissionRow(
                    type: .accessibility,
                    status: permissionsState.accessibility,
                    onRequest: { await coordinator.requestPermission(.accessibility) }
                )
                
                Divider()
                
                // Optional permissions
                Text("Optional")
                    .font(.headline)
                    .frame(maxWidth: .infinity, alignment: .leading)
                
                PermissionRow(
                    type: .calendar,
                    status: permissionsState.calendar,
                    onRequest: { await coordinator.requestPermission(.calendar) }
                )
                
                PermissionRow(
                    type: .reminders,
                    status: permissionsState.reminders,
                    onRequest: { await coordinator.requestPermission(.reminders) }
                )
                
                PermissionRow(
                    type: .contacts,
                    status: permissionsState.contacts,
                    onRequest: { await coordinator.requestPermission(.contacts) }
                )
            }
            .padding()
            .background(Color(nsColor: .controlBackgroundColor))
            .cornerRadius(8)
            
            Spacer()
            
            if !permissionsState.requiredPermissionsGranted {
                Label("Microphone and Accessibility permissions are required to continue.", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundColor(.orange)
            }
        }
        .onAppear {
            refreshPermissions()
        }
        .onReceive(NotificationCenter.default.publisher(for: .permissionsStateDidChange)) { _ in
            refreshPermissions()
        }
    }
    
    private func refreshPermissions() {
        Task {
            await PermissionsManager.shared.refreshAll()
            permissionsState = await PermissionsManager.shared.state
        }
    }
}

struct PermissionRow: View {
    let type: PermissionType
    let status: PermissionStatus
    let onRequest: () async -> Void
    
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(type.displayName)
                        .fontWeight(.medium)
                    
                    if type.isRequired {
                        Text("Required")
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.orange.opacity(0.2))
                            .foregroundColor(.orange)
                            .cornerRadius(4)
                    }
                }
                
                Text(type.explanation)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            // Status indicator or button
            if status.isGranted {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                    .font(.title2)
            } else if status == .denied {
                Button("Open Settings") {
                    Task { @MainActor in
                        await PermissionsManager.shared.openSettings(for: type)
                    }
                }
                .buttonStyle(.bordered)
            } else {
                Button("Grant") {
                    Task { await onRequest() }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(.vertical, 8)
    }
}
```

### 3.6 Download Step

**File:** `Ora/Setup/Steps/DownloadStepView.swift`

```swift
//
//  DownloadStepView.swift
//  Ora
//
//  Model download step
//

import SwiftUI

struct DownloadStepView: View {
    let state: SetupState
    let onRetry: () -> Void
    
    var body: some View {
        VStack(spacing: 24) {
            Text("Downloading Models")
                .font(.largeTitle)
                .fontWeight(.bold)
            
            Text("Ora is downloading the AI models needed for voice recognition and responses.")
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            
            Spacer()
                .frame(height: 20)
            
            // Overall progress
            VStack(spacing: 16) {
                // Progress bar
                ProgressView(value: state.downloadProgress)
                    .progressViewStyle(.linear)
                
                HStack {
                    if let currentModel = state.downloadingModel {
                        Text("Downloading \(currentModel)...")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else if state.downloadProgress >= 1.0 {
                        Label("All models downloaded", systemImage: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundColor(.green)
                    }
                    
                    Spacer()
                    
                    Text("\(Int(state.downloadProgress * 100))%")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .monospacedDigit()
                }
                
                // Individual model status
                VStack(alignment: .leading, spacing: 12) {
                    ModelDownloadRow(name: "Parakeet ASR", size: "~600 MB", progress: modelProgress(for: .parakeetTDT))
                    ModelDownloadRow(name: state.recommendedModel, size: state.recommendedModel.contains("7B") ? "~5 GB" : "~2 GB", progress: modelProgress(for: state.recommendedModel.contains("7B") ? .qwen7B : .qwen3B))
                    ModelDownloadRow(name: "Kokoro TTS", size: "~500 MB", progress: modelProgress(for: .kokoro))
                }
                .padding()
                .background(Color(nsColor: .controlBackgroundColor))
                .cornerRadius(8)
            }
            
            Spacer()
            
            // Error state
            if let error = state.downloadError {
                VStack(spacing: 12) {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundColor(.red)
                    
                    Button("Retry Download") {
                        onRetry()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            
            // Note
            if state.downloadError == nil && state.downloadProgress < 1.0 {
                Label("This may take a few minutes depending on your internet speed.", systemImage: "info.circle")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }
    
    private func modelProgress(for model: ModelIdentifier) -> Double {
        // In a real implementation, this would come from ModelManager state
        // For now, approximate based on overall progress
        return state.downloadProgress
    }
}

struct ModelDownloadRow: View {
    let name: String
    let size: String
    let progress: Double
    
    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                Text(name)
                    .fontWeight(.medium)
                Text(size)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            if progress >= 1.0 {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
            } else if progress > 0 {
                ProgressView()
                    .scaleEffect(0.7)
            } else {
                Image(systemName: "circle")
                    .foregroundColor(.secondary)
            }
        }
    }
}
```

### 3.7 Ready Step

**File:** `Ora/Setup/Steps/ReadyStepView.swift`

```swift
//
//  ReadyStepView.swift
//  Ora
//
//  Setup complete step
//

import SwiftUI

struct ReadyStepView: View {
    var body: some View {
        VStack(spacing: 24) {
            // Success icon
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 80))
                .foregroundColor(.green)
            
            Text("You're All Set!")
                .font(.largeTitle)
                .fontWeight(.bold)
            
            Text("Ora is ready to assist you.")
                .font(.title3)
                .foregroundColor(.secondary)
            
            Spacer()
                .frame(height: 20)
            
            // Hotkey tutorial
            VStack(spacing: 16) {
                Text("How to Use Ora")
                    .font(.headline)
                
                HStack(spacing: 20) {
                    TutorialStep(
                        number: 1,
                        icon: "keyboard",
                        title: "Press & Hold",
                        description: "⌥ Space"
                    )
                    
                    Image(systemName: "arrow.right")
                        .foregroundColor(.secondary)
                    
                    TutorialStep(
                        number: 2,
                        icon: "waveform",
                        title: "Speak",
                        description: "Say your request"
                    )
                    
                    Image(systemName: "arrow.right")
                        .foregroundColor(.secondary)
                    
                    TutorialStep(
                        number: 3,
                        icon: "hand.raised",
                        title: "Release",
                        description: "Let go to send"
                    )
                }
            }
            .padding()
            .background(Color(nsColor: .controlBackgroundColor))
            .cornerRadius(8)
            
            Spacer()
            
            Text("You can change settings anytime from the menu bar icon.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
}

struct TutorialStep: View {
    let number: Int
    let icon: String
    let title: String
    let description: String
    
    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.1))
                    .frame(width: 50, height: 50)
                
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundColor(.accentColor)
            }
            
            Text(title)
                .font(.caption)
                .fontWeight(.medium)
            
            Text(description)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }
}
```

---

## 4. Integration with AppDelegate

**Update:** `Ora/AppDelegate.swift`

```swift
func applicationDidFinishLaunching(_ notification: Notification) {
    // ... existing code ...
    
    // Check if setup is needed
    SetupCoordinator.shared.checkAndShowSetupIfNeeded()
    
    // Listen for setup completion
    NotificationCenter.default.addObserver(
        forName: .setupDidComplete,
        object: nil,
        queue: .main
    ) { [weak self] _ in
        self?.onSetupComplete()
    }
}

private func onSetupComplete() {
    logger.info("Setup complete, initializing main functionality")
    // Initialize hotkey, warmup models, etc.
}
```

---

## 5. Acceptance Criteria

### Flow

- [ ] **AC-1:** Setup window appears on first launch
- [ ] **AC-2:** Setup window does not appear if already completed
- [ ] **AC-3:** Steps progress in order: Welcome → Permissions → Download → Ready
- [ ] **AC-4:** "Later" button postpones setup (shows minimal UI)

### Welcome Step

- [ ] **AC-5:** System RAM displayed correctly
- [ ] **AC-6:** Recommended model shown based on RAM (7B for ≥16GB, 3B for <16GB)

### Permissions Step

- [ ] **AC-7:** All permission types shown with status
- [ ] **AC-8:** "Grant" button requests permission
- [ ] **AC-9:** "Open Settings" shown for denied permissions
- [ ] **AC-10:** Cannot proceed without required permissions

### Download Step

- [ ] **AC-11:** Progress bar shows overall download progress
- [ ] **AC-12:** Individual model progress displayed
- [ ] **AC-13:** Error message and retry button on failure
- [ ] **AC-14:** Auto-advances to Ready when complete

### Ready Step

- [ ] **AC-15:** Hotkey tutorial displayed
- [ ] **AC-16:** "Done" button completes setup and dismisses window

### Persistence

- [ ] **AC-17:** Setup completion persisted to UserDefaults
- [ ] **AC-18:** If models missing after setup complete, download step shown

---

## 6. Directory Structure

```
Ora/
└── Setup/
    ├── SetupState.swift
    ├── SetupCoordinator.swift
    ├── SetupWindow.swift
    └── Steps/
        ├── WelcomeStepView.swift
        ├── PermissionsStepView.swift
        ├── DownloadStepView.swift
        └── ReadyStepView.swift
```

---

## 7. Implementation Checklist

- [ ] Create `SetupState.swift`
- [ ] Create `SetupCoordinator.swift`
- [ ] Create `SetupWindow.swift`
- [ ] Create `WelcomeStepView.swift`
- [ ] Create `PermissionsStepView.swift`
- [ ] Create `DownloadStepView.swift`
- [ ] Create `ReadyStepView.swift`
- [ ] Integrate with AppDelegate
- [ ] Test full setup flow
- [ ] Test postpone functionality
- [ ] Test resume after models deleted
