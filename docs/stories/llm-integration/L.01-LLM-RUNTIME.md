# L.01 - LLM Runtime

**Epic:** LLM Integration
**Status:** Not Started
**Priority:** P0 (Critical Path)
**Estimated Effort:** 2-3 days
**Dependencies:** F.03 (Model Manager)
**Target:** macOS 26 (Tahoe)

---

## 1. Objective

Create an `LLMService` actor that wraps MLX Swift for local Qwen 2.5 inference with streaming token generation.

---

## 2. Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                       LLMService                             │
│                        (Actor)                               │
├─────────────────────────────────────────────────────────────┤
│  - Loads model from ModelManager path                       │
│  - Manages MLX model instance                               │
│  - Provides streaming generation                            │
│  - Handles warmup for fast TTFT                            │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────┐
│                    MLX Swift (mlx-lm)                        │
│  - Model loading                                            │
│  - Token generation                                         │
│  - KV cache management                                      │
└─────────────────────────────────────────────────────────────┘
```

---

## 3. Implementation

### 3.1 LLM Service

**File:** `Ora/LLM/LLMService.swift`

```swift
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
import os

/// Token generation events
enum LLMDelta: Sendable {
    case token(String)
    case completed(totalTokens: Int)
}

/// LLM message for conversation
struct LLMMessage: Sendable {
    enum Role: String, Sendable {
        case system
        case user
        case assistant
        case tool
    }
    
    let role: Role
    let content: String
}

/// LLM service protocol
protocol LLMServicing: Sendable {
    func generate(messages: [LLMMessage], maxTokens: Int) -> AsyncThrowingStream<LLMDelta, Error>
    func warmup() async throws
}

/// MLX-based LLM service
actor LLMService: LLMServicing {
    
    // MARK: - Singleton
    
    static let shared = LLMService()
    
    // MARK: - Properties
    
    private let logger = Logger(subsystem: "com.ora.app", category: "LLMService")
    
    private var model: LLMModel?
    private var tokenizer: Tokenizer?
    private var isReady = false
    private var isWarmedUp = false
    
    // Configuration
    private let defaultMaxTokens = 800
    private let temperature: Float = 0.7
    private let topP: Float = 0.9
    
    // MARK: - Initialization
    
    private init() {}
    
    // MARK: - Public API
    
    /// Load the LLM model
    func prepare() async throws {
        guard !isReady else { return }
        
        logger.info("Loading LLM model...")
        
        // Get model path from ModelManager
        let modelManager = await ModelManager.shared
        let modelState = await modelManager.state
        let primaryLLM = modelState.primaryLLM
        
        guard let modelPath = await modelManager.pathForModel(primaryLLM) else {
            throw LLMServiceError.modelNotFound
        }
        
        // Load model using MLX
        let configuration = ModelConfiguration(id: primaryLLM.huggingFaceRepo)
        let (loadedModel, loadedTokenizer) = try await LLMModelFactory.load(
            configuration: configuration,
            modelDirectory: modelPath
        )
        
        self.model = loadedModel
        self.tokenizer = loadedTokenizer
        self.isReady = true
        
        logger.info("LLM model loaded: \(primaryLLM.displayName)")
    }
    
    /// Warmup the model for faster first inference
    func warmup() async throws {
        guard isReady, !isWarmedUp else { return }
        
        logger.info("Warming up LLM...")
        
        // Run a tiny generation to compile Metal kernels
        let warmupMessages = [LLMMessage(role: .user, content: "Hi")]
        var tokenCount = 0
        
        for try await delta in generate(messages: warmupMessages, maxTokens: 5) {
            if case .token = delta {
                tokenCount += 1
            }
        }
        
        isWarmedUp = true
        logger.info("LLM warmup complete (generated \(tokenCount) tokens)")
    }
    
    /// Generate response tokens
    func generate(messages: [LLMMessage], maxTokens: Int = 800) -> AsyncThrowingStream<LLMDelta, Error> {
        AsyncThrowingStream { continuation in
            Task {
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
        }
    }
    
    // MARK: - Private
    
    private func runGeneration(
        messages: [LLMMessage],
        maxTokens: Int,
        continuation: AsyncThrowingStream<LLMDelta, Error>.Continuation
    ) async throws {
        guard isReady, let model = model, let tokenizer = tokenizer else {
            throw LLMServiceError.notReady
        }
        
        // Format messages for Qwen chat template
        let prompt = formatMessages(messages)
        
        // Tokenize
        let inputTokens = tokenizer.encode(text: prompt)
        
        logger.debug("Generating with \(inputTokens.count) input tokens, max \(maxTokens) output")
        
        // Generate
        var generatedTokens = 0
        let generateParameters = GenerateParameters(
            temperature: temperature,
            topP: topP,
            maxTokens: maxTokens
        )
        
        for try await token in model.generate(
            promptTokens: inputTokens,
            parameters: generateParameters
        ) {
            try Task.checkCancellation()
            
            let text = tokenizer.decode(tokens: [token])
            continuation.yield(.token(text))
            generatedTokens += 1
            
            // Check for stop tokens
            if isStopToken(token, tokenizer: tokenizer) {
                break
            }
        }
        
        continuation.yield(.completed(totalTokens: generatedTokens))
        continuation.finish()
        
        logger.debug("Generation complete: \(generatedTokens) tokens")
    }
    
    private func formatMessages(_ messages: [LLMMessage]) -> String {
        // Qwen 2.5 chat template
        var formatted = ""
        
        for message in messages {
            switch message.role {
            case .system:
                formatted += "<|im_start|>system\n\(message.content)<|im_end|>\n"
            case .user:
                formatted += "<|im_start|>user\n\(message.content)<|im_end|>\n"
            case .assistant:
                formatted += "<|im_start|>assistant\n\(message.content)<|im_end|>\n"
            case .tool:
                formatted += "<|im_start|>tool\n\(message.content)<|im_end|>\n"
            }
        }
        
        // Add assistant prefix for generation
        formatted += "<|im_start|>assistant\n"
        
        return formatted
    }
    
    private func isStopToken(_ token: Int, tokenizer: Tokenizer) -> Bool {
        let decoded = tokenizer.decode(tokens: [token])
        return decoded.contains("<|im_end|>") || decoded.contains("<|endoftext|>")
    }
}

// MARK: - Errors

enum LLMServiceError: LocalizedError {
    case notReady
    case modelNotFound
    case generationFailed(String)
    
    var errorDescription: String? {
        switch self {
        case .notReady:
            return "LLM is not ready. Please wait for model loading."
        case .modelNotFound:
            return "LLM model not found. Please download models first."
        case .generationFailed(let reason):
            return "Generation failed: \(reason)"
        }
    }
}
```

---

## 4. Memory Management

### 4.1 Memory Budget

Ora runs three ML models simultaneously. Memory must be carefully managed:

| Model | Approx. Size (4-bit) | Notes |
|:------|:---------------------|:------|
| Parakeet ASR | ~600MB | Always loaded |
| Qwen 2.5 7B | ~5GB | Primary LLM |
| Qwen 2.5 3B | ~2GB | Fallback LLM |
| Kokoro TTS | ~500MB | Can be unloaded |

**RAM Requirements:**
- **16GB Mac:** Qwen 3B recommended, TTS may unload under pressure
- **32GB+ Mac:** Qwen 7B with all models loaded

### 4.2 Memory Management Implementation

**Add to `LLMService.swift`:**

```swift
// MARK: - Memory Management

/// Estimated memory usage in bytes
var estimatedMemoryUsage: Int64 {
    guard isReady else { return 0 }
    // Qwen 7B 4-bit ≈ 5GB, 3B 4-bit ≈ 2GB
    return modelSize == .qwen7B ? 5_000_000_000 : 2_000_000_000
}

/// Check if memory is sufficient before loading
func checkMemoryAvailable() -> Bool {
    let availableMemory = os_proc_available_memory()
    let requiredMemory = estimatedMemoryUsage
    let safetyMargin: Int64 = 2_000_000_000  // Keep 2GB free
    
    return availableMemory > (requiredMemory + safetyMargin)
}

/// Unload the model to free memory
func unload() async {
    guard isReady else { return }
    
    logger.info("Unloading LLM model...")
    
    model = nil
    tokenizer = nil
    isReady = false
    isWarmedUp = false
    
    // Force memory cleanup
    autoreleasepool { }
    
    logger.info("LLM model unloaded")
    
    NotificationCenter.default.post(name: .llmModelUnloaded, object: nil)
}

/// Switch to a different model (e.g., fallback to smaller)
func switchModel(to modelID: ModelIdentifier) async throws {
    guard modelID.category == .llm else {
        throw LLMServiceError.invalidModel
    }
    
    logger.info("Switching to model: \(modelID.displayName)")
    
    // Unload current model first
    await unload()
    
    // Wait for memory to be reclaimed
    try? await Task.sleep(for: .milliseconds(500))
    
    // Check memory before loading new model
    guard checkMemoryAvailable() else {
        throw LLMServiceError.insufficientMemory
    }
    
    // Load new model
    try await prepare(modelID: modelID)
    try await warmup()
    
    logger.info("Model switch complete")
}

/// Handle memory pressure notification
func handleMemoryPressure() async {
    logger.warning("Memory pressure detected")
    
    // Option 1: Clear KV cache if possible
    // Option 2: Switch to smaller model
    // Option 3: Unload if not actively generating
    
    if !isGenerating {
        // Switch to smaller model if on 7B
        if modelSize == .qwen7B {
            try? await switchModel(to: .qwen3B)
        }
    }
}

private var isGenerating = false
private var modelSize: ModelSize = .qwen7B

enum ModelSize {
    case qwen7B
    case qwen3B
}
```

### 4.3 Automatic Model Selection

**Add to `LLMService.swift`:**

```swift
/// Select appropriate model based on available RAM
static func recommendedModel() -> ModelIdentifier {
    let totalRAM = ProcessInfo.processInfo.physicalMemory
    let availableRAM = os_proc_available_memory()
    
    // If less than 20GB total or less than 8GB available, use 3B
    if totalRAM < 20_000_000_000 || availableRAM < 8_000_000_000 {
        return .qwen3B
    }
    
    return .qwen7B
}
```

### 4.4 Memory Monitoring

```swift
/// Periodically check memory and take action if needed
func startMemoryMonitoring() {
    Task {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(30))
            
            let available = os_proc_available_memory()
            let threshold: Int64 = 1_500_000_000  // 1.5GB minimum
            
            if available < threshold {
                logger.warning("Low memory: \(available / 1_000_000)MB available")
                await handleMemoryPressure()
            }
        }
    }
}
```

---

## 5. Acceptance Criteria

- [ ] **AC-1:** Model loads from ModelManager path
- [ ] **AC-2:** `generate()` returns `AsyncThrowingStream<LLMDelta, Error>`
- [ ] **AC-3:** Tokens stream in real-time
- [ ] **AC-4:** `warmup()` reduces first-inference latency
- [ ] **AC-5:** Stop tokens detected correctly
- [ ] **AC-6:** Qwen chat template formatted correctly
- [ ] **AC-7:** `unload()` frees model memory
- [ ] **AC-8:** `switchModel()` transitions between models
- [ ] **AC-9:** Automatic model recommendation based on RAM
- [ ] **AC-10:** Memory monitoring triggers fallback under pressure

---

## 6. Implementation Checklist

- [ ] Add MLX Swift dependencies (mlx-swift-lm)
- [ ] Create `LLMService.swift`
- [ ] Implement memory management methods
- [ ] Add automatic model selection
- [ ] Add memory monitoring
- [ ] Test model loading
- [ ] Test streaming generation
- [ ] Test model switching
- [ ] Test under memory pressure
- [ ] Measure TTFT and throughput
- [ ] Add warmup on app launch
