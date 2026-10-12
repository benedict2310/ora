//
//  LLMServiceTests.swift
//  OraTests
//
//  Tests for LLMService logic
//

import XCTest
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

    func testKVCacheReuse() async throws {
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
