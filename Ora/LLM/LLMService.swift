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

struct LLMPreparedRequest: Sendable {
    let messages: [LLMMessage]
    let chatMessages: [[String: any Sendable]]
    let fallbackPrompt: String
    let runtimeBackend: LocalRuntimeBackend
}

/// Transfers the actual model cache between the factory and generation runtime.
/// KVCache is not Sendable: creation, access and release must remain inside
/// MLXMetalGate's exclusive scope. Neither the service nor runtime retains it.
final class LLMRequestCache: @unchecked Sendable {
    let storage: [KVCache]

    init(storage: [KVCache]) {
        self.storage = storage
    }
}

struct LLMGenerationParameters: Sendable {
    let maxTokens: Int
    let temperature: Float
    let topP: Float
}

protocol LLMGenerationRuntime: Sendable {
    func makeCache(parameters: LLMGenerationParameters) async -> LLMRequestCache
    /// Nonthrowing cleanup, called under the Metal gate after request state is released.
    func cleanup() async
    func generate(
        request: LLMPreparedRequest,
        cache: LLMRequestCache,
        parameters: LLMGenerationParameters,
        emit: @escaping @Sendable (String) -> Bool,
        didReceiveFirstToken: @escaping @Sendable (Int) -> Void
    ) async throws -> Int
}

private final class ModelContainerGenerationRuntime: LLMGenerationRuntime, Sendable {
    let container: ModelContainer

    init(container: ModelContainer) {
        self.container = container
    }

    func makeCache(parameters: LLMGenerationParameters) async -> LLMRequestCache {
        await container.perform { context in
            LLMRequestCache(storage: context.model.newCache(parameters: GenerateParameters(
                maxTokens: parameters.maxTokens,
                temperature: parameters.temperature,
                topP: parameters.topP
            )))
        }
    }

    func cleanup() async {
        // Also drain work queued by preparation/prefill before a throw or cancellation.
        Stream.gpu.synchronize()
        GPU.clearCache()
    }

    func generate(
        request: LLMPreparedRequest,
        cache: LLMRequestCache,
        parameters: LLMGenerationParameters,
        emit: @escaping @Sendable (String) -> Bool,
        didReceiveFirstToken: @escaping @Sendable (Int) -> Void
    ) async throws -> Int {
        let mlxParameters = GenerateParameters(
            maxTokens: parameters.maxTokens,
            temperature: parameters.temperature,
            topP: parameters.topP
        )
        return try await container.perform { context -> Int in
            let input: LMInput
            let promptTokenCount: Int
            switch request.runtimeBackend {
            case .mlxLLM:
                let inputTokens: [Int]
                do {
                    inputTokens = try context.tokenizer.applyChatTemplate(messages: request.chatMessages)
                } catch {
                    inputTokens = context.tokenizer.encode(text: request.fallbackPrompt)
                }
                input = LMInput(tokens: MLXArray(inputTokens))
                promptTokenCount = inputTokens.count
            case .mlxVLM:
                let vlmUserInput = try LLMService.makeVLMUserInput(from: request.messages)
                input = try await context.processor.prepare(input: vlmUserInput)
                promptTokenCount = input.text.tokens.size
            }

            let iterator = try TokenIterator(
                input: input,
                model: context.model,
                cache: cache.storage,
                parameters: mlxParameters
            )

            let (generations, generationTask) = MLXLMCommon.generateTask(
                promptTokenCount: promptTokenCount,
                modelConfiguration: context.configuration,
                tokenizer: context.tokenizer,
                iterator: iterator
            )
            var tokenCount = 0
            var didLogFirstToken = false
            for await generation in generations {
                if Task.isCancelled { break }
                if let chunk = generation.chunk {
                    if !didLogFirstToken {
                        didLogFirstToken = true
                        didReceiveFirstToken(promptTokenCount)
                    }
                    tokenCount += 1
                    if !emit(chunk) { break }
                    if chunk.contains("<|im_end|>") ||
                       chunk.contains("<|endoftext|>") ||
                       chunk.contains("</tool_call>") {
                        break
                    }
                }
            }

            // A stream break alone does not finish the pinned runtime's producer.
            // Join it before request state is released and GPU cleanup can run.
            generationTask.cancel()
            await generationTask.value
            return tokenCount
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
    private var generationRuntime: (any LLMGenerationRuntime)?
    
    // Configuration
    private let temperature: Float = 0.7
    private let topP: Float = 0.9
    
    // MARK: - Initialization

    private init() {}

    init(runtime: any LLMGenerationRuntime, isReady: Bool = true, backend: LocalRuntimeBackend = .mlxLLM) {
        self.generationRuntime = runtime
        self.isReady = isReady
        self.runtimeBackend = backend
    }
    
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

        guard primaryLLM.isRuntimeSupported else {
            throw LLMServiceError.generationFailed(
                "\(primaryLLM.displayName) is not yet supported by the local inference engine. " +
                "Please select a different model in the menu bar."
            )
        }

        let backend = Self.runtimeBackend(for: primaryLLM)
        let container: ModelContainer
        do {
            switch backend {
            case .mlxLLM:
                container = try await LLMModelFactory.shared.loadContainer(configuration: configuration)
            case .mlxVLM:
                container = try await VLMModelFactory.shared.loadContainer(configuration: configuration)
            }
        } catch let error as ModelFactoryError {
            throw LLMServiceError.generationFailed(error.localizedDescription ?? error.errorDescription ?? "Unsupported model architecture.")
        }
        
        self.modelContainer = container
        self.runtimeBackend = backend
        self.generationRuntime = ModelContainerGenerationRuntime(container: container)
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

        // Clear GPU buffers inside the gate to prevent race with in-flight generation.
        await MLXMetalGate.shared.withExclusiveAccess {
            GPU.clearCache()
        }

        modelContainer = nil
        generationRuntime = nil
        isReady = false
        isWarmedUp = false
        runtimeBackend = .mlxLLM

        logger.info("LLM model unloaded")

        NotificationCenter.default.post(name: Notification.Name("LLMModelUnloaded"), object: nil)
    }
    
    /// Clear GPU buffers when ending a session or starting a new conversation.
    /// Foreground KV caches are request-local and discarded automatically.
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
            GPU.clearCache()
        }
    }
    
    // MARK: - Private
    
    private func runGeneration(
        messages: [LLMMessage],
        maxTokens: Int,
        continuation: AsyncThrowingStream<LLMDelta, Error>.Continuation
    ) async throws {
        guard isReady, let runtime = generationRuntime else {
            throw LLMServiceError.notReady
        }

        if messages.contains(where: \.containsImageAttachments) && !self.runtimeBackend.supportsImageInput {
            throw LLMServiceError.unsupportedInput(
                "The local model currently supports text-only input. Remove image attachments and try again."
            )
        }

        let request = LLMPreparedRequest(
            messages: messages,
            chatMessages: messages.map { ["role": $0.role.rawValue, "content": $0.textContent] },
            fallbackPrompt: formatMessagesLegacy(messages),
            runtimeBackend: runtimeBackend
        )
        let parameters = LLMGenerationParameters(maxTokens: maxTokens, temperature: temperature, topP: topP)
        let generationStart = CFAbsoluteTimeGetCurrent()

        self.logger.debug("Generating with \(messages.count) messages")
        let chunkCount = try await MLXMetalGate.shared.withExclusiveAccess {
            // This nested operation owns all request-local cache references.
            // Returning or unwinding it releases them before allocator cleanup.
            func generateRequest() async throws -> Int {
                let requestCache = await runtime.makeCache(parameters: parameters)
                return try await runtime.generate(
                    request: request,
                    cache: requestCache,
                    parameters: parameters,
                    emit: { chunk in
                        continuation.yield(.token(chunk))
                        return !Task.isCancelled
                    },
                    didReceiveFirstToken: { promptTokenCount in
                        let ttft = (CFAbsoluteTimeGetCurrent() - generationStart) * 1000
                        self.logger.info("⏱️ TTFT: \(String(format: "%.1f", ttft))ms (\(promptTokenCount) prompt tokens)")
                    }
                )
            }

            let result: Int
            do {
                result = try await generateRequest()
            } catch {
                // Nonthrowing cleanup also runs in a cancelled task, without
                // masking the original error or releasing the gate early.
                await runtime.cleanup()
                throw error
            }
            await runtime.cleanup()
            return result
        }

        let totalTime = (CFAbsoluteTimeGetCurrent() - generationStart) * 1000
        let chunksPerSec = chunkCount > 0 ? Double(chunkCount) / (totalTime / 1000) : 0
        self.logger.info("⏱️ Generation complete: \(chunkCount) decoded chunks in \(String(format: "%.1f", totalTime))ms (\(String(format: "%.1f", chunksPerSec)) chunks/s)")

        // Preserve the legacy delta field; this count represents decoded chunks.
        continuation.yield(.completed(totalTokens: chunkCount))
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

    nonisolated static func makeVLMUserInput(from messages: [LLMMessage]) throws -> UserInput {
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
    
    // MARK: - One-Shot Generation

    /// Generate a one-shot completion with an isolated KV cache.
    ///
    /// Creates a fresh KV cache that is discarded after generation completes.
    /// This keeps one-shot work isolated from foreground request state.
    func generateOneShot(prompt: String, maxTokens: Int = 800) async throws -> String {
        guard isReady, let container = modelContainer else {
            try await self.prepare()
            guard let container = modelContainer else {
                throw LLMServiceError.notReady
            }
            return try await self.runOneShotGeneration(
                prompt: prompt,
                maxTokens: maxTokens,
                container: container
            )
        }

        return try await self.runOneShotGeneration(
            prompt: prompt,
            maxTokens: maxTokens,
            container: container
        )
    }

    private func runOneShotGeneration(
        prompt: String,
        maxTokens: Int,
        container: ModelContainer
    ) async throws -> String {
        let parameters = GenerateParameters(
            maxTokens: maxTokens,
            temperature: temperature,
            topP: topP
        )

        self.logger.info("Starting one-shot generation (\(maxTokens) max tokens)")

        let result: String = try await MLXMetalGate.shared.withExclusiveAccess {
            try await container.perform { context -> String in
                let inputTokens = context.tokenizer.encode(text: prompt)
                let input = LMInput(tokens: MLXArray(inputTokens))

                // Create a fresh KV cache isolated from foreground requests.
                let freshCache = context.model.newCache(parameters: parameters)

                let iterator = try TokenIterator(
                    input: input,
                    model: context.model,
                    cache: freshCache,
                    parameters: parameters
                )

                var tokens: [String] = []

                for await generation in MLXLMCommon.generate(
                    input: input,
                    context: context,
                    iterator: iterator
                ) {
                    if Task.isCancelled { break }

                    if let chunk = generation.chunk {
                        // Stop on end-of-turn tokens
                        if chunk.contains("<|im_end|>") ||
                           chunk.contains("<|endoftext|>") {
                            break
                        }
                        tokens.append(chunk)
                    }
                }

                Stream.gpu.synchronize()
                // freshCache is discarded when this scope exits
                return tokens.joined()
            }
        }

        // Clear GPU cache after one-shot generation to free memory
        GPU.clearCache()

        self.logger.info("One-shot generation complete (\(result.count) chars)")
        return result
    }

    // MARK: - Memory Management
    
    private func checkMemoryAvailable(for model: ModelIdentifier) -> Bool {
        let totalRAM = ProcessInfo.processInfo.physicalMemory

        if !Self.hasSufficientMemory(for: model, totalRAMBytes: totalRAM) {
            let minimumRAMGB = Int(Double(model.minimumSupportedRAMBytes ?? 0) / 1_000_000_000)
            logger.error("Insufficient RAM for \(model.displayName). Required: \(minimumRAMGB)GB+, Available Total: \(totalRAM / 1_000_000_000)GB")
            return false
        }

        if model == .qwen35_4B_Vision && totalRAM < 20_000_000_000 {
            logger.warning("Low RAM headroom for Qwen3 VL 4B. Available Total: \(totalRAM / 1_000_000_000)GB")
        }
        
        return true
    }

    nonisolated static func runtimeBackend(for model: ModelIdentifier) -> LocalRuntimeBackend {
        return model.supportsImageInput ? .mlxVLM : .mlxLLM
    }

    nonisolated static func hasSufficientMemory(for model: ModelIdentifier, totalRAMBytes: UInt64) -> Bool {
        return model.isSupported(on: totalRAMBytes)
    }
    
    static func recommendedModel(
        totalRAMBytes: UInt64 = ProcessInfo.processInfo.physicalMemory
    ) -> ModelIdentifier {
        return .recommendedLocalLLM(for: totalRAMBytes)
    }
}
