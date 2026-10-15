//
//  LLMServiceTests.swift
//  OraTests
//
//  Tests for LLMService logic
//

import XCTest
import MLX
import MLXLMCommon
@testable import Ora

final class LLMServiceTests: XCTestCase {
    
    // MARK: - Template Tests
    
    func testFormatMessages() async {
        let service = LLMService.shared
        
        let messages = [
            LLMMessage(role: .system, content: "You are helpful."),
            LLMMessage(role: .user, content: "Hello"),
            LLMMessage(role: .assistant, content: "Hi there"),
            LLMMessage(role: .tool, content: "Tool output")
        ]
        
        let formatted = await service.formatMessages(messages)
        
        // Expected Qwen format (ChatML)
        XCTAssertTrue(formatted.contains("<|im_start|>system\nYou are helpful.<|im_end|>\n"))
        XCTAssertTrue(formatted.contains("<|im_start|>user\nHello<|im_end|>\n"))
        XCTAssertTrue(formatted.contains("<|im_start|>assistant\nHi there<|im_end|>\n"))
        XCTAssertTrue(formatted.contains("<|im_start|>tool\nTool output<|im_end|>\n"))
        XCTAssertTrue(formatted.hasSuffix("<|im_start|>assistant\n"))
    }
    
    func testMemoryCheckLogic() {
        // Since we cannot easily mock ProcessInfo, we just verify the helper method exists and returns a valid identifier
        let recommended = LLMService.recommendedModel()
        XCTAssertEqual(recommended, .recommendedLocalLLM())
    }

    func testMemoryCheckLogic_fallsBackToLegacyOn8GBHardware() {
        let recommended = LLMService.recommendedModel(totalRAMBytes: 8_000_000_000)
        XCTAssertEqual(recommended, .qwen3_4B)
    }

    func testMemoryCheckLogic_prefersVisionOnSupportedHardware() {
        let recommended = LLMService.recommendedModel(totalRAMBytes: 16_000_000_000)
        XCTAssertEqual(recommended, .qwen35_4B_Vision)
    }

    func testRuntimeBackendSelection_textModelUsesMLXLLM() {
        let backend = LLMService.runtimeBackend(for: .qwen3_4B)
        XCTAssertEqual(backend, .mlxLLM)
    }

    func testRuntimeBackendSelection_visionModelUsesMLXVLM() {
        let backend = LLMService.runtimeBackend(for: .qwen35_4B_Vision)
        XCTAssertEqual(backend, .mlxVLM)
    }

    func testMemoryGating_visionModelRequires16GB() {
        XCTAssertFalse(
            LLMService.hasSufficientMemory(
                for: .qwen35_4B_Vision,
                totalRAMBytes: 15_000_000_000
            )
        )
        XCTAssertTrue(
            LLMService.hasSufficientMemory(
                for: .qwen35_4B_Vision,
                totalRAMBytes: 16_000_000_000
            )
        )
    }
    
    // MARK: - KV Cache Tests
    
    func testClearCacheDoesNotCrashWhenEmpty() async throws {
        let service = LLMService.shared
        
        // Calling clearCache when no cache exists should not crash
        await service.clearCache()
        // If we get here without crashing, test passes
    }
    
    func testClearCacheAfterUnload() async throws {
        let service = LLMService.shared
        
        // Unload clears the cache
        await service.unload()
        
        // Calling clearCache after unload should not crash
        await service.clearCache()
        // If we get here without crashing, test passes
    }

    func testGenerateUsesFreshCacheAndCompletePromptForEveryTurn() async throws {
        let runtime = RecordingLLMRuntime()
        let service = LLMService(runtime: runtime)
        let first = [LLMMessage(role: .system, content: "system one"), LLMMessage(role: .user, content: "first")]
        let second = first + [LLMMessage(role: .assistant, content: "reply"), LLMMessage(role: .user, content: "second")]

        for messages in [first, second] {
            let output = try await collect(await service.generate(messages: messages, maxTokens: 2))
            XCTAssertEqual(output, "ok")
            let hasLiveCache = await runtime.hasLiveCache
            XCTAssertFalse(hasLiveCache, "Completed request must release its cache")
        }
        try await assertIsolatedRequests(runtime, service: service, prompts: [first, second])
    }

    func testGenerateRetriesSamePromptAfterPartialPrefillErrorWithFreshCache() async throws {
        let runtime = RecordingLLMRuntime(failuresRemaining: 1)
        let service = LLMService(runtime: runtime)
        let messages = [LLMMessage(role: .system, content: "one"), LLMMessage(role: .user, content: "retry")]
        do {
            _ = try await collect(await service.generate(messages: messages, maxTokens: 2))
            XCTFail("Expected the injected failure after cache consumption")
        } catch LLMServiceError.generationFailed {
            // The next call must not append this full prompt to the failed prefill.
        }
        let hasLiveCache = await runtime.hasLiveCache
        XCTAssertFalse(hasLiveCache)
        _ = try await collect(await service.generate(messages: messages, maxTokens: 2))
        try await assertIsolatedRequests(runtime, service: service, prompts: [messages, messages])
    }

    func testGenerateTrimmedHistoryAndChangedSystemPromptUseFreshCache() async throws {
        let runtime = RecordingLLMRuntime()
        let service = LLMService(runtime: runtime)
        let first = [LLMMessage(role: .system, content: "one"), LLMMessage(role: .user, content: "old"),
                     LLMMessage(role: .assistant, content: "reply"), LLMMessage(role: .user, content: "recent")]
        let trimmed = [first[0], first[3]]
        let changedSystem = [LLMMessage(role: .system, content: "two"), first[3]]
        for messages in [first, trimmed, changedSystem] {
            _ = try await collect(await service.generate(messages: messages, maxTokens: 2))
        }
        try await assertIsolatedRequests(runtime, service: service, prompts: [first, trimmed, changedSystem])
    }

    func testConsumerCancellationStopsProducerAndNextRequestStartsFresh() async throws {
        let stopped = expectation(description: "Producer observes consumer cancellation")
        let received = expectation(description: "Consumer receives first chunk")
        let runtime = RecordingLLMRuntime(suspendFirst: true, firstRequestStopped: stopped)
        let service = LLMService(runtime: runtime)
        let first = [LLMMessage(role: .user, content: "cancel")]
        let stream = await service.generate(messages: first, maxTokens: 2)
        let consumer = Task {
            for try await delta in stream {
                if case .token = delta { received.fulfill() }
            }
        }
        await fulfillment(of: [received], timeout: 2)
        consumer.cancel()
        _ = await consumer.result
        await fulfillment(of: [stopped], timeout: 2)
        let next = [LLMMessage(role: .user, content: "next")]
        _ = try await collect(await service.generate(messages: next, maxTokens: 2))
        let observedCancellation = await runtime.observedCancellation
        XCTAssertTrue(observedCancellation)
        try await assertIsolatedRequests(runtime, service: service, prompts: [first, next])
    }

    func testGenerateNotReadyDoesNotAllocateCache() async throws {
        let runtime = RecordingLLMRuntime()
        let service = LLMService(runtime: runtime, isReady: false)
        do {
            _ = try await collect(await service.generate(messages: [], maxTokens: 2))
            XCTFail("Expected notReady")
        } catch LLMServiceError.notReady {}
        let records = await runtime.records
        let allocations = await runtime.allocations
        XCTAssertTrue(records.isEmpty)
        XCTAssertEqual(allocations, 0)
    }

    func testTextRuntimeRejectsImagesBeforeAllocatingCache() async throws {
        let runtime = RecordingLLMRuntime()
        let service = LLMService(runtime: runtime)
        let image = LLMImageAttachmentReference(stagedFilePath: "/unused.png", mimeType: "image/png")
        do {
            _ = try await collect(await service.generate(messages: [LLMMessage(role: .user, contentParts: [.image(image)])], maxTokens: 2))
            XCTFail("Text runtime must reject image attachments")
        } catch LLMServiceError.unsupportedInput {}
        let allocations = await runtime.allocations
        XCTAssertEqual(allocations, 0)
    }

    func testVLMRuntimeReceivesCompleteMessagesIncludingImageReferences() async throws {
        let runtime = RecordingLLMRuntime()
        let service = LLMService(runtime: runtime, backend: .mlxVLM)
        let image = LLMImageAttachmentReference(stagedFilePath: "/unused.png", mimeType: "image/png")
        let messages = [LLMMessage(role: .system, content: "describe"),
                        LLMMessage(role: .user, contentParts: [.text("image"), .image(image)])]
        _ = try await collect(await service.generate(messages: messages, maxTokens: 2))
        try await assertIsolatedRequests(runtime, service: service, prompts: [messages])
        let records = await runtime.records
        XCTAssertEqual(records.first?.request.runtimeBackend, .mlxVLM)
        XCTAssertEqual(records.first?.request.messages.last?.imageAttachments, [image])
    }

    func testVLMUserInputPreservesRolesTextAndStagedImageURL() throws {
        let imageURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        // Preparation passes a staged URL, not decoded pixels, to the processor.
        try Data().write(to: imageURL)
        defer { try? FileManager.default.removeItem(at: imageURL) }
        let image = LLMImageAttachmentReference(stagedFilePath: imageURL.path, mimeType: "image/png")
        let messages = [LLMMessage(role: .system, content: "system"),
                        LLMMessage(role: .user, contentParts: [.text("look"), .image(image)]),
                        LLMMessage(role: .assistant, content: "reply"), LLMMessage(role: .tool, content: "tool")]
        let input = try LLMService.makeVLMUserInput(from: messages)
        guard case .chat(let chat) = input.prompt else { return XCTFail("Expected structured VLM chat") }
        XCTAssertEqual(chat.map { $0.role.rawValue }, messages.map { $0.role.rawValue })
        XCTAssertEqual(chat.map(\.content), messages.map(\.textContent))
        XCTAssertEqual(chat.map { $0.images.count }, [0, 1, 0, 0])
        guard case .url(let stagedURL) = try XCTUnwrap(input.images.first) else { return XCTFail("Expected staged image URL") }
        XCTAssertEqual(stagedURL, imageURL)
    }

    func testVLMUserInputRejectsMissingStagedImage() throws {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        let image = LLMImageAttachmentReference(stagedFilePath: missing, mimeType: "image/png")
        XCTAssertThrowsError(try LLMService.makeVLMUserInput(from: [LLMMessage(role: .user, contentParts: [.image(image)])])) { error in
            guard case LLMServiceError.unsupportedInput = error else { return XCTFail("Unexpected error: \(error)") }
        }
    }

    private func assertIsolatedRequests(
        _ runtime: RecordingLLMRuntime,
        service: LLMService,
        prompts: [[LLMMessage]],
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let records = await runtime.records
        XCTAssertEqual(records.count, prompts.count, file: file, line: line)
        for (record, messages) in zip(records, prompts) {
            let expected = Array(await service.formatMessages(messages).utf8)
            XCTAssertEqual(record.request.messages, messages, file: file, line: line)
            XCTAssertEqual(record.request.chatMessages.compactMap { $0["role"] as? String }, messages.map { $0.role.rawValue }, file: file, line: line)
            XCTAssertEqual(record.request.chatMessages.compactMap { $0["content"] as? String }, messages.map(\.textContent), file: file, line: line)
            XCTAssertEqual(record.initialOffset, 0, file: file, line: line)
            XCTAssertEqual(record.consumedInput, expected, file: file, line: line)
            XCTAssertEqual(record.cacheInput, expected, "Cache must contain the complete input exactly once, not prior history", file: file, line: line)
            XCTAssertEqual(record.finalOffset, expected.count + 1, file: file, line: line)
            XCTAssertTrue(record.underMetalGate, file: file, line: line)
            XCTAssertEqual(record.maxTokens, 2, file: file, line: line)
        }
        XCTAssertEqual(Set(records.map(\.allocation)).count, prompts.count, file: file, line: line)
    }

    private func collect(_ stream: AsyncThrowingStream<LLMDelta, Error>) async throws -> String {
        var result = ""
        var completions = 0
        for try await delta in stream {
            switch delta {
            case .token(let token): result += token
            case .completed(let count):
                XCTAssertEqual(count, 1)
                completions += 1
            }
        }
        XCTAssertEqual(completions, 1, "Successful generation must complete exactly once")
        return result
    }
}

private struct RuntimeRecord: Sendable {
    let allocation: Int
    let initialOffset: Int
    let request: LLMPreparedRequest
    let consumedInput: [UInt8]
    let cacheInput: [UInt8]
    let finalOffset: Int
    let underMetalGate: Bool
    let maxTokens: Int
}

/// CPU-only cache using the pinned library's actual KVCache interface. Input
/// units are deterministic UTF-8 bytes, NOT claims about model tokenization.
private final class CountingKVCache: KVCache {
    let allocation: Int
    var input: [UInt8] = []
    var offset = 0
    var maxSize: Int? { nil }
    var state: [MLXArray] = []
    var metaState: [String] = []
    var isTrimmable: Bool { false }

    init(allocation: Int) {
        self.allocation = allocation
    }

    func consume(_ input: [UInt8]) {
        self.input += input
        self.offset += input.count + 1 // Full prefill plus one generated unit.
    }

    func innerState() -> [MLXArray] { [] }
    func trim(_ n: Int) -> Int { 0 }
    func copy() -> any KVCache {
        let result = CountingKVCache(allocation: self.allocation)
        result.input = self.input
        result.offset = self.offset
        return result
    }
    func makeMask(n: Int, windowSize: Int?, returnArray: Bool) -> MLXFast.ScaledDotProductAttentionMaskMode { .none }
    func update(keys: MLXArray, values: MLXArray) -> (MLXArray, MLXArray) {
        XCTFail("CPU-only runtime must not perform tensor operations")
        return (keys, values)
    }
}

private actor RecordingLLMRuntime: LLMGenerationRuntime {
    private(set) var records: [RuntimeRecord] = []
    private(set) var allocations = 0
    private(set) var observedCancellation = false
    private weak var lastCache: LLMRequestCache?
    var hasLiveCache: Bool { self.lastCache != nil }
    private var failuresRemaining: Int
    private let suspendFirst: Bool
    private let firstRequestStopped: XCTestExpectation?

    init(failuresRemaining: Int = 0, suspendFirst: Bool = false, firstRequestStopped: XCTestExpectation? = nil) {
        self.failuresRemaining = failuresRemaining
        self.suspendFirst = suspendFirst
        self.firstRequestStopped = firstRequestStopped
    }

    func makeCache(parameters: LLMGenerationParameters) async -> LLMRequestCache {
        self.allocations += 1
        return LLMRequestCache(storage: [CountingKVCache(allocation: self.allocations)])
    }

    func generate(
        request: LLMPreparedRequest,
        cache: LLMRequestCache,
        parameters: LLMGenerationParameters,
        emit: @escaping @Sendable (String) -> Bool,
        didReceiveFirstToken: @escaping @Sendable (Int) -> Void
    ) async throws -> Int {
        self.lastCache = cache
        let state = try XCTUnwrap(cache.storage.first as? CountingKVCache)
        let initialOffset = state.offset
        let input = Array(request.fallbackPrompt.utf8)
        state.consume(input)
        records.append(RuntimeRecord(
            allocation: state.allocation,
            initialOffset: initialOffset,
            request: request,
            consumedInput: input,
            cacheInput: state.input,
            finalOffset: state.offset,
            underMetalGate: await MLXMetalGate.shared.isAcquired,
            maxTokens: parameters.maxTokens
        ))
        if self.failuresRemaining > 0 {
            self.failuresRemaining -= 1
            throw LLMServiceError.generationFailed("test failure")
        }
        didReceiveFirstToken(input.count)
        guard emit("ok") else { return 1 }
        if self.suspendFirst && self.records.count == 1 {
            do {
                try await Task.sleep(for: .seconds(60))
                XCTFail("Consumer cancellation did not stop generation")
            } catch is CancellationError {
                self.observedCancellation = Task.isCancelled
                self.firstRequestStopped?.fulfill()
                throw CancellationError()
            }
        }
        return 1
    }
}

// MARK: - Model Integration Tests

final class LLMModelIntegrationTests: XCTestCase {
    func testGenerationCancellation() async throws {
        try IntegrationTestGate.requireModelTestsEnabled()
        let service = LLMService.shared
        let modelManager = ModelManager.shared
        await modelManager.refreshStatuses()
        let state = await modelManager.state
        let availableModel = [ModelIdentifier.qwen35_4B_Vision, .qwen3_4B, .qwen7B, .qwen3B].first { modelID in
            state.statuses[modelID]?.isReady == true
        }
        guard availableModel != nil else {
            throw XCTSkip("No LLM model downloaded. Skipping generation test.")
        }

        try await service.prepare()
        let messages = [LLMMessage(role: .user, content: "Count from 1 to 100 very slowly.")]
        let stream = await service.generate(messages: messages, maxTokens: 50)
        let counter = Counter()
        let task = Task {
            do {
                for try await _ in stream {
                    await counter.increment()
                    if await counter.count >= 1 {
                        try Task.checkCancellation()
                    }
                }
            } catch is CancellationError {
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
        }
        try? await Task.sleep(for: .milliseconds(100))
        task.cancel()
        let _ = await task.result
        let count = await counter.count
        XCTAssertLessThan(count, 50, "Generation should have stopped early due to cancellation")
        await service.unload()
    }

    func testStopTokenHandling() async throws {
        try IntegrationTestGate.requireModelTestsEnabled()
        let service = LLMService.shared
        let modelManager = ModelManager.shared
        await modelManager.refreshStatuses()
        let state = await modelManager.state
        let availableModel = [ModelIdentifier.qwen35_4B_Vision, .qwen3_4B, .qwen7B, .qwen3B].first { modelID in
            state.statuses[modelID]?.isReady == true
        }
        guard availableModel != nil else {
            throw XCTSkip("No LLM model downloaded. Skipping stop token test.")
        }

        try await service.prepare()
        let messages = [LLMMessage(role: .user, content: "Say 'Hello'")]
        var text = ""
        let stream = await service.generate(messages: messages, maxTokens: 10)
        for try await delta in stream {
            if case .token(let t) = delta { text += t }
        }
        XCTAssertFalse(text.isEmpty)
        await service.unload()
    }

    func testRequestLocalGenerationAcrossConversationTurns() async throws {
        try IntegrationTestGate.requireModelTestsEnabled()
        let service = LLMService.shared
        let modelManager = ModelManager.shared
        await modelManager.refreshStatuses()
        let state = await modelManager.state
        guard state.statuses[.qwen35_4B_Vision]?.isReady == true else {
            throw XCTSkip("Qwen3 VL 4B not downloaded")
        }

        try await service.prepare()
        let messages1 = [LLMMessage(role: .user, content: "Hello")]
        var text1 = ""
        let stream1 = await service.generate(messages: messages1, maxTokens: 10)
        for try await delta in stream1 {
            if case .token(let t) = delta { text1 += t }
        }
        XCTAssertFalse(text1.isEmpty, "First generation should produce output")
        let messages2 = [
            LLMMessage(role: .user, content: "Hello"),
            LLMMessage(role: .assistant, content: text1),
            LLMMessage(role: .user, content: "How are you?")
        ]
        var text2 = ""
        let stream2 = await service.generate(messages: messages2, maxTokens: 10)
        for try await delta in stream2 {
            if case .token(let t) = delta { text2 += t }
        }
        XCTAssertFalse(text2.isEmpty, "Second generation should produce output")
        await service.clearCache()
        await service.unload()
    }

    func testCacheClearedOnUnload() async throws {
        try IntegrationTestGate.requireModelTestsEnabled()
        let service = LLMService.shared
        let modelManager = ModelManager.shared
        await modelManager.refreshStatuses()
        let state = await modelManager.state
        guard state.statuses[.qwen35_4B_Vision]?.isReady == true else {
            throw XCTSkip("Qwen3 VL 4B not downloaded")
        }

        try await service.prepare()
        let stream = await service.generate(
            messages: [LLMMessage(role: .user, content: "Hi")],
            maxTokens: 5
        )
        for try await _ in stream {}
        await service.unload()
        try await service.prepare()
        let stream2 = await service.generate(
            messages: [LLMMessage(role: .user, content: "Hello again")],
            maxTokens: 5
        )
        for try await _ in stream2 {}
        await service.unload()
    }
}

// Helper actor for thread-safe counting
private actor Counter {
    var count = 0
    func increment() { count += 1 }
}
