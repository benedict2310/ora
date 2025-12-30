//
//  ModelTypes.swift
//  Ora
//
//  Model type definitions for AI model management
//

import Foundation

// MARK: - Model Category

/// Categories of AI models
enum ModelCategory: String, Codable, Sendable, CaseIterable {
    case asr    // Speech recognition
    case llm    // Language model
    case tts    // Text-to-speech
}

// MARK: - Model Identifier

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
        // Note: FluidAudio creates its own directory name when downloading,
        // so this must match what FluidAudio actually creates
        case .parakeetTDT: return "asr/parakeet-tdt-0.6b-v3-coreml"
        case .qwen7B: return "llm/qwen2.5-7b-instruct-4bit"
        case .qwen3B: return "llm/qwen2.5-3b-instruct-4bit"
        case .kokoro: return "tts/kokoro"
        }
    }

    /// Files that must exist to consider model valid
    var requiredFiles: [String] {
        switch self {
        case .parakeetTDT:
            // FluidAudio creates these CoreML models with capitalized names
            return ["Encoder.mlmodelc", "Decoder.mlmodelc", "JointDecision.mlmodelc", "parakeet_vocab.json"]
        case .qwen7B, .qwen3B:
            // Must include model weights to prevent treating partial downloads as complete
            return ["config.json", "tokenizer.json", "model.safetensors"]
        case .kokoro:
            // Must include model weights to prevent treating partial downloads as complete
            return ["config.json", "kokoro-v1_0.safetensors"]
        }
    }
}

// MARK: - Model Status

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

    var progress: Double? {
        if case .downloading(let progress) = self { return progress }
        return nil
    }
}

// MARK: - Model Metadata

/// Metadata for an installed model
struct ModelMetadata: Codable, Sendable, Equatable {
    let identifier: ModelIdentifier
    var version: String
    var downloadedAt: Date
    var sizeBytes: Int64
    var sha256: String?
    var isPrimary: Bool

    init(
        identifier: ModelIdentifier,
        version: String = "1.0",
        sizeBytes: Int64 = 0,
        sha256: String? = nil,
        isPrimary: Bool = false
    ) {
        self.identifier = identifier
        self.version = version
        self.downloadedAt = Date()
        self.sizeBytes = sizeBytes
        self.sha256 = sha256
        self.isPrimary = isPrimary
    }
}

// MARK: - Models State

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

    subscript(model: ModelIdentifier) -> ModelStatus {
        statuses[model] ?? .notDownloaded
    }
}

// MARK: - Notifications

extension Notification.Name {
    static let modelStateDidChange = Notification.Name("com.ora.modelStateDidChange")
    static let modelDownloadProgress = Notification.Name("com.ora.modelDownloadProgress")
}

// MARK: - Errors

enum ModelError: LocalizedError {
    case verificationFailed(ModelIdentifier)
    case downloadFailed(ModelIdentifier, String)
    case modelNotFound(ModelIdentifier)
    case downloadCancelled(ModelIdentifier)

    var errorDescription: String? {
        switch self {
        case .verificationFailed(let model):
            return "Verification failed for \(model.displayName). Please try downloading again."
        case .downloadFailed(let model, let reason):
            return "Failed to download \(model.displayName): \(reason)"
        case .modelNotFound(let model):
            return "\(model.displayName) is not downloaded."
        case .downloadCancelled(let model):
            return "Download cancelled for \(model.displayName)."
        }
    }
}
