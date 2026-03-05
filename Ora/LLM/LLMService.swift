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
import MLXVLM
import MLXRandom
import Tokenizers
import os

enum LocalRuntimeBackend: Sendable, Equatable {
    case mlxLLM
    case mlxVLM

    var supportsImageInput: Bool {
        switch self {
        case .mlxLLM:
            return false
        case .mlxVLM:
            return true
        }
    }
}

/// MLX-based LLM service
actor LLMService: LLMServicing {
    
    // MARK: - Singleton
    
    static let shared = LLMService()
    
    // MARK: - Properties
    
    private let logger = Logger.ora(category: "LLMService")
    
    private var modelContainer: ModelContainer?
    private var isReady = false
    private var isWarmedUp = false
    private var runtimeBackend: LocalRuntimeBackend = .mlxLLM
    
    /// Persistent KV cache for multi-turn conversations
    /// Created on first generation, reused across turns, cleared on session end
    /// 
    /// Note: Using nonisolated(unsafe) because KVCache is not Sendable, but we ensure
    /// thread-safe access via:
    /// 1. MLXMetalGate.shared.withExclusiveAccess serializes all GPU operations
    /// 2. All cache mutations happen within container.perform blocks
    /// 3. Cache is only accessed from within this actor
    nonisolated(unsafe) private var kvCache: [KVCache]?
    
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
        
        guard self.checkMemoryAvailable(for: primaryLLM) else {
            throw LLMServiceError.insufficientMemory
        }
        
        logger.info("Loading LLM model...")
        
        guard let modelPath = await modelManager.pathForModel(primaryLLM) else {
            throw LLMServiceError.modelNotFound
        }
        
        // Attempt to create configuration pointing to local directory
        let configuration = ModelConfiguration(directory: modelPath)

        let backend = Self.runtimeBackend(for: primaryLLM)
        let container: ModelContainer
        switch backend {
        case .mlxLLM:
            container = try await LLMModelFactory.shared.loadContainer(configuration: configuration)
        case .mlxVLM:
            container = try await VLMModelFactory.shared.loadContainer(configuration: configuration)
        }
        
        self.modelContainer = container
        self.runtimeBackend = backend
        self.isReady = true
        
        // Limit GPU cache to prevent unbounded memory growth (BUG-005)
        // MLX caches Metal buffers for reuse, but without a limit this can grow to 15GB+
        // 512MB is generous for buffer reuse while preventing excessive accumulation
        GPU.set(cacheLimit: 512 * 1024 * 1024)
        logger.info("GPU cache limit set to 512MB")
        
        logger.info("LLM model loaded: \(primaryLLM.displayName)")
    }
    
    /// Warmup the model for faster first inference
    func warmup() async throws {
        guard isReady, !isWarmedUp, let container = modelContainer else { return }
        
        logger.info("Warming up LLM...")
        
        let generateParameters = GenerateParameters(maxTokens: 2, temperature: 0.0)
        
        let _ = try await container.perform { context in
            // Use a simple warmup message with proper chat template
            let warmupMessages: [[String: any Sendable]] = [
                ["role": "user", "content": "Hello"]
            ]
            let tokens = try context.tokenizer.applyChatTemplate(messages: warmupMessages)
            let _ = try MLXLMCommon.generate(
                promptTokens: tokens,  // [Int] as expected by generate
                parameters: generateParameters,
                model: context.model,
                tokenizer: context.tokenizer,
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

    func capabilities() async -> ProviderCapabilities {
        let primaryLLM = await ModelManager.shared.state.primaryLLM
        let backend = Self.runtimeBackend(for: primaryLLM)
        return backend.supportsImageInput ? .multimodal : .textOnly
    }
    
    /// Unload the model to free memory
    func unload() async {
        guard isReady else { return }

        logger.info("Unloading LLM model...")

        // Clear KV cache and GPU buffers inside the gate to prevent race with in-flight generation.
        await MLXMetalGate.shared.withExclusiveAccess {
            self.kvCache = nil
            GPU.clearCache()
        }

        modelContainer = nil
        isReady = false
        isWarmedUp = false
        runtimeBackend = .mlxLLM

        logger.info("LLM model unloaded")

        NotificationCenter.default.post(name: Notification.Name("LLMModelUnloaded"), object: nil)
    }
    
    /// Clear the KV cache to start fresh for a new session
    /// Call this when ending a session or starting a new conversation
    func clearCache() async {
        // Guard against calling GPU.clearCache() before any model is loaded.
        // Calling GPU APIs on an uninitialized MLX Metal context causes an
        // async GPU crash that manifests in whichever test is running at the
        // time the Metal driver processes the bad command.
        guard isReady else { return }

        // Wrap in MLXMetalGate to prevent race with runGeneration.
        // GPU.clearCache() MUST be inside the lock — if called outside, a new generation
        // could start between lock release and cache clear, causing Metal buffer corruption.
        await MLXMetalGate.shared.withExclusiveAccess {
            if self.kvCache != nil {
                self.logger.info("Clearing KV cache")
                self.kvCache = nil
            }
            GPU.clearCache()
        }
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

        if messages.contains(where: \.containsImageAttachments) && !self.runtimeBackend.supportsImageInput {
            throw LLMServiceError.unsupportedInput(
                "The local model currently supports text-only input. Remove image attachments and try again."
            )
        }
        
        let chatMessages: [[String: any Sendable]] = messages.map { msg in
            ["role": msg.role.rawValue, "content": msg.textContent]
        }
        
        // Pre-compute fallback prompt outside the closure to avoid actor isolation issues
        let fallbackPrompt = formatMessagesLegacy(messages)
        
        self.logger.debug("Generating with \(messages.count) messages")
        
        let parameters = GenerateParameters(
            maxTokens: maxTokens,
            temperature: temperature,
            topP: topP
        )
        let runtimeBackend = self.runtimeBackend
        
        // Track timing for TTFT measurement
        let generationStart = CFAbsoluteTimeGetCurrent()
        
        // Use the new perform API with ModelContext
        // Wrap in MLXMetalGate to serialize GPU access with TTS
        let (tokenCount, isNewCache, promptTokenCount) = try await MLXMetalGate.shared.withExclusiveAccess {
            try await container.perform { context -> (Int, Bool, Int) in
                let input: LMInput
                let promptTokenCount: Int
                switch runtimeBackend {
                case .mlxLLM:
                    // Use applyChatTemplate to properly encode special tokens
                    // This ensures <|im_start|> becomes token 151644 (not multiple text tokens)
                    let inputTokens: [Int]
                    do {
                        inputTokens = try context.tokenizer.applyChatTemplate(messages: chatMessages)
                    } catch {
                        // Fallback to manual encoding if chat template fails
                        // This shouldn't happen with Qwen models but provides safety
                        // Note: fallbackPrompt is pre-computed above to avoid actor isolation issues
                        inputTokens = context.tokenizer.encode(text: fallbackPrompt)
                    }
                    input = LMInput(tokens: MLXArray(inputTokens))
                    promptTokenCount = inputTokens.count
                case .mlxVLM:
                    let vlmUserInput = try Self.makeVLMUserInput(from: messages)
                    input = try await context.processor.prepare(input: vlmUserInput)
                    promptTokenCount = input.text.tokens.size
                }
                
                // Initialize cache on first generation, reuse on subsequent
                let isNewCache: Bool
                if self.kvCache == nil {
                    self.logger.info("Creating new KV cache for session")
                    self.kvCache = context.model.newCache(parameters: parameters)
                    isNewCache = true
                } else {
                    let offset = self.kvCache?.first?.offset ?? 0
                    self.logger.debug("Reusing existing KV cache (offset: \(offset))")
                    isNewCache = false
                }
                
                // Create iterator with persistent cache
                let iterator = try TokenIterator(
                    input: input,
                    model: context.model,
                    cache: self.kvCache,
                    parameters: parameters
                )
                
                // Track tokens and TTFT
                var tokenCount = 0
                var ttftLogged = false
                
                // Stream tokens using the modern async API
                for await generation in MLXLMCommon.generate(
                    input: input,
                    context: context,
                    iterator: iterator
                ) {
                    if Task.isCancelled { break }
                    
                    if let chunk = generation.chunk {
                        // Log TTFT on first token
                        if !ttftLogged {
                            let ttft = (CFAbsoluteTimeGetCurrent() - generationStart) * 1000
                            let cacheStatus = isNewCache ? "new cache" : "cached"
                            self.logger.info("⏱️ TTFT: \(String(format: "%.1f", ttft))ms (\(cacheStatus), \(promptTokenCount) prompt tokens)")
                            ttftLogged = true
                        }
                        
                        tokenCount += 1
                        continuation.yield(.token(chunk))
                        
                        // Stop on end-of-turn tokens (Qwen 2.5 and Qwen 3 compatible)
                        // Qwen 3 also uses </tool_call> for tool call completion
                        if chunk.contains("<|im_end|>") || 
                           chunk.contains("<|endoftext|>") ||
                           chunk.contains("</tool_call>") {
                            break
                        }
                    }
                }
                
                // Synchronize GPU to ensure all Metal work is complete before returning
                // This prevents race conditions when starting a new generation immediately after
                Stream.gpu.synchronize()
                
                return (tokenCount, isNewCache, promptTokenCount)
            }
        }
        
        // Log generation stats
        let totalTime = (CFAbsoluteTimeGetCurrent() - generationStart) * 1000
        let tokensPerSec = tokenCount > 0 ? Double(tokenCount) / (totalTime / 1000) : 0
        self.logger.info("⏱️ Generation complete: \(tokenCount) tokens in \(String(format: "%.1f", totalTime))ms (\(String(format: "%.1f", tokensPerSec)) tok/s)")

        
        // Note: GPU.clearCache() is intentionally NOT called here (M.02 optimization)
        // The 512MB cache limit allows buffer reuse across generations for faster TTFT.
        // Cache is cleared at session end via clearCache() and when app backgrounds.
        
        continuation.yield(.completed(totalTokens: tokenCount))
        continuation.finish()
    }
    
    /// Legacy message formatting - only used as fallback if applyChatTemplate fails
    /// This manually creates ChatML format but may not properly encode special tokens
    private func formatMessagesLegacy(_ messages: [LLMMessage]) -> String {
        var formatted = ""
        for message in messages {
            switch message.role {
            case .system: formatted += "<|im_start|>system\n\(message.textContent)<|im_end|>\n"
            case .user: formatted += "<|im_start|>user\n\(message.textContent)<|im_end|>\n"
            case .assistant: formatted += "<|im_start|>assistant\n\(message.textContent)<|im_end|>\n"
            case .tool: formatted += "<|im_start|>tool\n\(message.textContent)<|im_end|>\n"
            }
        }
        formatted += "<|im_start|>assistant\n"
        return formatted
    }
    
    /// Format messages for testing - exposed for unit tests
    internal func formatMessages(_ messages: [LLMMessage]) -> String {
        return formatMessagesLegacy(messages)
    }

    nonisolated private static func makeVLMUserInput(from messages: [LLMMessage]) throws -> UserInput {
        let chat = try messages.map { message in
            let images = try message.imageAttachments.map { imageAttachment in
                let imageURL = URL(fileURLWithPath: imageAttachment.stagedFilePath)
                guard FileManager.default.fileExists(atPath: imageURL.path) else {
                    throw LLMServiceError.unsupportedInput(
                        "The attached image could not be found on disk. Please attach the image again and retry."
                    )
                }
                return UserInput.Image.url(imageURL)
            }
            return Chat.Message(
                role: Self.chatRole(for: message.role),
                content: message.textContent,
                images: images
            )
        }
        return UserInput(chat: chat)
    }

    nonisolated private static func chatRole(for role: LLMMessage.Role) -> Chat.Message.Role {
        switch role {
        case .system:
            return .system
        case .user:
            return .user
        case .assistant:
            return .assistant
        case .tool:
            return .tool
        }
    }
    
    // MARK: - Memory Management
    
    private func checkMemoryAvailable(for model: ModelIdentifier) -> Bool {
        let totalRAM = ProcessInfo.processInfo.physicalMemory

        if !Self.hasSufficientMemory(for: model, totalRAMBytes: totalRAM) {
            let minimumRAMGB = Int(Double(model.minimumSupportedRAMBytes ?? 0) / 1_000_000_000)
            logger.error("Insufficient RAM for \(model.displayName). Required: \(minimumRAMGB)GB+, Available Total: \(totalRAM / 1_000_000_000)GB")
            return false
        }

        if model == .qwen3_4B && totalRAM < 8_000_000_000 {
            logger.warning("Low RAM for Qwen 3 4B. Available Total: \(totalRAM / 1_000_000_000)GB - proceeding anyway")
        }
        
        return true
    }

    nonisolated static func runtimeBackend(for model: ModelIdentifier) -> LocalRuntimeBackend {
        return model.supportsImageInput ? .mlxVLM : .mlxLLM
    }

    nonisolated static func hasSufficientMemory(for model: ModelIdentifier, totalRAMBytes: UInt64) -> Bool {
        return model.isSupported(on: totalRAMBytes)
    }
    
    static func recommendedModel() -> ModelIdentifier {
        // Qwen 3 4B is the only active model now
        return .qwen3_4B
    }
}
