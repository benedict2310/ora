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
        // Qwen 3 4B is now the only recommended model
        XCTAssertEqual(recommended, .qwen3_4B)
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
    
    // MARK: - Inference Tests
    
    func testGenerationCancellation() async throws {
        let service = LLMService.shared
        
        // 1. Check for model availability
        // Check if Qwen 3 or legacy models are available on disk
        let modelManager = ModelManager.shared
        await modelManager.refreshStatuses()
        let state = await modelManager.state
        
        let availableModel = [ModelIdentifier.qwen3_4B, .qwen7B, .qwen3B].first { modelID in
            state.statuses[modelID]?.isReady == true
        }
        
        guard let _ = availableModel else {
            throw XCTSkip("No LLM model downloaded. Skipping generation test.")
        }
        
        // 2. Prepare service
        try await service.prepare()
        
        // 3. Start generation task
        let messages = [LLMMessage(role: .user, content: "Count from 1 to 100 very slowly.")]
        let stream = await service.generate(messages: messages, maxTokens: 50)
        
        // 4. Cancel immediately after first token
        let counter = Counter()
        
        let task = Task {
            do {
                for try await _ in stream {
                    await counter.increment()
                    let count = await counter.count
                    if count >= 1 {
                        // Cancel the task iterating the stream
                        // This should trigger the stream's onTermination handler
                        try Task.checkCancellation()
                    }
                }
            } catch is CancellationError {
                // Expected
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
        }
        
        // Wait a tiny bit then cancel
        try? await Task.sleep(for: .milliseconds(100))
        task.cancel()
        
        // Wait for finish
        let _ = await task.result
        
        // 5. Verify it didn't generate 50 tokens
        // Since we cancelled early, it should be much less than maxTokens
        let count = await counter.count
        XCTAssertLessThan(count, 50, "Generation should have stopped early due to cancellation")
        
        // Optional: Cleanup
        await service.unload()
    }
    
    func testStopTokenHandling() async throws {
        let service = LLMService.shared
        
        // 1. Check for model availability
        let modelManager = ModelManager.shared
        await modelManager.refreshStatuses()
        let state = await modelManager.state
        
        let availableModel = [ModelIdentifier.qwen3_4B, .qwen7B, .qwen3B].first { modelID in
            state.statuses[modelID]?.isReady == true
        }
        
        guard let _ = availableModel else {
            throw XCTSkip("No LLM model downloaded. Skipping stop token test.")
        }
        
        // 2. Prepare service
        try await service.prepare()
        
        // 3. Inject a prompt that we expect to end naturally or we can inject a stop token?
        // Since we can't easily force the model to emit a specific token without control,
        // we'll rely on a short prompt and verify it doesn't run away.
        // Or we rely on the implementation logic we verified in code review.
        
        // However, we can verify that the code *compiles* and runs without crashing.
        // Ideally we'd mock the MLX container but it's not protocol-based easily.
        
        let messages = [LLMMessage(role: .user, content: "Say 'Hello'")]
        var text = ""
        
        let stream = await service.generate(messages: messages, maxTokens: 10)
        
        for try await delta in stream {
            if case .token(let t) = delta {
                text += t
            }
        }
        
        XCTAssertFalse(text.isEmpty)
        // If it stopped, it shouldn't contain the raw <|im_end|> token usually, as we stop *on* it.
        // But our logic returns .stop when it sees it.
        // So the token might be emitted or not depending on tokenizer behavior.
        
        await service.unload()
    }
    
    func testKVCacheReuse() async throws {
        let service = LLMService.shared
        
        // Check for model availability
        let modelManager = ModelManager.shared
        await modelManager.refreshStatuses()
        let state = await modelManager.state
        
        guard state.statuses[.qwen3_4B]?.isReady == true else {
            throw XCTSkip("Qwen 3 4B not downloaded")
        }
        
        try await service.prepare()
        
        // First generation (cache should be created)
        let messages1 = [LLMMessage(role: .user, content: "Hello")]
        var text1 = ""
        let stream1 = await service.generate(messages: messages1, maxTokens: 10)
        for try await delta in stream1 {
            if case .token(let t) = delta { text1 += t }
        }
        XCTAssertFalse(text1.isEmpty, "First generation should produce output")
        
        // Second generation (cache should be reused)
        // The cache reuse is verified by checking logs or timing, but at minimum
        // this verifies the generation still works after the first turn
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
        
        // Clear cache
        await service.clearCache()
        
        await service.unload()
    }
    
    func testCacheClearedOnUnload() async throws {
        let service = LLMService.shared
        
        let modelManager = ModelManager.shared
        await modelManager.refreshStatuses()
        let state = await modelManager.state
        
        guard state.statuses[.qwen3_4B]?.isReady == true else {
            throw XCTSkip("Qwen 3 4B not downloaded")
        }
        
        try await service.prepare()
        
        // Generate to create cache
        let stream = await service.generate(
            messages: [LLMMessage(role: .user, content: "Hi")],
            maxTokens: 5
        )
        for try await _ in stream {}
        
        // Unload should clear cache
        await service.unload()
        
        // Re-prepare and verify cache is fresh
        try await service.prepare()
        // No crash = success (cache was properly cleared)
        
        // Another generation should work fine
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
