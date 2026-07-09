# S.05 - Always-On Continuous Listening Mode

**Epic:** Parakeet Starter Pack
**Status:** Draft
**Date:** 2025-12-27
**Dependency:** S.02 (Audio Pipeline), S.03 (Parakeet Engine Integration)
**Priority:** High

---

## 1. Objective

Implement an always-on continuous listening mode that maintains a rolling audio buffer (Minutes Pad), enabling users to retroactively transcribe the last N minutes of audio on-demand. This creates a "time machine" for audio - users can capture conversations they forgot to record.

**Goal:** Users never miss important audio again. The app silently maintains a configurable buffer (1-5 minutes) and can transcribe it instantly when triggered.

**Key Value Proposition:**
- "I wish I had recorded that" is eliminated
- Zero-friction audio capture for spontaneous moments
- Low-power operation suitable for always-on use
- Session persistence across app lifecycle

---

## 2. Scope

### In Scope

- **MinutesPad**: Memory-efficient ring buffer for continuous audio capture
- **ContinuousListeningManager**: Orchestrator for always-on mode
- **RetroactiveTranscription**: On-demand batch transcription of buffered audio
- **Session Persistence**: Resume listening after app relaunch
- **Power Management**: Low-power operation with VAD gating
- **Audio Session Handling**: Graceful interruption handling

### Out of Scope (Explicitly Excluded)

- Whisper engine support (Parakeet only)
- Clipboard/paste functionality
- Auto-paste to applications
- Visual waveform or audio level displays
- Live streaming transcription (separate from retroactive)
- Cloud sync or backup

---

## 3. Architecture

### 3.1 High-Level System Design

```
┌─────────────────────────────────────────────────────────────────────────┐
│                        Always-On Audio Pipeline                          │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                          │
│  Microphone                                                              │
│      │                                                                   │
│      ▼                                                                   │
│  ┌────────────────┐     ┌─────────────────────────────────────────────┐ │
│  │ AudioCapture   │────►│         ContinuousListeningManager          │ │
│  │ (16kHz Mono)   │     │                                             │ │
│  └────────────────┘     │  ┌─────────────┐     ┌──────────────────┐   │ │
│                         │  │ MinutesPad  │     │ LowPowerVAD      │   │ │
│                         │  │ (5 min max) │     │ (silence gating) │   │ │
│                         │  └──────┬──────┘     └────────┬─────────┘   │ │
│                         │         │                     │             │ │
│                         └─────────┼─────────────────────┼─────────────┘ │
│                                   │                     │               │
│                                   ▼                     ▼               │
│                         ┌─────────────────┐   ┌──────────────────────┐  │
│                         │ User Trigger    │   │ Power Management     │  │
│                         │ "Save Last 2m"  │   │ - CPU throttling     │  │
│                         └────────┬────────┘   │ - Sleep mode hooks   │  │
│                                  │            └──────────────────────┘  │
│                                  ▼                                      │
│                         ┌─────────────────┐                             │
│                         │ ParakeetEngine  │                             │
│                         │ (Batch Mode)    │                             │
│                         └────────┬────────┘                             │
│                                  │                                      │
│                                  ▼                                      │
│                         ┌─────────────────┐                             │
│                         │ ASRFinalSegment │                             │
│                         │ (Timestamped)   │                             │
│                         └─────────────────┘                             │
│                                                                          │
└─────────────────────────────────────────────────────────────────────────┘
```

### 3.2 Component Interaction Flow

```
                          App Launch / Resume
                                 │
                                 ▼
                    ┌────────────────────────┐
                    │ Check Persisted State  │
                    │ (UserDefaults)         │
                    └───────────┬────────────┘
                                │
               ┌────────────────┼────────────────┐
               │                │                │
               ▼                ▼                ▼
        Was Enabled?      Permissions OK?   Audio Available?
               │                │                │
               └────────────────┼────────────────┘
                                │
                    Yes to all ─┼─ No
                                │   │
                    ┌───────────▼───┼────────────┐
                    │ Start Always- │ Log reason │
                    │ On Listening  │ Stay idle  │
                    └───────────────┴────────────┘
```

---

## 4. Memory Budget & Constraints

### 4.1 Audio Buffer Memory

| Duration | Sample Rate | Channels | Sample Count | Memory (Float32) |
|----------|-------------|----------|--------------|------------------|
| 1 min    | 16 kHz      | 1        | 960,000      | ~3.84 MB         |
| 2 min    | 16 kHz      | 1        | 1,920,000    | ~7.68 MB         |
| 5 min    | 16 kHz      | 1        | 4,800,000    | ~19.2 MB         |

### 4.2 Memory Constraints

- **Maximum buffer size:** 5 minutes (~20 MB)
- **Default buffer size:** 2 minutes (~8 MB)
- **Memory warning threshold:** Reduce to 1 minute if system memory pressure detected
- **Buffer allocation:** Pre-allocated fixed-size array (no dynamic growth)

### 4.3 CPU Budget

| Operation | Target CPU | Notes |
|-----------|------------|-------|
| Idle listening | < 1% | Audio callback only, no processing |
| VAD processing | < 2% | Simple energy-based detection |
| Transcription (1 min) | < 100% for 2-3s | Burst usage, then idle |
| Transcription (5 min) | < 100% for 10-15s | Progress callback recommended |

---

## 5. Implementation Plan

### 5.1 MinutesPad (Core Ring Buffer)

A thread-safe, memory-efficient ring buffer optimized for continuous audio capture.

**File:** `Audio/MinutesPad.swift`

```swift
import Foundation
import os.log

/// Fixed-size ring buffer for continuous audio capture.
/// Thread-safe via NSLock with minimal contention.
/// Marked @unchecked Sendable because internal synchronization is manual.
final class MinutesPad: @unchecked Sendable {

    // MARK: - Types

    struct Configuration: Sendable {
        var maxDurationMinutes: Int = 5
        var sampleRate: Double = 16000.0

        var capacity: Int {
            Int(Double(maxDurationMinutes) * 60.0 * sampleRate)
        }

        var memoryFootprint: Int {
            capacity * MemoryLayout<Float>.stride
        }

        static let oneMinute = Configuration(maxDurationMinutes: 1)
        static let twoMinutes = Configuration(maxDurationMinutes: 2)
        static let fiveMinutes = Configuration(maxDurationMinutes: 5)
    }

    enum State: Sendable {
        case idle
        case capturing
        case paused
    }

    // MARK: - Properties

    private let logger = Logger(subsystem: "com.parakeet.starter", category: "MinutesPad")
    private let config: Configuration

    private var buffer: [Float]
    private var writeIndex: Int = 0
    private var totalSamplesWritten: Int64 = 0

    private let lock = NSLock()
    private var _state: State = .idle

    // MARK: - Initialization

    init(configuration: Configuration = .twoMinutes) {
        self.config = configuration
        self.buffer = [Float](repeating: 0, count: configuration.capacity)

        logger.info("MinutesPad initialized: \(configuration.maxDurationMinutes)min, \(configuration.memoryFootprint / 1_000_000)MB")
    }

    convenience init(durationMinutes: Int) {
        self.init(configuration: Configuration(maxDurationMinutes: durationMinutes))
    }

    // MARK: - Public API

    /// Current state of the pad
    var state: State {
        lock.withLock { _state }
    }

    /// Whether actively capturing audio
    var isCapturing: Bool {
        state == .capturing
    }

    /// Current buffered duration in seconds
    var currentDuration: TimeInterval {
        lock.withLock {
            let samples = min(Int(totalSamplesWritten), config.capacity)
            return TimeInterval(samples) / config.sampleRate
        }
    }

    /// Maximum duration the buffer can hold
    var maxDuration: TimeInterval {
        TimeInterval(config.maxDurationMinutes) * 60.0
    }

    /// Memory footprint in bytes
    var memoryFootprint: Int {
        config.memoryFootprint
    }

    // MARK: - Audio Capture

    /// Start capturing audio
    func startCapturing() {
        lock.withLock {
            guard _state != .capturing else { return }
            _state = .capturing
            logger.debug("Started capturing")
        }
    }

    /// Pause capturing (buffer preserved)
    func pauseCapturing() {
        lock.withLock {
            guard _state == .capturing else { return }
            _state = .paused
            logger.debug("Paused capturing")
        }
    }

    /// Resume from paused state
    func resumeCapturing() {
        lock.withLock {
            guard _state == .paused else { return }
            _state = .capturing
            logger.debug("Resumed capturing")
        }
    }

    /// Stop capturing and optionally clear buffer
    func stopCapturing(clearBuffer: Bool = false) {
        lock.withLock {
            _state = .idle
            if clearBuffer {
                resetBufferUnsafe()
            }
            logger.debug("Stopped capturing, cleared: \(clearBuffer)")
        }
    }

    /// Append audio samples to the buffer
    /// Called from audio callback - must be fast
    func append(_ samples: [Float]) {
        lock.lock()
        defer { lock.unlock() }

        guard _state == .capturing else { return }

        for sample in samples {
            buffer[writeIndex] = sample
            writeIndex = (writeIndex + 1) % config.capacity
            totalSamplesWritten += 1
        }
    }

    /// Append contiguous buffer pointer (zero-copy path)
    func append(_ pointer: UnsafeBufferPointer<Float>) {
        lock.lock()
        defer { lock.unlock() }

        guard _state == .capturing else { return }

        for sample in pointer {
            buffer[writeIndex] = sample
            writeIndex = (writeIndex + 1) % config.capacity
            totalSamplesWritten += 1
        }
    }

    // MARK: - Audio Extraction

    /// Extract the last N minutes of audio
    /// Returns empty array if no audio available
    func getLastMinutes(_ minutes: Int) -> [Float] {
        let seconds = TimeInterval(minutes) * 60.0
        return getLastSeconds(seconds)
    }

    /// Extract the last N seconds of audio
    func getLastSeconds(_ seconds: TimeInterval) -> [Float] {
        lock.lock()
        defer { lock.unlock() }

        let requestedSamples = Int(seconds * config.sampleRate)
        let availableSamples = min(Int(totalSamplesWritten), config.capacity)
        let samplesToExtract = min(requestedSamples, availableSamples)

        guard samplesToExtract > 0 else {
            logger.debug("No audio available for extraction")
            return []
        }

        var result = [Float](repeating: 0, count: samplesToExtract)
        let startIndex = (writeIndex - samplesToExtract + config.capacity) % config.capacity

        for i in 0..<samplesToExtract {
            result[i] = buffer[(startIndex + i) % config.capacity]
        }

        logger.debug("Extracted \(samplesToExtract) samples (\(seconds)s requested)")
        return result
    }

    /// Get all available audio
    func getAllAvailable() -> [Float] {
        return getLastSeconds(maxDuration)
    }

    // MARK: - Buffer Management

    /// Clear the buffer completely
    func clear() {
        lock.withLock {
            resetBufferUnsafe()
            logger.info("Buffer cleared")
        }
    }

    private func resetBufferUnsafe() {
        // Zero out is optional - just resetting indices is sufficient
        // buffer = [Float](repeating: 0, count: config.capacity)
        writeIndex = 0
        totalSamplesWritten = 0
    }

    // MARK: - Statistics

    /// Statistics for debugging and UI
    struct Statistics: Sendable {
        let state: State
        let bufferedDuration: TimeInterval
        let maxDuration: TimeInterval
        let fillPercentage: Double
        let totalSamplesWritten: Int64
        let memoryUsageMB: Double
    }

    var statistics: Statistics {
        lock.withLock {
            let buffered = min(Int(totalSamplesWritten), config.capacity)
            let duration = TimeInterval(buffered) / config.sampleRate
            let fill = Double(buffered) / Double(config.capacity)

            return Statistics(
                state: _state,
                bufferedDuration: duration,
                maxDuration: maxDuration,
                fillPercentage: fill * 100.0,
                totalSamplesWritten: totalSamplesWritten,
                memoryUsageMB: Double(config.memoryFootprint) / 1_000_000.0
            )
        }
    }
}
```

### 5.2 LowPowerVAD (Voice Activity Detection)

Simple energy-based VAD for power-efficient silence detection.

**File:** `Audio/LowPowerVAD.swift`

```swift
import Foundation
import Accelerate

/// Lightweight Voice Activity Detection for power management.
/// Uses RMS energy with adaptive threshold.
struct LowPowerVAD: Sendable {

    // MARK: - Configuration

    struct Configuration: Sendable {
        /// Minimum RMS level to consider as voice activity
        var energyThreshold: Float = 0.01

        /// Number of consecutive frames needed to confirm activity
        var activationFrames: Int = 3

        /// Number of consecutive frames needed to confirm silence
        var deactivationFrames: Int = 10

        /// Frame size in samples (10ms at 16kHz)
        var frameSamples: Int = 160

        /// Enable adaptive threshold adjustment
        var adaptiveThreshold: Bool = true

        /// Noise floor tracking decay (0-1, lower = slower)
        var noiseFloorDecay: Float = 0.995

        static let `default` = Configuration()
        static let sensitive = Configuration(energyThreshold: 0.005, activationFrames: 2)
        static let conservative = Configuration(energyThreshold: 0.02, activationFrames: 5)
    }

    // MARK: - State

    private var config: Configuration
    private var consecutiveActiveFrames: Int = 0
    private var consecutiveSilentFrames: Int = 0
    private var noiseFloor: Float = 0.001
    private var _isVoiceActive: Bool = false

    // MARK: - Initialization

    init(configuration: Configuration = .default) {
        self.config = configuration
    }

    // MARK: - Public API

    /// Current voice activity state
    var isVoiceActive: Bool {
        _isVoiceActive
    }

    /// Process audio samples and update VAD state
    /// Returns true if voice activity is detected
    mutating func process(_ samples: [Float]) -> Bool {
        guard !samples.isEmpty else { return _isVoiceActive }

        let rms = calculateRMS(samples)
        let effectiveThreshold = config.adaptiveThreshold
            ? max(config.energyThreshold, noiseFloor * 3.0)
            : config.energyThreshold

        let isFrameActive = rms > effectiveThreshold

        // Update adaptive noise floor during silence
        if !isFrameActive && config.adaptiveThreshold {
            noiseFloor = noiseFloor * config.noiseFloorDecay + rms * (1.0 - config.noiseFloorDecay)
        }

        // State machine for hysteresis
        if isFrameActive {
            consecutiveActiveFrames += 1
            consecutiveSilentFrames = 0

            if consecutiveActiveFrames >= config.activationFrames {
                _isVoiceActive = true
            }
        } else {
            consecutiveSilentFrames += 1
            consecutiveActiveFrames = 0

            if consecutiveSilentFrames >= config.deactivationFrames {
                _isVoiceActive = false
            }
        }

        return _isVoiceActive
    }

    /// Reset VAD state
    mutating func reset() {
        consecutiveActiveFrames = 0
        consecutiveSilentFrames = 0
        noiseFloor = 0.001
        _isVoiceActive = false
    }

    // MARK: - Private

    private func calculateRMS(_ samples: [Float]) -> Float {
        var sumSquares: Float = 0
        vDSP_svesq(samples, 1, &sumSquares, vDSP_Length(samples.count))
        return sqrt(sumSquares / Float(samples.count))
    }
}
```

### 5.3 ContinuousListeningManager (Orchestrator)

The main controller that manages the always-on listening mode.

**File:** `Managers/ContinuousListeningManager.swift`

```swift
import Foundation
import AVFoundation
import os.log

/// Manages always-on continuous listening with background buffering.
/// Main entry point for the continuous listening feature.
@MainActor
final class ContinuousListeningManager: ObservableObject {

    // MARK: - Types

    enum State: Sendable, Equatable {
        case disabled
        case starting
        case listening
        case paused(reason: PauseReason)
        case transcribing(minutes: Int)
        case error(String)

        var isActive: Bool {
            switch self {
            case .listening, .transcribing: return true
            default: return false
            }
        }
    }

    enum PauseReason: Sendable, Equatable {
        case userRequested
        case audioInterruption
        case systemSleep
        case lowPower
    }

    struct Configuration: Sendable {
        var bufferDurationMinutes: Int = 2
        var enableLowPowerMode: Bool = true
        var pauseDuringCalls: Bool = true
        var resumeOnWake: Bool = true

        static let `default` = Configuration()
    }

    // MARK: - Published State

    @Published private(set) var state: State = .disabled
    @Published private(set) var bufferDuration: TimeInterval = 0
    @Published private(set) var isVoiceActive: Bool = false

    // MARK: - Properties

    private let logger = Logger(subsystem: "com.parakeet.starter", category: "ContinuousListening")
    private var config: Configuration

    private var minutesPad: MinutesPad
    private var audioCapture: AudioCaptureProtocol?
    private var engine: ParakeetEngine?

    private var vad = LowPowerVAD()
    private var updateTimer: Timer?
    private var interruptionObserver: NSObjectProtocol?

    // MARK: - Persistence Keys

    private enum Keys {
        static let wasEnabled = "continuousListening.wasEnabled"
        static let bufferMinutes = "continuousListening.bufferMinutes"
        static let lowPowerMode = "continuousListening.lowPowerMode"
    }

    // MARK: - Initialization

    init(configuration: Configuration = .default) {
        self.config = configuration
        self.minutesPad = MinutesPad(durationMinutes: configuration.bufferDurationMinutes)

        setupInterruptionHandling()
        restorePersistedState()
    }

    deinit {
        if let observer = interruptionObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Public API

    /// Start continuous listening
    func startContinuousListening() async throws {
        guard state != .listening else { return }

        logger.info("Starting continuous listening")
        state = .starting

        do {
            try await setupAudioCapture()
            try await setupEngine()

            minutesPad.startCapturing()
            startUpdateTimer()

            state = .listening
            persistState(enabled: true)

            logger.info("Continuous listening started successfully")
        } catch {
            logger.error("Failed to start: \(error.localizedDescription)")
            state = .error(error.localizedDescription)
            throw error
        }
    }

    /// Stop continuous listening
    func stopContinuousListening() async {
        logger.info("Stopping continuous listening")

        stopUpdateTimer()
        minutesPad.stopCapturing(clearBuffer: false)
        await audioCapture?.stop()

        state = .disabled
        persistState(enabled: false)
    }

    /// Pause listening (preserves buffer)
    func pauseListening(reason: PauseReason) {
        guard state == .listening else { return }

        logger.info("Pausing: \(String(describing: reason))")
        minutesPad.pauseCapturing()
        state = .paused(reason: reason)
    }

    /// Resume from paused state
    func resumeListening() async throws {
        guard case .paused = state else { return }

        logger.info("Resuming listening")
        minutesPad.resumeCapturing()
        state = .listening
    }

    /// Transcribe the last N minutes of buffered audio
    func transcribeLastMinutes(_ minutes: Int) async throws -> ASRFinalSegment {
        guard state.isActive || state == .disabled else {
            throw ContinuousListeningError.notAvailable
        }

        logger.info("Transcribing last \(minutes) minutes")
        let previousState = state
        state = .transcribing(minutes: minutes)

        defer {
            state = previousState == .transcribing(minutes: minutes) ? .listening : previousState
        }

        let samples = minutesPad.getLastMinutes(minutes)

        guard !samples.isEmpty else {
            throw ContinuousListeningError.noAudioAvailable
        }

        let engine = try await getOrCreateEngine()
        try await engine.prepare()

        guard let segment = try await engine.finalize(samples: samples, language: nil) else {
            throw ContinuousListeningError.transcriptionFailed
        }

        logger.info("Transcription complete: \(segment.text.prefix(50))...")
        return segment
    }

    /// Save the last N minutes of audio to a file
    func saveLastMinutes(_ minutes: Int, to url: URL) async throws {
        logger.info("Saving last \(minutes) minutes to \(url.lastPathComponent)")

        let samples = minutesPad.getLastMinutes(minutes)

        guard !samples.isEmpty else {
            throw ContinuousListeningError.noAudioAvailable
        }

        try await writeWAVFile(samples: samples, to: url)
        logger.info("Saved \(samples.count) samples to file")
    }

    /// Clear the audio buffer
    func clearBuffer() {
        minutesPad.clear()
        bufferDuration = 0
    }

    /// Update configuration (restarts if currently listening)
    func updateConfiguration(_ newConfig: Configuration) async throws {
        let wasListening = state == .listening

        if wasListening {
            await stopContinuousListening()
        }

        config = newConfig
        minutesPad = MinutesPad(durationMinutes: newConfig.bufferDurationMinutes)

        persistConfiguration()

        if wasListening {
            try await startContinuousListening()
        }
    }

    // MARK: - Buffer Statistics

    var statistics: MinutesPad.Statistics {
        minutesPad.statistics
    }

    var maxBufferDuration: TimeInterval {
        minutesPad.maxDuration
    }

    // MARK: - Audio Capture Setup

    private func setupAudioCapture() async throws {
        // Create audio capture instance
        // This is protocol-based to allow testing
        let capture = DefaultAudioCapture()

        capture.onSamples = { [weak self] samples in
            self?.handleAudioSamples(samples)
        }

        try await capture.start()
        self.audioCapture = capture
    }

    private func handleAudioSamples(_ samples: [Float]) {
        // Feed to MinutesPad
        minutesPad.append(samples)

        // Update VAD state (for power management)
        let wasActive = vad.isVoiceActive
        let isActive = vad.process(samples)

        if wasActive != isActive {
            Task { @MainActor in
                self.isVoiceActive = isActive
            }
        }
    }

    // MARK: - Engine Management

    private func setupEngine() async throws {
        engine = ParakeetEngine()
        try await engine?.prepare()
    }

    private func getOrCreateEngine() async throws -> ParakeetEngine {
        if let existing = engine {
            return existing
        }

        let newEngine = ParakeetEngine()
        try await newEngine.prepare()
        engine = newEngine
        return newEngine
    }

    // MARK: - Update Timer

    private func startUpdateTimer() {
        updateTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateBufferDuration()
            }
        }
    }

    private func stopUpdateTimer() {
        updateTimer?.invalidate()
        updateTimer = nil
    }

    private func updateBufferDuration() {
        bufferDuration = minutesPad.currentDuration
    }

    // MARK: - Interruption Handling

    private func setupInterruptionHandling() {
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.handleInterruption(notification)
        }

        // Also observe system sleep/wake
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleSystemSleep()
        }

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleSystemWake()
        }
    }

    private func handleInterruption(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else {
            return
        }

        switch type {
        case .began:
            logger.info("Audio interruption began")
            if config.pauseDuringCalls {
                pauseListening(reason: .audioInterruption)
            }

        case .ended:
            logger.info("Audio interruption ended")
            if state == .paused(reason: .audioInterruption) {
                Task {
                    try? await resumeListening()
                }
            }

        @unknown default:
            break
        }
    }

    private func handleSystemSleep() {
        logger.info("System going to sleep")
        if state == .listening {
            pauseListening(reason: .systemSleep)
        }
    }

    private func handleSystemWake() {
        logger.info("System woke from sleep")
        if config.resumeOnWake && state == .paused(reason: .systemSleep) {
            Task {
                try? await resumeListening()
            }
        }
    }

    // MARK: - Persistence

    private func persistState(enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Keys.wasEnabled)
    }

    private func persistConfiguration() {
        UserDefaults.standard.set(config.bufferDurationMinutes, forKey: Keys.bufferMinutes)
        UserDefaults.standard.set(config.enableLowPowerMode, forKey: Keys.lowPowerMode)
    }

    private func restorePersistedState() {
        if UserDefaults.standard.object(forKey: Keys.bufferMinutes) != nil {
            config.bufferDurationMinutes = UserDefaults.standard.integer(forKey: Keys.bufferMinutes)
            config.enableLowPowerMode = UserDefaults.standard.bool(forKey: Keys.lowPowerMode)
            minutesPad = MinutesPad(durationMinutes: config.bufferDurationMinutes)
        }

        // Auto-resume if was enabled before quit
        if UserDefaults.standard.bool(forKey: Keys.wasEnabled) {
            Task {
                try? await startContinuousListening()
            }
        }
    }

    // MARK: - WAV Export

    private func writeWAVFile(samples: [Float], to url: URL) async throws {
        try await Task.detached(priority: .utility) {
            let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 16000,
                channels: 1,
                interleaved: false
            )!

            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(samples.count)
            ) else {
                throw ContinuousListeningError.bufferCreationFailed
            }

            buffer.frameLength = AVAudioFrameCount(samples.count)
            memcpy(buffer.floatChannelData![0], samples, samples.count * MemoryLayout<Float>.stride)

            let file = try AVAudioFile(
                forWriting: url,
                settings: format.settings,
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )

            try file.write(from: buffer)
        }.value
    }
}

// MARK: - Errors

enum ContinuousListeningError: LocalizedError {
    case notAvailable
    case noAudioAvailable
    case transcriptionFailed
    case bufferCreationFailed
    case permissionDenied

    var errorDescription: String? {
        switch self {
        case .notAvailable:
            return "Continuous listening is not available"
        case .noAudioAvailable:
            return "No audio available in buffer"
        case .transcriptionFailed:
            return "Transcription failed"
        case .bufferCreationFailed:
            return "Failed to create audio buffer"
        case .permissionDenied:
            return "Microphone permission denied"
        }
    }
}

// MARK: - Audio Capture Protocol

protocol AudioCaptureProtocol: AnyObject, Sendable {
    var onSamples: (([Float]) -> Void)? { get set }
    func start() async throws
    func stop() async
}

/// Default implementation using AVAudioEngine
final class DefaultAudioCapture: AudioCaptureProtocol, @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var _onSamples: (([Float]) -> Void)?

    var onSamples: (([Float]) -> Void)? {
        get { lock.withLock { _onSamples } }
        set { lock.withLock { _onSamples = newValue } }
    }

    func start() async throws {
        let inputNode = engine.inputNode
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        )!

        // Install tap
        inputNode.installTap(
            onBus: 0,
            bufferSize: 1600, // 100ms at 16kHz
            format: format
        ) { [weak self] buffer, _ in
            guard let channelData = buffer.floatChannelData?[0] else { return }
            let samples = Array(UnsafeBufferPointer(
                start: channelData,
                count: Int(buffer.frameLength)
            ))
            self?.onSamples?(samples)
        }

        try engine.start()
    }

    func stop() async {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }
}
```

### 5.4 RetroactiveTranscriptionController (Progress Reporting)

For longer transcriptions, provide progress feedback.

**File:** `Managers/RetroactiveTranscriptionController.swift`

```swift
import Foundation
import os.log

/// Handles retroactive transcription with progress reporting.
/// Suitable for long audio buffers (3+ minutes).
@MainActor
final class RetroactiveTranscriptionController: ObservableObject {

    // MARK: - Types

    enum State: Sendable, Equatable {
        case idle
        case preparing
        case transcribing(progress: Double)
        case completed(ASRFinalSegment)
        case failed(String)
    }

    struct TranscriptionResult: Sendable {
        let segment: ASRFinalSegment
        let audioDuration: TimeInterval
        let processingTime: TimeInterval
        let realTimeFactor: Double
    }

    // MARK: - Published State

    @Published private(set) var state: State = .idle
    @Published private(set) var currentResult: TranscriptionResult?

    // MARK: - Properties

    private let logger = Logger(subsystem: "com.parakeet.starter", category: "RetroactiveTranscription")
    private var currentTask: Task<Void, Never>?

    // MARK: - Public API

    /// Transcribe audio samples with progress reporting
    func transcribe(
        samples: [Float],
        using engine: ParakeetEngine,
        chunkDuration: TimeInterval = 30.0 // Process in 30-second chunks
    ) async throws -> TranscriptionResult {

        guard !samples.isEmpty else {
            throw TranscriptionError.noAudio
        }

        let startTime = Date()
        let audioDuration = TimeInterval(samples.count) / 16000.0

        state = .preparing
        logger.info("Starting transcription of \(audioDuration)s audio")

        // For short audio, transcribe directly
        if audioDuration <= chunkDuration {
            state = .transcribing(progress: 0.5)

            try await engine.prepare()
            guard let segment = try await engine.finalize(samples: samples, language: nil) else {
                throw TranscriptionError.engineFailed
            }

            let processingTime = Date().timeIntervalSince(startTime)
            let result = TranscriptionResult(
                segment: segment,
                audioDuration: audioDuration,
                processingTime: processingTime,
                realTimeFactor: audioDuration / processingTime
            )

            state = .completed(segment)
            currentResult = result
            return result
        }

        // For longer audio, process in chunks and report progress
        let sampleRate = 16000.0
        let chunkSamples = Int(chunkDuration * sampleRate)
        var transcribedText = ""
        var allWords: [ASRWord] = []

        try await engine.prepare()

        var offset = 0
        while offset < samples.count {
            let remaining = samples.count - offset
            let chunkSize = min(chunkSamples, remaining)
            let chunk = Array(samples[offset..<(offset + chunkSize)])

            let progress = Double(offset + chunkSize) / Double(samples.count)
            state = .transcribing(progress: progress)

            if let segment = try await engine.finalize(samples: chunk, language: nil) {
                if !transcribedText.isEmpty {
                    transcribedText += " "
                }
                transcribedText += segment.text

                // Adjust word timestamps for chunk offset
                let offsetSeconds = TimeInterval(offset) / sampleRate
                let adjustedWords = segment.words.map { word in
                    ASRWord(
                        text: word.text,
                        startTime: word.startTime.map { $0 + offsetSeconds },
                        endTime: word.endTime.map { $0 + offsetSeconds },
                        confidence: word.confidence
                    )
                }
                allWords.append(contentsOf: adjustedWords)
            }

            offset += chunkSize

            // Yield to allow cancellation
            try Task.checkCancellation()
        }

        let finalSegment = ASRFinalSegment(text: transcribedText, words: allWords)
        let processingTime = Date().timeIntervalSince(startTime)

        let result = TranscriptionResult(
            segment: finalSegment,
            audioDuration: audioDuration,
            processingTime: processingTime,
            realTimeFactor: audioDuration / processingTime
        )

        state = .completed(finalSegment)
        currentResult = result

        logger.info("Transcription complete: RTF=\(result.realTimeFactor)x")
        return result
    }

    /// Cancel ongoing transcription
    func cancel() {
        currentTask?.cancel()
        currentTask = nil
        state = .idle
    }

    /// Reset state
    func reset() {
        cancel()
        currentResult = nil
    }
}

enum TranscriptionError: LocalizedError {
    case noAudio
    case engineFailed
    case cancelled

    var errorDescription: String? {
        switch self {
        case .noAudio: return "No audio to transcribe"
        case .engineFailed: return "Transcription engine failed"
        case .cancelled: return "Transcription cancelled"
        }
    }
}
```

### 5.5 Audio Session Configuration

Proper audio session setup for always-on operation.

**File:** `Audio/AudioSessionManager.swift`

```swift
import Foundation
import AVFoundation
import os.log

/// Manages audio session configuration for continuous listening.
final class AudioSessionManager: @unchecked Sendable {

    // MARK: - Singleton

    static let shared = AudioSessionManager()

    // MARK: - Types

    enum Mode {
        case idle
        case continuousListening
        case activeRecording
    }

    // MARK: - Properties

    private let logger = Logger(subsystem: "com.parakeet.starter", category: "AudioSession")
    private let lock = NSLock()
    private var _currentMode: Mode = .idle

    var currentMode: Mode {
        lock.withLock { _currentMode }
    }

    // MARK: - Configuration

    /// Configure audio session for continuous listening
    func configureForContinuousListening() throws {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()

        try session.setCategory(
            .playAndRecord,
            mode: .measurement,
            options: [
                .allowBluetooth,
                .allowBluetoothA2DP,
                .defaultToSpeaker,
                .mixWithOthers // Allow other audio to play
            ]
        )

        // Low buffer duration for responsiveness
        try session.setPreferredIOBufferDuration(0.01) // 10ms

        try session.setActive(true, options: .notifyOthersOnDeactivation)

        lock.withLock { _currentMode = .continuousListening }
        logger.info("Configured for continuous listening")
        #endif

        // macOS: No explicit session configuration needed
        // AVAudioEngine handles this automatically
    }

    /// Configure audio session for active recording
    func configureForActiveRecording() throws {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()

        try session.setCategory(
            .record,
            mode: .measurement,
            options: [
                .allowBluetooth
            ]
        )

        try session.setPreferredIOBufferDuration(0.005) // 5ms for lower latency

        try session.setActive(true, options: .notifyOthersOnDeactivation)

        lock.withLock { _currentMode = .activeRecording }
        logger.info("Configured for active recording")
        #endif
    }

    /// Deactivate audio session
    func deactivate() throws {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try session.setActive(false, options: .notifyOthersOnDeactivation)

        lock.withLock { _currentMode = .idle }
        logger.info("Audio session deactivated")
        #endif
    }
}
```

### 5.6 Power Management

Battery-aware operation for always-on mode.

**File:** `Utilities/PowerManager.swift`

```swift
import Foundation
import IOKit.ps
import os.log

/// Monitors power state and provides battery-aware recommendations.
final class PowerManager: @unchecked Sendable {

    // MARK: - Singleton

    static let shared = PowerManager()

    // MARK: - Types

    struct PowerState: Sendable {
        let isOnBattery: Bool
        let batteryLevel: Double // 0.0 - 1.0
        let isLowPower: Bool
        let recommendation: Recommendation
    }

    enum Recommendation: Sendable {
        case normal
        case reducedBuffer      // Reduce buffer to 1 minute
        case pauseListening     // Stop continuous listening
    }

    // MARK: - Properties

    private let logger = Logger(subsystem: "com.parakeet.starter", category: "PowerManager")
    private let lock = NSLock()

    // Thresholds
    private let lowBatteryThreshold: Double = 0.20
    private let criticalBatteryThreshold: Double = 0.10

    // MARK: - Public API

    /// Current power state
    var currentState: PowerState {
        let info = getPowerInfo()
        return PowerState(
            isOnBattery: !info.isPluggedIn,
            batteryLevel: info.batteryLevel,
            isLowPower: info.isLowPowerMode,
            recommendation: calculateRecommendation(info)
        )
    }

    /// Whether full continuous listening should be enabled
    var shouldEnableFullListening: Bool {
        currentState.recommendation == .normal
    }

    /// Recommended buffer duration based on power state
    var recommendedBufferMinutes: Int {
        switch currentState.recommendation {
        case .normal: return 5
        case .reducedBuffer: return 1
        case .pauseListening: return 0
        }
    }

    // MARK: - Power Info

    private struct PowerInfo {
        let isPluggedIn: Bool
        let batteryLevel: Double
        let isLowPowerMode: Bool
    }

    private func getPowerInfo() -> PowerInfo {
        #if os(macOS)
        let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue()
        let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef] ?? []

        for source in sources {
            if let desc = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: Any] {
                let isCharging = desc[kIOPSIsChargingKey] as? Bool ?? false
                let currentCapacity = desc[kIOPSCurrentCapacityKey] as? Int ?? 100
                let maxCapacity = desc[kIOPSMaxCapacityKey] as? Int ?? 100
                let powerSource = desc[kIOPSPowerSourceStateKey] as? String ?? ""

                let isPluggedIn = powerSource == kIOPSACPowerValue || isCharging
                let batteryLevel = Double(currentCapacity) / Double(maxCapacity)

                return PowerInfo(
                    isPluggedIn: isPluggedIn,
                    batteryLevel: batteryLevel,
                    isLowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled
                )
            }
        }

        // Desktop Mac or unknown - assume plugged in
        return PowerInfo(isPluggedIn: true, batteryLevel: 1.0, isLowPowerMode: false)
        #else
        // iOS
        return PowerInfo(
            isPluggedIn: UIDevice.current.batteryState == .charging || UIDevice.current.batteryState == .full,
            batteryLevel: Double(UIDevice.current.batteryLevel),
            isLowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled
        )
        #endif
    }

    private func calculateRecommendation(_ info: PowerInfo) -> Recommendation {
        // Always normal when plugged in
        if info.isPluggedIn {
            return .normal
        }

        // Critical battery - stop listening
        if info.batteryLevel < criticalBatteryThreshold {
            return .pauseListening
        }

        // Low battery or low power mode - reduce buffer
        if info.batteryLevel < lowBatteryThreshold || info.isLowPowerMode {
            return .reducedBuffer
        }

        return .normal
    }
}
```

---

## 6. Settings & Configuration

### 6.1 Settings Keys

**File:** `Utilities/ContinuousListeningSettings.swift`

```swift
import Foundation

/// Settings specific to continuous listening feature
struct ContinuousListeningSettings: Sendable {

    // MARK: - Keys

    private enum Keys {
        static let enabled = "cl.enabled"
        static let bufferMinutes = "cl.bufferMinutes"
        static let lowPowerMode = "cl.lowPowerMode"
        static let pauseDuringCalls = "cl.pauseDuringCalls"
        static let resumeOnWake = "cl.resumeOnWake"
        static let autoStart = "cl.autoStart"
    }

    // MARK: - Properties

    private let defaults: UserDefaults

    // MARK: - Initialization

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        registerDefaults()
    }

    private func registerDefaults() {
        defaults.register(defaults: [
            Keys.enabled: false,
            Keys.bufferMinutes: 2,
            Keys.lowPowerMode: true,
            Keys.pauseDuringCalls: true,
            Keys.resumeOnWake: true,
            Keys.autoStart: false
        ])
    }

    // MARK: - Settings

    var isEnabled: Bool {
        get { defaults.bool(forKey: Keys.enabled) }
        set { defaults.set(newValue, forKey: Keys.enabled) }
    }

    var bufferMinutes: Int {
        get {
            let value = defaults.integer(forKey: Keys.bufferMinutes)
            return max(1, min(5, value))
        }
        set { defaults.set(max(1, min(5, newValue)), forKey: Keys.bufferMinutes) }
    }

    var lowPowerModeEnabled: Bool {
        get { defaults.bool(forKey: Keys.lowPowerMode) }
        set { defaults.set(newValue, forKey: Keys.lowPowerMode) }
    }

    var pauseDuringCalls: Bool {
        get { defaults.bool(forKey: Keys.pauseDuringCalls) }
        set { defaults.set(newValue, forKey: Keys.pauseDuringCalls) }
    }

    var resumeOnWake: Bool {
        get { defaults.bool(forKey: Keys.resumeOnWake) }
        set { defaults.set(newValue, forKey: Keys.resumeOnWake) }
    }

    var autoStartOnLaunch: Bool {
        get { defaults.bool(forKey: Keys.autoStart) }
        set { defaults.set(newValue, forKey: Keys.autoStart) }
    }

    // MARK: - Derived Configuration

    var configuration: ContinuousListeningManager.Configuration {
        ContinuousListeningManager.Configuration(
            bufferDurationMinutes: bufferMinutes,
            enableLowPowerMode: lowPowerModeEnabled,
            pauseDuringCalls: pauseDuringCalls,
            resumeOnWake: resumeOnWake
        )
    }
}
```

---

## 7. Acceptance Criteria

### 7.1 Core Functionality

- [ ] **AC-1:** MinutesPad correctly maintains a circular buffer of configurable duration (1, 2, or 5 minutes)
- [ ] **AC-2:** Audio is captured continuously when continuous listening is enabled
- [ ] **AC-3:** `getLastMinutes(N)` returns exactly N minutes of audio (or all available if less)
- [ ] **AC-4:** Buffer wraparound works correctly after filling the entire buffer
- [ ] **AC-5:** Memory usage stays within expected bounds (see Memory Budget table)

### 7.2 Retroactive Transcription

- [ ] **AC-6:** "Transcribe Last 1/2/5 Minutes" produces accurate transcription
- [ ] **AC-7:** Transcription uses Parakeet engine in batch mode
- [ ] **AC-8:** Progress is reported for transcriptions longer than 30 seconds
- [ ] **AC-9:** Transcription can be cancelled mid-process
- [ ] **AC-10:** Word timestamps are accurate and aligned to original audio position

### 7.3 Session Persistence

- [ ] **AC-11:** Enabled state persists across app relaunch
- [ ] **AC-12:** Buffer configuration (duration) persists across app relaunch
- [ ] **AC-13:** Audio buffer is cleared on app quit (privacy)
- [ ] **AC-14:** Listening resumes automatically if was enabled before quit

### 7.4 Power Management

- [ ] **AC-15:** CPU usage during idle listening is < 1%
- [ ] **AC-16:** Low power mode reduces buffer size automatically
- [ ] **AC-17:** Critical battery (< 10%) pauses continuous listening
- [ ] **AC-18:** VAD gating prevents unnecessary processing during silence

### 7.5 Audio Session Handling

- [ ] **AC-19:** Phone call interruption pauses listening gracefully
- [ ] **AC-20:** Listening resumes after call ends (if configured)
- [ ] **AC-21:** System sleep pauses listening, wake resumes (if configured)
- [ ] **AC-22:** Siri activation does not corrupt the buffer

### 7.6 Save Functionality

- [ ] **AC-23:** "Save Last N Minutes" exports valid WAV file
- [ ] **AC-24:** Exported WAV is 16kHz mono Float32
- [ ] **AC-25:** File save location is user-configurable

---

## 8. Test Cases

### 8.1 MinutesPad Unit Tests

**File:** `Tests/MinutesPadTests.swift`

```swift
import XCTest
@testable import ParakeetStarter

final class MinutesPadTests: XCTestCase {

    // MARK: - Initialization

    func test_init_createsEmptyBuffer() {
        let pad = MinutesPad(durationMinutes: 1)

        XCTAssertEqual(pad.currentDuration, 0)
        XCTAssertEqual(pad.state, .idle)
        XCTAssertFalse(pad.isCapturing)
    }

    func test_init_allocatesCorrectMemory() {
        let pad = MinutesPad(durationMinutes: 2)

        // 2 minutes * 60 seconds * 16000 samples * 4 bytes
        let expectedBytes = 2 * 60 * 16000 * 4
        XCTAssertEqual(pad.memoryFootprint, expectedBytes)
    }

    // MARK: - Basic Operations

    func test_append_incrementsDuration() {
        let pad = MinutesPad(durationMinutes: 1)
        pad.startCapturing()

        let samples = [Float](repeating: 0.5, count: 16000) // 1 second
        pad.append(samples)

        XCTAssertEqual(pad.currentDuration, 1.0, accuracy: 0.01)
    }

    func test_append_whileIdle_doesNothing() {
        let pad = MinutesPad(durationMinutes: 1)
        // Not started

        let samples = [Float](repeating: 0.5, count: 16000)
        pad.append(samples)

        XCTAssertEqual(pad.currentDuration, 0)
    }

    func test_getLastMinutes_returnsCorrectSamples() {
        let pad = MinutesPad(durationMinutes: 5)
        pad.startCapturing()

        // Append 2 minutes of audio with known pattern
        for i in 0..<120 {
            let value = Float(i)
            pad.append([Float](repeating: value, count: 16000))
        }

        let result = pad.getLastMinutes(1)

        XCTAssertEqual(result.count, 60 * 16000)
        // Last minute should be values 60-119
        XCTAssertEqual(result.first!, 60.0, accuracy: 0.01)
        XCTAssertEqual(result.last!, 119.0, accuracy: 0.01)
    }

    // MARK: - Buffer Wraparound

    func test_wraparound_maintainsCorrectData() {
        let config = MinutesPad.Configuration(maxDurationMinutes: 1)
        let pad = MinutesPad(configuration: config)
        pad.startCapturing()

        // Fill buffer completely (60 seconds)
        for second in 0..<60 {
            pad.append([Float](repeating: Float(second), count: 16000))
        }

        // Buffer is now full - add 30 more seconds (wraps halfway)
        for second in 60..<90 {
            pad.append([Float](repeating: Float(second), count: 16000))
        }

        let result = pad.getLastMinutes(1)

        // Should contain seconds 30-89
        XCTAssertEqual(result.first!, 30.0, accuracy: 0.01)
        XCTAssertEqual(result.last!, 89.0, accuracy: 0.01)
    }

    func test_multipleWraparounds_dataIntegrity() {
        let pad = MinutesPad(durationMinutes: 1)
        pad.startCapturing()

        // Wrap around 5 times (5 minutes into 1 minute buffer)
        for i in 0..<300 {
            pad.append([Float](repeating: Float(i % 256), count: 16000))
        }

        let result = pad.getLastSeconds(30)

        // Should have 30 seconds of data
        XCTAssertEqual(result.count, 30 * 16000)
    }

    // MARK: - Thread Safety

    func test_concurrentReadWrite_noDataCorruption() async {
        let pad = MinutesPad(durationMinutes: 2)
        pad.startCapturing()

        await withTaskGroup(of: Void.self) { group in
            // Writers
            for i in 0..<10 {
                group.addTask {
                    for j in 0..<100 {
                        let value = Float(i * 100 + j)
                        pad.append([Float](repeating: value, count: 160))
                    }
                }
            }

            // Readers
            for _ in 0..<5 {
                group.addTask {
                    for _ in 0..<100 {
                        _ = pad.getLastSeconds(1)
                    }
                }
            }
        }

        // If we get here without crash, thread safety is working
        XCTAssertGreaterThan(pad.currentDuration, 0)
    }

    // MARK: - State Transitions

    func test_pause_preservesBuffer() {
        let pad = MinutesPad(durationMinutes: 1)
        pad.startCapturing()
        pad.append([Float](repeating: 0.5, count: 16000))

        pad.pauseCapturing()

        XCTAssertEqual(pad.state, .paused)
        XCTAssertEqual(pad.currentDuration, 1.0, accuracy: 0.01)
    }

    func test_stop_withClear_emptiesBuffer() {
        let pad = MinutesPad(durationMinutes: 1)
        pad.startCapturing()
        pad.append([Float](repeating: 0.5, count: 16000))

        pad.stopCapturing(clearBuffer: true)

        XCTAssertEqual(pad.state, .idle)
        XCTAssertEqual(pad.currentDuration, 0)
    }

    // MARK: - Edge Cases

    func test_getLastMinutes_moreThanAvailable_returnsAll() {
        let pad = MinutesPad(durationMinutes: 5)
        pad.startCapturing()

        // Only add 1 minute
        pad.append([Float](repeating: 0.5, count: 60 * 16000))

        let result = pad.getLastMinutes(3)

        // Should return only what's available
        XCTAssertEqual(result.count, 60 * 16000)
    }

    func test_getLastMinutes_emptyBuffer_returnsEmpty() {
        let pad = MinutesPad(durationMinutes: 1)

        let result = pad.getLastMinutes(1)

        XCTAssertTrue(result.isEmpty)
    }

    func test_clear_resetsStatistics() {
        let pad = MinutesPad(durationMinutes: 1)
        pad.startCapturing()
        pad.append([Float](repeating: 0.5, count: 16000))

        pad.clear()

        let stats = pad.statistics
        XCTAssertEqual(stats.bufferedDuration, 0)
        XCTAssertEqual(stats.fillPercentage, 0)
        XCTAssertEqual(stats.totalSamplesWritten, 0)
    }
}
```

### 8.2 ContinuousListeningManager Tests

**File:** `Tests/ContinuousListeningManagerTests.swift`

```swift
import XCTest
@testable import ParakeetStarter

@MainActor
final class ContinuousListeningManagerTests: XCTestCase {

    // MARK: - State Transitions

    func test_initialState_isDisabled() {
        let manager = ContinuousListeningManager()

        XCTAssertEqual(manager.state, .disabled)
        XCTAssertFalse(manager.state.isActive)
    }

    func test_start_transitionsToListening() async throws {
        let manager = createTestManager()

        try await manager.startContinuousListening()

        XCTAssertEqual(manager.state, .listening)
    }

    func test_stop_transitionsToDisabled() async throws {
        let manager = createTestManager()
        try await manager.startContinuousListening()

        await manager.stopContinuousListening()

        XCTAssertEqual(manager.state, .disabled)
    }

    func test_pause_preservesBuffer() async throws {
        let manager = createTestManager()
        try await manager.startContinuousListening()

        // Simulate some audio capture
        await simulateAudioCapture(manager, seconds: 5)

        manager.pauseListening(reason: .userRequested)

        XCTAssertTrue(manager.bufferDuration > 0)
    }

    // MARK: - Retroactive Transcription

    func test_transcribeLastMinutes_returnsSegment() async throws {
        let manager = createTestManager()
        try await manager.startContinuousListening()

        await simulateAudioCapture(manager, seconds: 30)

        let segment = try await manager.transcribeLastMinutes(1)

        XCTAssertFalse(segment.text.isEmpty)
    }

    func test_transcribeLastMinutes_noAudio_throws() async throws {
        let manager = createTestManager()
        try await manager.startContinuousListening()

        // No audio captured

        do {
            _ = try await manager.transcribeLastMinutes(1)
            XCTFail("Expected error")
        } catch ContinuousListeningError.noAudioAvailable {
            // Expected
        }
    }

    // MARK: - Persistence

    func test_persistence_restoresEnabledState() async throws {
        // Start listening
        let manager1 = createTestManager()
        try await manager1.startContinuousListening()

        // Create new manager (simulating app restart)
        let manager2 = createTestManager(sameDefaults: true)

        // Should auto-start
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(manager2.state, .listening)
    }

    // MARK: - Power Management

    func test_lowBattery_reducesBuffer() async throws {
        let manager = createTestManager()
        manager.simulateLowBattery()

        try await manager.startContinuousListening()

        // Buffer should be reduced
        XCTAssertLessThanOrEqual(manager.maxBufferDuration, 60.0)
    }

    // MARK: - Audio Interruption

    func test_audioInterruption_pausesListening() async throws {
        let manager = createTestManager()
        try await manager.startContinuousListening()

        // Simulate phone call
        manager.simulateAudioInterruption(began: true)

        XCTAssertEqual(manager.state, .paused(reason: .audioInterruption))
    }

    func test_audioInterruptionEnd_resumesListening() async throws {
        let manager = createTestManager()
        try await manager.startContinuousListening()

        manager.simulateAudioInterruption(began: true)
        manager.simulateAudioInterruption(began: false)

        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(manager.state, .listening)
    }

    // MARK: - Helpers

    private func createTestManager(sameDefaults: Bool = false) -> ContinuousListeningManager {
        // Use mock dependencies for testing
        let defaults = sameDefaults ? UserDefaults.standard : UserDefaults(suiteName: UUID().uuidString)!
        return ContinuousListeningManager()
    }

    private func simulateAudioCapture(_ manager: ContinuousListeningManager, seconds: Int) async {
        // This would need access to internal methods for testing
        // Or use dependency injection with mock audio capture
    }
}
```

### 8.3 LowPowerVAD Tests

**File:** `Tests/LowPowerVADTests.swift`

```swift
import XCTest
@testable import ParakeetStarter

final class LowPowerVADTests: XCTestCase {

    func test_silence_returnsInactive() {
        var vad = LowPowerVAD()

        let silence = [Float](repeating: 0.0, count: 160)
        let isActive = vad.process(silence)

        XCTAssertFalse(isActive)
    }

    func test_loudSignal_activatesAfterThreshold() {
        var vad = LowPowerVAD()

        let loud = [Float](repeating: 0.5, count: 160)

        // First few frames don't trigger (need consecutive frames)
        _ = vad.process(loud)
        _ = vad.process(loud)
        let isActive = vad.process(loud)

        XCTAssertTrue(isActive)
    }

    func test_hysteresis_preventsFlapping() {
        var vad = LowPowerVAD()
        vad.stabilityThreshold = 3

        let loud = [Float](repeating: 0.5, count: 160)
        let silence = [Float](repeating: 0.0, count: 160)

        // Activate
        for _ in 0..<5 {
            _ = vad.process(loud)
        }
        XCTAssertTrue(vad.isVoiceActive)

        // Single silent frame should not deactivate
        _ = vad.process(silence)
        XCTAssertTrue(vad.isVoiceActive)
    }

    func test_adaptiveThreshold_adjustsToNoise() {
        var vad = LowPowerVAD(configuration: .init(adaptiveThreshold: true))

        // Feed consistent low noise
        let noise = [Float](repeating: 0.005, count: 160)
        for _ in 0..<100 {
            _ = vad.process(noise)
        }

        // Slightly louder than noise should still be inactive
        let slightlyLouder = [Float](repeating: 0.008, count: 160)
        for _ in 0..<3 {
            _ = vad.process(slightlyLouder)
        }

        XCTAssertFalse(vad.isVoiceActive)
    }

    func test_reset_clearsState() {
        var vad = LowPowerVAD()

        let loud = [Float](repeating: 0.5, count: 160)
        for _ in 0..<10 {
            _ = vad.process(loud)
        }
        XCTAssertTrue(vad.isVoiceActive)

        vad.reset()

        XCTAssertFalse(vad.isVoiceActive)
    }
}
```

### 8.4 Integration Tests

**File:** `Tests/ContinuousListeningIntegrationTests.swift`

```swift
import XCTest
@testable import ParakeetStarter

final class ContinuousListeningIntegrationTests: XCTestCase {

    func test_endToEnd_captureAndTranscribe() async throws {
        let manager = ContinuousListeningManager()

        // Start listening
        try await manager.startContinuousListening()

        // Wait for some audio to be captured (in real test, use mock audio)
        try await Task.sleep(for: .seconds(2))

        // Stop and verify buffer has data
        XCTAssertGreaterThan(manager.bufferDuration, 0)

        // Cleanup
        await manager.stopContinuousListening()
    }

    func test_longSession_memoryStability() async throws {
        let manager = ContinuousListeningManager(
            configuration: .init(bufferDurationMinutes: 5)
        )

        try await manager.startContinuousListening()

        // Run for 30+ minutes (in real test, simulate time)
        let startMemory = getMemoryUsage()

        // Simulate 30 minutes of audio
        for _ in 0..<1800 { // 30 min in seconds
            // Feed mock audio
            try await Task.sleep(for: .milliseconds(10))
        }

        let endMemory = getMemoryUsage()

        // Memory should not grow significantly
        XCTAssertLessThan(endMemory - startMemory, 10_000_000) // < 10MB growth

        await manager.stopContinuousListening()
    }

    func test_concurrentLiveAndBackground() async throws {
        let continuousManager = ContinuousListeningManager()

        // Start continuous listening
        try await continuousManager.startContinuousListening()

        // Simultaneously do live transcription (simulated)
        let liveEngine = ParakeetEngine()
        try await liveEngine.prepare()

        // Both should work without interference
        XCTAssertTrue(continuousManager.state.isActive)

        // Cleanup
        await continuousManager.stopContinuousListening()
    }

    private func getMemoryUsage() -> Int {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4

        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }

        return result == KERN_SUCCESS ? Int(info.resident_size) : 0
    }
}
```

### 8.5 Performance Tests

**File:** `Tests/ContinuousListeningPerformanceTests.swift`

```swift
import XCTest
@testable import ParakeetStarter

final class ContinuousListeningPerformanceTests: XCTestCase {

    func test_append_performance() {
        let pad = MinutesPad(durationMinutes: 5)
        pad.startCapturing()

        let samples = [Float](repeating: 0.5, count: 1600) // 100ms

        measure {
            for _ in 0..<600 { // 1 minute
                pad.append(samples)
            }
        }
    }

    func test_extraction_performance() {
        let pad = MinutesPad(durationMinutes: 5)
        pad.startCapturing()

        // Fill buffer
        let samples = [Float](repeating: 0.5, count: 16000)
        for _ in 0..<300 { // 5 minutes
            pad.append(samples)
        }

        measure {
            for _ in 0..<10 {
                _ = pad.getLastMinutes(2)
            }
        }
    }

    func test_vadProcessing_performance() {
        var vad = LowPowerVAD()

        let samples = [Float](repeating: 0.1, count: 160) // 10ms

        measure {
            for _ in 0..<6000 { // 1 minute at 10ms frames
                _ = vad.process(samples)
            }
        }
    }
}
```

---

## 9. File Structure

### 9.1 New Files

```
ParakeetStarter/
├── Audio/
│   ├── MinutesPad.swift                    # Ring buffer implementation
│   ├── LowPowerVAD.swift                   # Voice activity detection
│   └── AudioSessionManager.swift           # Audio session configuration
├── Managers/
│   ├── ContinuousListeningManager.swift    # Main orchestrator
│   └── RetroactiveTranscriptionController.swift
├── Utilities/
│   ├── PowerManager.swift                  # Battery monitoring
│   └── ContinuousListeningSettings.swift   # User settings
└── Tests/
    ├── MinutesPadTests.swift
    ├── LowPowerVADTests.swift
    ├── ContinuousListeningManagerTests.swift
    ├── ContinuousListeningIntegrationTests.swift
    └── ContinuousListeningPerformanceTests.swift
```

### 9.2 Modified Files

```
ParakeetStarter/
├── Engine/
│   └── ParakeetEngine.swift                # Add batch transcription support
├── UI/
│   └── SettingsView.swift                  # Add continuous listening settings
└── App/
    └── AppDelegate.swift                   # Wire up continuous listening
```

---

## 10. Risks & Mitigations

| Risk | Impact | Probability | Mitigation |
|------|--------|-------------|------------|
| Memory pressure on low-RAM devices | High | Medium | Automatic buffer reduction; memory warning handling |
| Battery drain in always-on mode | High | Medium | VAD gating; low-power mode; user warnings |
| Audio session conflicts with other apps | Medium | High | Proper interruption handling; graceful degradation |
| Data loss on app crash | Medium | Low | Buffer is volatile by design (privacy); no mitigation needed |
| Parakeet engine contention | Medium | Medium | Single engine instance; queue batch requests |
| Background execution limits (iOS) | High | High | macOS only for v1; iOS requires special entitlements |

---

## 11. Privacy Considerations

- **Buffer is RAM-only**: Audio is never persisted to disk automatically
- **Clear on quit**: Buffer is explicitly cleared when app terminates
- **No network**: All processing is local
- **User control**: Easy on/off toggle; clear buffer option
- **Transparency**: Status indicator shows when listening is active

---

## 12. Future Enhancements (Out of Scope)

- Live transcription overlaid on retroactive (dual-mode)
- Keyword/wake-word detection for automatic save triggers
- Background execution on iOS (requires Audio Background Mode entitlement)
- Cloud backup of transcriptions
- Multi-device sync of listening preferences

---

## 13. Definition of Done

- [ ] All acceptance criteria (AC-1 through AC-25) verified
- [ ] All test cases pass (unit, integration, performance)
- [ ] Thread Sanitizer clean run
- [ ] Memory profiling shows no leaks in 30-minute session
- [ ] CPU profiling confirms < 1% idle usage
- [ ] Power consumption validated on battery (< 5% per hour impact)
- [ ] Documentation complete
- [ ] Code reviewed and approved

---

## 14. References

- [AVAudioEngine Documentation](https://developer.apple.com/documentation/avfaudio/avaudioengine)
- [AVAudioSession Interruption Handling](https://developer.apple.com/documentation/avfaudio/avaudiosession/responding_to_audio_session_interruptions)
- [IOKit Power Sources](https://developer.apple.com/documentation/iokit/iopowersources)
- [Ring Buffer Design Patterns](https://en.wikipedia.org/wiki/Circular_buffer)
- [Voice Activity Detection](https://en.wikipedia.org/wiki/Voice_activity_detection)
