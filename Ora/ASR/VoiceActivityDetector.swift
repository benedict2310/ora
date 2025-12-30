//
//  VoiceActivityDetector.swift
//  Ora
//
//  Energy-based voice activity detection for streaming transcription.
//

import Foundation
import Accelerate

// MARK: - VAD Types

/// VAD state transitions
public enum VADTransitionType: Sendable, Equatable {
    case speechStart
    case speechEnd
}

/// Result from VAD processing
public struct VADResult: Sendable, Equatable {
    /// Whether current frame contains speech
    public let isSpeech: Bool

    /// RMS energy level (0.0-1.0 normalized)
    public let energy: Float

    /// State transition if one occurred
    public let transitionType: VADTransitionType?

    /// Number of consecutive speech frames
    public let speechFrameCount: Int

    /// Number of consecutive silence frames
    public let silenceFrameCount: Int
}

/// Configuration for voice activity detection
public struct VADConfiguration: Sendable {
    /// RMS threshold for speech detection (0.0-1.0)
    public var speechThreshold: Float

    /// RMS threshold for silence detection (hysteresis)
    public var silenceThreshold: Float

    /// Number of frames to wait before declaring silence
    public var hangoverFrames: Int

    /// Frame size in samples for VAD analysis
    public var frameSize: Int

    public init(
        speechThreshold: Float = 0.01,
        silenceThreshold: Float = 0.005,
        hangoverFrames: Int = 8,
        frameSize: Int = 480  // 30ms at 16kHz
    ) {
        self.speechThreshold = speechThreshold
        self.silenceThreshold = silenceThreshold
        self.hangoverFrames = hangoverFrames
        self.frameSize = frameSize
    }

    /// Preset for quiet environments
    public static let quiet = VADConfiguration(
        speechThreshold: 0.008,
        silenceThreshold: 0.003,
        hangoverFrames: 10
    )

    /// Preset for noisy environments
    public static let noisy = VADConfiguration(
        speechThreshold: 0.02,
        silenceThreshold: 0.01,
        hangoverFrames: 6
    )
}

// MARK: - VoiceActivityDetector Protocol

/// Protocol for voice activity detection
public protocol VoiceActivityDetector: Sendable {
    /// Process audio samples and return VAD result
    mutating func process(_ samples: [Float]) -> VADResult

    /// Reset VAD state
    mutating func reset()

    /// Current speech state
    var isSpeech: Bool { get }
}

// MARK: - EnergyVAD Implementation

/// Energy-based (RMS) voice activity detector
///
/// Uses a state machine with hysteresis and hangover to provide
/// stable speech/silence detection:
///
/// ```
///                     energy > speechThreshold
///                ┌─────────────────────────────────┐
///                │                                 │
///                ▼                                 │
/// ┌──────────────────────┐              ┌──────────────────────┐
/// │                      │              │                      │
/// │       SILENCE        │              │       SPEECH         │
/// │                      │              │                      │
/// │  - Skip transcription│              │  - Process audio     │
/// │  - Low CPU usage     │              │  - Reset hangover    │
/// │                      │              │                      │
/// └──────────────────────┘              └──────────────────────┘
///           ▲                                     │
///           │      energy < silenceThreshold      │
///           │      AND hangover == 0              │
///           └─────────────────────────────────────┘
///                   (hangover countdown during silence)
/// ```
public struct EnergyVAD: VoiceActivityDetector {

    // MARK: - Configuration

    private let speechThreshold: Float
    private let silenceThreshold: Float
    private let hangoverFrames: Int

    // MARK: - State

    private var currentState: Bool = false
    private var hangoverCounter: Int = 0
    private var speechFrameCount: Int = 0
    private var silenceFrameCount: Int = 0
    private var smoothedEnergy: Float = 0
    private let smoothingFactor: Float = 0.3

    // MARK: - Public Properties

    public var isSpeech: Bool { currentState }

    // MARK: - Initialization

    public init(configuration: VADConfiguration = VADConfiguration()) {
        self.speechThreshold = configuration.speechThreshold
        self.silenceThreshold = configuration.silenceThreshold
        self.hangoverFrames = configuration.hangoverFrames
    }

    public init(
        speechThreshold: Float = 0.01,
        silenceThreshold: Float = 0.005,
        hangoverFrames: Int = 8
    ) {
        self.speechThreshold = speechThreshold
        self.silenceThreshold = silenceThreshold
        self.hangoverFrames = hangoverFrames
    }

    // MARK: - Processing

    public mutating func process(_ samples: [Float]) -> VADResult {
        guard !samples.isEmpty else {
            return VADResult(
                isSpeech: currentState,
                energy: 0,
                transitionType: nil,
                speechFrameCount: speechFrameCount,
                silenceFrameCount: silenceFrameCount
            )
        }

        // Calculate RMS energy using Accelerate
        let energy = calculateRMS(samples)

        // Apply smoothing to reduce noise
        smoothedEnergy = smoothingFactor * energy + (1 - smoothingFactor) * smoothedEnergy

        // Determine raw speech detection
        let rawIsSpeech = smoothedEnergy > speechThreshold
        let isSilence = smoothedEnergy < silenceThreshold

        // State machine with hangover
        var transition: VADTransitionType? = nil

        if rawIsSpeech {
            // Speech detected
            if !currentState {
                transition = .speechStart
            }
            currentState = true
            hangoverCounter = hangoverFrames
            speechFrameCount += 1
            silenceFrameCount = 0
        } else if isSilence {
            // Silence detected
            silenceFrameCount += 1
            speechFrameCount = 0

            if currentState {
                // In speech state, use hangover
                if hangoverCounter > 0 {
                    hangoverCounter -= 1
                } else {
                    currentState = false
                    transition = .speechEnd
                }
            }
        } else {
            // Ambiguous region (between thresholds)
            if currentState && hangoverCounter > 0 {
                hangoverCounter -= 1
            }
        }

        return VADResult(
            isSpeech: currentState,
            energy: smoothedEnergy,
            transitionType: transition,
            speechFrameCount: speechFrameCount,
            silenceFrameCount: silenceFrameCount
        )
    }

    public mutating func reset() {
        currentState = false
        hangoverCounter = 0
        speechFrameCount = 0
        silenceFrameCount = 0
        smoothedEnergy = 0
    }

    // MARK: - Private Methods

    private func calculateRMS(_ samples: [Float]) -> Float {
        var rms: Float = 0
        vDSP_rmsqv(samples, 1, &rms, vDSP_Length(samples.count))
        return rms
    }
}
