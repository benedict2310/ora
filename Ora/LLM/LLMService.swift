//
//  LLMService.swift
//  Ora
//
//  MLX Swift LLM runtime wrapper
//

import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXRandom
import os

/// MLX-based LLM service
actor LLMService: LLMServicing {
    
    // MARK: - Singleton
    
    static let shared = LLMService()
    
    // MARK: - Properties
    
    private let logger = Logger(subsystem: "com.ora.app", category: "LLMService")
    
    private var modelContainer: ModelContainer?
    private var isReady = false
    private var isWarmedUp = false
    
    // Configuration
    private let temperature: Float = 0.7
    private let topP: Float = 0.9
    
    // MARK: - Initialization
    
    private init() {}
    
    // MARK: - Public API
    
    /// Load the LLM model
    func prepare() async throws {
        guard !isReady else { return }
        
        // Get model first to check requirements
        let modelManager = ModelManager.shared
        let modelState = await modelManager.state
        let primaryLLM = modelState.primaryLLM
        
        guard await checkMemoryAvailable(for: primaryLLM) else {
            throw LLMServiceError.insufficientMemory
        }
        
        logger.info("Loading LLM model...")
        
        guard let modelPath = await modelManager.pathForModel(primaryLLM) else {
            throw LLMServiceError.modelNotFound
        }
        
        // Attempt to create configuration pointing to local directory
        let configuration = ModelConfiguration(directory: modelPath)
        
        let container = try await LLMModelFactory.shared.loadContainer(
            configuration: configuration
        )
        
        self.modelContainer = container
        self.isReady = true
        
        logger.info("LLM model loaded: \(primaryLLM.displayName)")
    }
    
    /// Warmup the model for faster first inference
    func warmup() async throws {
        guard isReady, !isWarmedUp, let container = modelContainer else { return }
        
        logger.info("Warming up LLM...")
        
        let prompt = "Hello"
        let generateParameters = GenerateParameters(maxTokens: 2, temperature: 0.0)
        
        let _ = try await container.perform { (model, tokenizer) -> Void in
            let tokens = tokenizer.encode(text: prompt)
            let _ = try MLXLMCommon.generate(
                promptTokens: tokens,
                parameters: generateParameters,
                model: model,
                tokenizer: tokenizer,
                didGenerate: { _ in
                    return .stop
                }
            )
        }
        
        isWarmedUp = true
        logger.info("LLM warmup complete")
    }
    
    /// Generate response tokens
    func generate(messages: [LLMMessage], maxTokens: Int = 800) async -> AsyncThrowingStream<LLMDelta, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.runGeneration(
                        messages: messages,
                        maxTokens: maxTokens,
                        continuation: continuation
                    )
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            
            continuation.onTermination = { @Sendable state in
                if case .cancelled = state {
                    task.cancel()
                }
            }
        }
    }
    
    /// Unload the model to free memory
    func unload() async {
        guard isReady else { return }
        
        logger.info("Unloading LLM model...")
        
        modelContainer = nil
        isReady = false
        isWarmedUp = false
        
        logger.info("LLM model unloaded")
        
        NotificationCenter.default.post(name: Notification.Name("LLMModelUnloaded"), object: nil)
    }
    
    // MARK: - Private
    
    private func runGeneration(
        messages: [LLMMessage],
        maxTokens: Int,
        continuation: AsyncThrowingStream<LLMDelta, Error>.Continuation
    ) async throws {
        guard isReady, let container = modelContainer else {
            throw LLMServiceError.notReady
        }
        
        let prompt = formatMessages(messages)
        logger.debug("Generating with prompt length: \(prompt.count)")
        
        let parameters = GenerateParameters(
            maxTokens: maxTokens,
            temperature: temperature,
            topP: topP
        )
        
        try await container.perform { (model, tokenizer) -> Void in
            let inputTokens = tokenizer.encode(text: prompt)
            var count = 0
            
            // Propagate errors from MLX
            let _ = try MLXLMCommon.generate(
                promptTokens: inputTokens,
                parameters: parameters,
                model: model,
                tokenizer: tokenizer,
                didGenerate: { tokens in
                    if Task.isCancelled { return .stop }
                    
                    if tokens.count > count {
                        let newTokens = Array(tokens[count...])
                        let text = tokenizer.decode(tokens: newTokens)
                        continuation.yield(.token(text))
                        count = tokens.count
                        
                        if text.contains("<|im_end|>") || text.contains("<|endoftext|>") {
                            return .stop
                        }
                    }
                    return .more
                }
            )
        }
        
        continuation.yield(.completed(totalTokens: 0))
        continuation.finish()
        
        self.logger.debug("Generation complete")
    }
    
    internal func formatMessages(_ messages: [LLMMessage]) -> String {
        var formatted = ""
        for message in messages {
            switch message.role {
            case .system: formatted += "<|im_start|>system\n\(message.content)<|im_end|>\n"
            case .user: formatted += "<|im_start|>user\n\(message.content)<|im_end|>\n"
            case .assistant: formatted += "<|im_start|>assistant\n\(message.content)<|im_end|>\n"
            case .tool: formatted += "<|im_start|>tool\n\(message.content)<|im_end|>\n"
            }
        }
        formatted += "<|im_start|>assistant\n"
        return formatted
    }
    
    // MARK: - Memory Management
    
    private func checkMemoryAvailable(for model: ModelIdentifier) async -> Bool {
        let totalRAM = ProcessInfo.processInfo.physicalMemory
        
        // AC-8: Prevent loading 7B if insufficient RAM
        // Qwen 7B requires ~5GB. macOS ~3GB.
        // We enforce 16GB minimum for 7B to ensure headroom.
        if model == .qwen7B && totalRAM < 16_000_000_000 {
            logger.error("Insufficient RAM for Qwen 7B. Required: 16GB+, Available Total: \(totalRAM / 1_000_000_000)GB")
            return false
        }
        
        return true
    }
    
    static func recommendedModel() -> ModelIdentifier {
        let totalRAM = ProcessInfo.processInfo.physicalMemory
        if totalRAM < 16_000_000_000 {
            return .qwen3B
        }
        return .qwen7B
    }
}
