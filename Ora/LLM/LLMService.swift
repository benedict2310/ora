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

struct LLMPreparedModel: Sendable {
    let runtime: any LLMGenerationRuntime
    let backend: LocalRuntimeBackend
}

struct LLMPreparationEvent: Sendable {
    enum Phase: String, Sendable { case requested, joined, completed, failed }
    let phase: Phase
    let flightID: UUID
    let model: ModelIdentifier
    let durationMilliseconds: Int
    let joined: Bool
}

/// Sole ownership transfers here before suspension; release happens under the gate.
private final class LLMRuntimeRetirement: @unchecked Sendable {
    private var runtime: (any LLMGenerationRuntime)?

    init(_ runtime: (any LLMGenerationRuntime)?) { self.runtime = runtime }

    func dispose() async {
        await self.runtime?.cleanup()
        self.runtime = nil
    }
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
    
    private var isReady = false
    private var readyModel: ModelIdentifier?
    private var isWarmedUp = false
    private var runtimeBackend: LocalRuntimeBackend = .mlxLLM
    private var generationRuntime: (any LLMGenerationRuntime)?
    private var modelContainer: ModelContainer? {
        (self.generationRuntime as? ModelContainerGenerationRuntime)?.container
    }
    private struct PreparationFlight {
        let id: UUID
        let model: ModelIdentifier
        let generation: UInt64
        let task: Task<Void, Error>
    }
    private var preparationFlight: PreparationFlight?
    private var lifecycleGeneration: UInt64 = 0
    private let injectedModelLoader: (@Sendable (ModelIdentifier) async throws -> LLMPreparedModel)?
    private let monotonicNow: @Sendable () -> Double
    private let modelSource: @Sendable () async -> ModelIdentifier
    private let preparationObserver: @Sendable (LLMPreparationEvent) -> Void
    
    // Configuration
    private let temperature: Float = 0.7
    private let topP: Float = 0.9
    
    // MARK: - Initialization

    private init() {
        self.injectedModelLoader = nil
        self.monotonicNow = { ProcessInfo.processInfo.systemUptime }
        self.modelSource = { await ModelManager.shared.state.primaryLLM }
        self.preparationObserver = { _ in }
    }

    init(runtime: any LLMGenerationRuntime, isReady: Bool = true, backend: LocalRuntimeBackend = .mlxLLM) {
        self.generationRuntime = runtime
        self.isReady = isReady
        self.runtimeBackend = backend
        self.injectedModelLoader = nil
        self.monotonicNow = { ProcessInfo.processInfo.systemUptime }
        self.modelSource = { .qwen3_4B }
        self.readyModel = isReady ? .qwen3_4B : nil
        self.preparationObserver = { _ in }
    }

    /// Test seam for exercising preparation lifecycle without loading a real model.
    init(
        modelLoader: @escaping @Sendable (ModelIdentifier) async throws -> LLMPreparedModel,
        modelSource: @escaping @Sendable () async -> ModelIdentifier = { .qwen3_4B },
        monotonicNow: @escaping @Sendable () -> Double = { ProcessInfo.processInfo.systemUptime },
        preparationObserver: @escaping @Sendable (LLMPreparationEvent) -> Void = { _ in }
    ) {
        self.injectedModelLoader = modelLoader
        self.modelSource = modelSource
        self.monotonicNow = monotonicNow
        self.preparationObserver = preparationObserver
    }
    
    // MARK: - Public API
    
    /// Speculative requests carry manager eligibility into the service actor.
    /// Capture our epoch before checking it: unload may run during the callback.
    func prepareIfEligible(_ eligibility: @Sendable () async -> Bool) async throws {
        let generation = self.lifecycleGeneration
        let eligible = await eligibility()
        guard eligible, !Task.isCancelled, generation == self.lifecycleGeneration else {
            throw LLMServiceError.preparationInvalidated
        }
        try await self.prepare()
    }

    /// Load the LLM model. Concurrent callers share one physical load.
    func prepare() async throws {
        let start = self.monotonicNow()
        let generation = self.lifecycleGeneration
        let model = await self.modelSource()
        // The source is another actor: recheck every decision after this suspension.
        guard generation == self.lifecycleGeneration else {
            throw LLMServiceError.preparationInvalidated
        }
        if self.isReady, self.readyModel == model { return }
        if self.isReady {
            await self.invalidatePreparation()
            // Retirement is a suspension too. Only our own invalidation may have
            // advanced the epoch; an unload/switch must invalidate this caller.
            guard self.lifecycleGeneration == generation &+ 1 else {
                throw LLMServiceError.preparationInvalidated
            }
            return try await self.prepare()
        }

        let flight: PreparationFlight
        let joined: Bool
        if let existing = self.preparationFlight,
           existing.model == model, existing.generation == generation {
            flight = existing
            joined = true
            self.recordPreparation(.joined, flight: flight, start: start, joined: joined)
        } else {
            let id = UUID()
            let task = Task { [self] in
                try await self.performPreparation(for: model, generation: generation, id: id)
            }
            flight = PreparationFlight(id: id, model: model, generation: generation, task: task)
            self.preparationFlight = flight
            joined = false
            self.recordPreparation(.requested, flight: flight, start: start, joined: joined)
        }
        do {
            try await flight.task.value
            guard generation == self.lifecycleGeneration, self.isReady, self.readyModel == model else {
                throw LLMServiceError.preparationInvalidated
            }
            self.recordPreparation(.completed, flight: flight, start: start, joined: joined)
        } catch {
            self.recordPreparation(.failed, flight: flight, start: start, joined: joined)
            if self.preparationFlight?.id == flight.id { self.preparationFlight = nil }
            throw error
        }
        if self.preparationFlight?.id == flight.id { self.preparationFlight = nil }
    }

    private func recordPreparation(_ phase: LLMPreparationEvent.Phase, flight: PreparationFlight, start: Double, joined: Bool) {
        let duration = max(0, Int((self.monotonicNow() - start) * 1000))
        let disposition = joined ? "joined" : "started"
        self.logger.notice("LLM_PREPARATION phase=\(phase.rawValue, privacy: .public) disposition=\(disposition, privacy: .public) flight=\(flight.id.uuidString, privacy: .public) model=\(flight.model.rawValue, privacy: .public) duration_ms=\(duration, privacy: .public)")
        self.preparationObserver(LLMPreparationEvent(phase: phase, flightID: flight.id, model: flight.model, durationMilliseconds: duration, joined: joined))
    }

    private func performPreparation(for model: ModelIdentifier, generation: UInt64, id: UUID) async throws {
        var prepared: LLMPreparedModel?
        if let injectedModelLoader {
            prepared = try await injectedModelLoader(model)
        } else {
            prepared = try await self.loadProductionModel(for: model)
        }
        let currentModel = await self.modelSource()
        guard generation == self.lifecycleGeneration, model == currentModel,
              self.preparationFlight?.id == id else {
            let retired = LLMRuntimeRetirement(prepared?.runtime)
            prepared = nil
            await MLXMetalGate.shared.withExclusiveAccess { await retired.dispose() }
            throw LLMServiceError.preparationInvalidated
        }
        // The runtime owns the container too; publish the entire bundle atomically.
        self.runtimeBackend = prepared!.backend
        self.generationRuntime = prepared!.runtime
        self.readyModel = model
        self.isReady = true
    }

    private func loadProductionModel(for model: ModelIdentifier) async throws -> LLMPreparedModel {
        guard self.checkMemoryAvailable(for: model) else { throw LLMServiceError.insufficientMemory }
        guard let modelPath = await ModelManager.shared.pathForModel(model) else { throw LLMServiceError.modelNotFound }
        guard model.isRuntimeSupported else {
            throw LLMServiceError.generationFailed(
                "\(model.displayName) is not yet supported by the local inference engine. Please select a different model in the menu bar."
            )
        }
        let configuration = ModelConfiguration(directory: modelPath)
        let backend = Self.runtimeBackend(for: model)
        return try await MLXMetalGate.shared.withExclusiveAccess {
            // Loading and the allocator limit must not overlap generation or retirement.
            GPU.set(cacheLimit: 512 * 1024 * 1024)
            do {
                let container: ModelContainer
                switch backend {
                case .mlxLLM:
                    container = try await LLMModelFactory.shared.loadContainer(configuration: configuration)
                case .mlxVLM:
                    container = try await VLMModelFactory.shared.loadContainer(configuration: configuration)
                }
                return LLMPreparedModel(runtime: ModelContainerGenerationRuntime(container: container), backend: backend)
            } catch {
                Stream.gpu.synchronize()
                GPU.clearCache()
                if let factoryError = error as? ModelFactoryError {
                    throw LLMServiceError.generationFailed(factoryError.localizedDescription ?? factoryError.errorDescription ?? "Unsupported model architecture.")
                }
                throw error
            }
        }
    }

    /// Invalidate synchronously before the gate hop; never mutate newer state afterwards.
    func invalidatePreparation() async {
        self.lifecycleGeneration &+= 1
        self.preparationFlight = nil
        self.readyModel = nil
        self.isReady = false
        self.isWarmedUp = false
        self.runtimeBackend = .mlxLLM
        guard self.generationRuntime != nil else { return }
        let retired = LLMRuntimeRetirement(self.generationRuntime)
        self.generationRuntime = nil
        await MLXMetalGate.shared.withExclusiveAccess { await retired.dispose() }
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
        let wasReady = isReady
        await self.invalidatePreparation()
        guard wasReady else { return }

        logger.info("Unloading LLM model...")

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
        guard isReady, let runtime = self.generationRuntime else { return }
        await MLXMetalGate.shared.withExclusiveAccess {
            await runtime.cleanup()
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
