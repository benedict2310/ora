# M.04 - Voice Processing (Noise Suppression)

**Epic:** Maintenance
**Status:** Not Started
**Priority:** P2 (Medium)
**Estimated Effort:** 1 day
**Dependencies:** None
**Target:** macOS 26 (Tahoe)
**Design Reference:** None

---

## 1. Objective

Enable Apple's built-in voice processing to improve transcription accuracy in noisy environments. Voice processing provides noise suppression, echo cancellation, and automatic gain control (AGC) with no external dependencies.

## 2. User Story

As a user, I want Ora to understand me clearly even when there's background noise (fans, AC, keyboard typing, room echo) so that I don't have to repeat myself or move to a quieter location.

## 3. Scope

### In Scope

- Enable voice processing by default on AudioCapture
- Add user preference to disable voice processing
- Graceful fallback if voice processing unavailable
- Preference UI toggle in General settings
- Status property to check if voice processing is active

### Out of Scope

- Third-party noise suppression (RNNoise, Koala)
- Custom audio filtering (high-pass, spectral subtraction)
- Echo cancellation tuning (use Apple defaults)
- Adaptive VAD thresholds (see M.03 for silence detection)

## 4. Architecture Alignment

### Component Boundaries

- **AudioCapture** (Audio layer): Enables/disables voice processing on AVAudioEngine input node
- **AudioPipeline** (Audio layer): Passes preference to AudioCapture on start
- **AppSettings** (Persistence layer): Stores user preference
- No changes to ASR, LLM, or TTS layers

### Concurrency Model

- Voice processing is configured before engine start (no runtime changes)
- AudioCapture remains `@unchecked Sendable` (AVAudioEngine is thread-safe)
- Preference changes require audio capture restart (engine must be stopped)

### Pipeline Boundaries

- Preserves ASR → LLM → Tools → TTS boundary
- Voice processing is transparent to downstream consumers
- Audio format remains 16kHz mono Float32 after processing

### Platform Support

| Platform | Availability |
|----------|--------------|
| iOS | iOS 15+ |
| macOS | macOS 14+ (Sonoma) |
| Ora target | macOS 26 (Tahoe) - fully supported |

### Voice Processing Features

| Feature | Description |
|---------|-------------|
| **Noise Suppression** | Removes steady-state background noise (fans, HVAC, hum) |
| **Echo Cancellation** | Removes speaker output from mic input (prevents feedback loops) |
| **Automatic Gain Control** | Normalizes volume levels (quiet speakers boosted, loud reduced) |

## 5. Implementation Plan (Draft)

### 5.1 Files to Create

None required - extending existing components.

### 5.2 Files to Modify

| File | Changes |
|------|---------|
| `Ora/Audio/AudioCapture.swift` | Add `setVoiceProcessingEnabled()` call, add `isVoiceProcessingEnabled` property |
| `Ora/Audio/AudioPipeline.swift` | Pass voice processing preference to AudioCapture |
| `Ora/Persistence/Models/AppSettings.swift` | Add `voiceProcessingEnabled` preference |
| `Ora/Preferences/Tabs/GeneralPreferencesView.swift` | Add toggle for voice processing |

### 5.3 Tests to Add

| Test File | Coverage |
|-----------|----------|
| `OraTests/Audio/AudioCaptureTests.swift` | Voice processing enable/disable/fallback |

**New test cases:**
- `test_voiceProcessing_enabledByDefault` - Voice processing is on when starting capture
- `test_voiceProcessing_disabledWhenRequested` - Preference disables voice processing
- `test_voiceProcessing_gracefulFallback` - Capture works even if VP fails
- `test_voiceProcessing_statusReported` - `isVoiceProcessingEnabled` reflects actual state

### 5.4 Dependencies/Config

No external dependencies or project.yml changes required.

### 5.5 Key Implementation Details

**AudioCapture Changes:**

```swift
final class AudioCapture: @unchecked Sendable {
    /// Whether voice processing is currently enabled
    private(set) var isVoiceProcessingEnabled: Bool = false

    func start(enableVoiceProcessing: Bool = true) throws {
        guard state != .running else { return }

        let inputNode = engine.inputNode

        // Enable voice processing BEFORE starting engine
        if enableVoiceProcessing {
            do {
                try inputNode.setVoiceProcessingEnabled(true)
                isVoiceProcessingEnabled = true
                logger.info("Voice processing enabled")
            } catch {
                isVoiceProcessingEnabled = false
                logger.warning("Voice processing not available: \(error)")
                // Continue without voice processing
            }
        } else {
            try? inputNode.setVoiceProcessingEnabled(false)
            isVoiceProcessingEnabled = false
        }

        // ... rest of existing start() implementation
    }
}
```

**User Preference:**

```swift
// AppSettings.swift
@Attribute var voiceProcessingEnabled: Bool = true

// GeneralPreferencesView.swift
Section("Audio") {
    Toggle("Noise suppression", isOn: $settings.voiceProcessingEnabled)
    Text("Reduces background noise and echo. Disable if you experience audio issues.")
        .font(.caption)
        .foregroundStyle(.secondary)
}
```

## 6. Acceptance Criteria

### Voice Processing

- [ ] AC-1: Voice processing is enabled by default on app start
- [ ] AC-2: Voice processing failures fall back gracefully to raw capture
- [ ] AC-3: `isVoiceProcessingEnabled` property reflects actual state
- [ ] AC-4: No audible latency increase (subjective, <20ms objective)

### User Preference

- [ ] AC-5: User can disable voice processing in Preferences → General
- [ ] AC-6: Preference persists across app restarts
- [ ] AC-7: Changing preference takes effect on next audio session

### Reliability

- [ ] AC-8: App functions correctly if voice processing unavailable on hardware
- [ ] AC-9: No crashes when toggling voice processing preference
- [ ] AC-10: Audio quality is subjectively better in noisy environments

## 7. Verification Plan

### Automated Tests

- [ ] Unit tests for enable/disable behavior
- [ ] Unit tests for fallback when voice processing fails
- [ ] Unit tests for status property accuracy

### Manual Tests

- [ ] Test with MacBook built-in mic in quiet room
- [ ] Test with MacBook built-in mic with fan/AC noise
- [ ] Test with external USB microphone
- [ ] Test with AirPods / Bluetooth headset
- [ ] Verify toggle in Preferences works
- [ ] Compare transcription accuracy with VP on vs off in noisy environment

## 8. Performance / Reliability Considerations

| Metric | Expected Impact |
|--------|-----------------|
| Latency | +10-20ms (acceptable) |
| CPU usage | Minimal (runs on audio DSP) |
| Memory | No significant change |
| Audio quality | Improved in noise, unchanged in quiet |

**Reliability:**
- Graceful fallback ensures app works even if VP unavailable
- User toggle allows disabling if issues arise
- No changes to downstream audio format

## 9. Risks & Mitigations

| Risk | Impact | Likelihood | Mitigation |
|------|--------|------------|------------|
| Voice processing crashes on some Macs | High | Low | Graceful fallback, user toggle |
| Audio quality degrades for some users | Medium | Low | User can disable in Preferences |
| Latency is noticeable | Low | Low | 10-20ms is imperceptible |
| Doesn't work with external mics | Medium | Low | Test with common USB mics |

## 10. Open Questions

- [ ] Should we show a status indicator when voice processing is active?
- [ ] Should the preference change take effect immediately (restart audio) or on next session?

---

## Implementation Summary

(TBD after implementation.)

## Code Review Findings

(TBD by review agent.)

## Completion Status

(TBD after merge.)
