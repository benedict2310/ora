//
//  AudioFormatConverter.swift
//  Ora
//
//  Thread-safe audio format converter for Parakeet compatibility.
//

@preconcurrency import AVFoundation
import os

/// Thread-safe audio format converter.
///
/// Converts audio from device format (typically 48kHz stereo) to
/// Parakeet's required format (16kHz mono Float32).
///
/// ## Thread Safety
/// Uses `OSAllocatedUnfairLock` to protect the converter cache.
/// Multiple threads can call `convert()` simultaneously.
///
/// ## Performance
/// - Caches AVAudioConverter instances per input format
/// - Reuses converters to avoid repeated allocation
/// - Uses priority-inheritance lock for audio thread safety
final class AudioFormatConverter: @unchecked Sendable {

    // MARK: - Types

    enum ConversionError: Error, Sendable {
        case unsupportedInputFormat
        case converterCreationFailed
        case conversionFailed(status: AVAudioConverterOutputStatus)
        case outputBufferCreationFailed
        case noChannelData
    }

    // MARK: - Properties

    /// Target format for Parakeet: 16kHz mono Float32
    let targetFormat: AVAudioFormat

    /// Cache of converters keyed by input format's ObjectIdentifier
    private let converterCache = OSAllocatedUnfairLock<[ObjectIdentifier: AVAudioConverter]>(
        initialState: [:]
    )

    // MARK: - Initialization

    init() {
        self.targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        )!
    }

    /// Initialize with custom target sample rate (for testing)
    init(targetSampleRate: Double) {
        self.targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetSampleRate,
            channels: 1,
            interleaved: false
        )!
    }

    // MARK: - Conversion

    /// Convert an AVAudioPCMBuffer to 16kHz mono Float32 samples
    /// - Parameter buffer: Input audio buffer (any format)
    /// - Returns: Array of Float samples in target format, or nil on failure
    func convert(buffer: AVAudioPCMBuffer) -> [Float]? {
        do {
            return try convertThrowing(buffer: buffer)
        } catch {
            // Log error but return nil to maintain simple API
            return nil
        }
    }

    /// Convert with detailed error reporting
    /// - Parameter buffer: Input audio buffer
    /// - Throws: `ConversionError` on failure
    /// - Returns: Array of Float samples in target format
    func convertThrowing(buffer: AVAudioPCMBuffer) throws -> [Float] {
        // Get or create converter for this input format (thread-safe)
        let formatID = ObjectIdentifier(buffer.format)

        let converter: AVAudioConverter = try converterCache.withLock { cache in
            if let existing = cache[formatID] {
                return existing
            }

            guard let newConverter = AVAudioConverter(from: buffer.format, to: targetFormat) else {
                throw ConversionError.converterCreationFailed
            }

            cache[formatID] = newConverter
            return newConverter
        }

        // Calculate output buffer size based on sample rate ratio
        let inputSampleRate = buffer.format.sampleRate
        let outputSampleRate = targetFormat.sampleRate
        let ratio = outputSampleRate / inputSampleRate
        let outputFrameCapacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * ratio))

        // Create output buffer
        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: targetFormat,
            frameCapacity: outputFrameCapacity
        ) else {
            throw ConversionError.outputBufferCreationFailed
        }

        // Perform conversion
        var error: NSError?
        // Use nonisolated(unsafe) because this closure is synchronous and blocking
        nonisolated(unsafe) var inputConsumed = false

        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            if inputConsumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            inputConsumed = true
            outStatus.pointee = .haveData
            return buffer
        }

        let status = converter.convert(to: outputBuffer, error: &error, withInputFrom: inputBlock)

        guard status != .error, error == nil else {
            throw ConversionError.conversionFailed(status: status)
        }

        // Extract Float samples from first channel
        guard let channelData = outputBuffer.floatChannelData else {
            throw ConversionError.noChannelData
        }

        // Copy samples to Swift Array
        let samples = Array(UnsafeBufferPointer(
            start: channelData[0],
            count: Int(outputBuffer.frameLength)
        ))

        return samples
    }

    /// Clear the converter cache (useful when audio device changes)
    func clearCache() {
        converterCache.withLock { cache in
            cache.removeAll()
        }
    }

    /// Get information about cached converters (for debugging)
    var cachedFormatCount: Int {
        converterCache.withLock { cache in
            cache.count
        }
    }
}
