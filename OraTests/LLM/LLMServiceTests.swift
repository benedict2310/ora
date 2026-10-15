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

    func testPrepareCoalescesConcurrentCallersOntoOneLoader() async throws {
        let loader = PreparationLoader()
        let runtime = RecordingLLMRuntime()
        let joined = expectation(description: "Second caller joins the suspended load")
        let recorder = PreparationEventRecorder()
        let service = LLMService(modelLoader: { _ in
            await loader.started()
            await loader.waitUntilReleased()
            return LLMPreparedModel(runtime: runtime, backend: .mlxLLM)
        }, preparationObserver: {
            recorder.record($0)
            if $0.phase == .joined { joined.fulfill() }
        })

        let first = Task { try await service.prepare() }
        await loader.waitUntilStarted()
        let second = Task { try await service.prepare() }
        await fulfillment(of: [joined], timeout: 2)
        let initialLoadCount = await loader.loadCount
        XCTAssertEqual(initialLoadCount, 1)
        await loader.release()
        try await first.value
        try await second.value
        let finalLoadCount = await loader.loadCount
        XCTAssertEqual(finalLoadCount, 1)
        let completions = recorder.events().filter { $0.phase == .completed }
        XCTAssertEqual(completions.filter(\.joined).count, 1, "Wait duration must remain distinguishable from load duration")
        XCTAssertEqual(completions.filter { !$0.joined }.count, 1)
    }

    func testPrepareCoalescesAcrossSuspendedModelSource() async throws {
        let source = SuspendedPreparationSource()
        let loader = RetryPreparationLoader()
        let runtime = RecordingLLMRuntime()
        let service = LLMService(modelLoader: { _ in
            await loader.succeed()
            return LLMPreparedModel(runtime: runtime, backend: .mlxLLM)
        }, modelSource: { await source.read() })
        let first = Task { try await service.prepare() }
        let second = Task { try await service.prepare() }
        await source.waitForTwoReaders()
        await source.releaseReaders()
        try await first.value
        try await second.value
        let count = await loader.loadCount
        XCTAssertEqual(count, 1, "Source suspension must not open a duplicate-load window")
        try await service.prepare()
        let readyCount = await loader.loadCount
        XCTAssertEqual(readyCount, 1)
    }

    func testPrepareDoesNotJoinFlightForPreviousModel() async throws {
        let source = MutablePreparationSource()
        let loader = PreparationLoader()
        let runtime = RecordingLLMRuntime()
        let service = LLMService(modelLoader: { model in
            await loader.started()
            if model == .qwen3_4B { await loader.waitUntilReleased() }
            return LLMPreparedModel(runtime: runtime, backend: .mlxLLM)
        }, modelSource: { await source.read() })
        let first = Task { try await service.prepare() }
        await loader.waitUntilStarted()
        await source.select(.qwen35_4B_Vision)
        let secondFinished = expectation(description: "New model prepares without waiting for old model")
        let second = Task {
            defer { secondFinished.fulfill() }
            try await service.prepare()
        }
        await fulfillment(of: [secondFinished], timeout: 2)
        // Let A finish: an obsolete flight must not satisfy B's preparation.
        await loader.release()
        do {
            try await first.value
            XCTFail("Old model must not publish")
        } catch LLMServiceError.preparationInvalidated {}
        do {
            try await second.value
        } catch {
            XCTFail("New model must prepare independently: \(error)")
        }
        let count = await loader.loadCount
        XCTAssertEqual(count, 2)
    }

    func testCancelledWaiterDoesNotCancelSharedPreparation() async throws {
        let loader = PreparationLoader()
        let runtime = RecordingLLMRuntime()
        let joined = expectation(description: "Foreground joined before cancellation")
        let service = LLMService(modelLoader: { _ in
            await loader.started()
            await loader.waitUntilReleased()
            return LLMPreparedModel(runtime: runtime, backend: .mlxLLM)
        }, preparationObserver: { if $0.phase == .joined { joined.fulfill() } })
        let early = Task { try await service.prepare() }
        await loader.waitUntilStarted()
        let foreground = Task { try await service.prepare() }
        await fulfillment(of: [joined], timeout: 2)
        early.cancel()
        await loader.release()
        try await foreground.value
        _ = try? await early.value
        let count = await loader.loadCount
        XCTAssertEqual(count, 1)
    }

    func testPrepareFailureDoesNotPoisonRetry() async throws {
        let loader = RetryPreparationLoader()
        let runtime = RecordingLLMRuntime()
        let service = LLMService(modelLoader: { _ in
            try await loader.load()
            return LLMPreparedModel(runtime: runtime, backend: .mlxLLM)
        })

        do {
            try await service.prepare()
            XCTFail("Expected first preparation to fail")
        } catch LLMServiceError.generationFailed(let reason) {
            XCTAssertEqual(reason, "injected")
        }
        try await service.prepare()
        let loadCount = await loader.loadCount
        XCTAssertEqual(loadCount, 2)
    }

    func testPrepareInvalidationDoesNotPublishStaleReadiness() async throws {
        let loader = PreparationLoader()
        let runtime = RecordingLLMRuntime()
        let service = LLMService(modelLoader: { _ in
            await loader.started()
            await loader.waitUntilReleased()
            return LLMPreparedModel(runtime: runtime, backend: .mlxLLM)
        })

        let pending = Task { try await service.prepare() }
        await loader.waitUntilStarted()
        await service.unload()
        await loader.release()
        do {
            try await pending.value
            XCTFail("Expected invalidated preparation")
        } catch LLMServiceError.preparationInvalidated {}
        let retry = Task { try await service.prepare() }
        await loader.release()
        try await retry.value
        let loadCount = await loader.loadCount
        XCTAssertEqual(loadCount, 2)
    }

    func testUnloadDuringEligibilityCallbackPreventsLateServiceEntry() async throws {
        let checking = PreparationTestSignal()
        let release = PreparationTestSignal()
        let loader = PreparationTestLoader(suspendFirst: false)
        let service = LLMService(modelLoader: { try await loader.load($0) })
        let pending = Task {
            try await service.prepareIfEligible {
                await checking.signal()
                await release.wait()
                return true
            }
        }
        await checking.wait()
        await service.unload()
        await release.signal()
        do { try await pending.value; XCTFail("Eligibility callback predates unload") }
        catch LLMServiceError.preparationInvalidated {}
        let count = await loader.count
        XCTAssertEqual(count, 0)
    }

    func testUnloadDuringModelSourceSuspensionPreventsLoadInstallation() async throws {
        let sourceStarted = PreparationTestSignal()
        let releaseSource = PreparationTestSignal()
        let loader = PreparationTestLoader(suspendFirst: false)
        let service = LLMService(modelLoader: { try await loader.load($0) }, modelSource: {
            await sourceStarted.signal()
            await releaseSource.wait()
            return .qwen3_4B
        })
        let pending = Task { try await service.prepare() }
        await sourceStarted.wait()
        await service.unload()
        await releaseSource.signal()
        do { try await pending.value; XCTFail("Source snapshot predates unload") }
        catch LLMServiceError.preparationInvalidated {}
        let count = await loader.count
        XCTAssertEqual(count, 0)
    }

    func testReadyModelChangeRetiresAndPreparesNewModel() async throws {
        let source = MutablePreparationSource()
        let runtimeA = PreparationTestRuntime()
        let runtimeB = PreparationTestRuntime()
        let service = LLMService(modelLoader: { model in
            LLMPreparedModel(runtime: model == .qwen3_4B ? runtimeA : runtimeB, backend: .mlxLLM)
        }, modelSource: { await source.read() })
        try await service.prepare()
        await source.select(.qwen35_4B_Vision)
        try await service.prepare()
        _ = try await self.collect(await service.generate(messages: [], maxTokens: 1))
        let cleanupA = await runtimeA.cleanupUnderGate
        let generatedB = await runtimeB.generationCount
        XCTAssertEqual(cleanupA, [true])
        XCTAssertEqual(generatedB, 1)
    }

    func testStaleSuccessCannotReplaceNewerRuntimeBundle() async throws {
        let source = MutablePreparationSource()
        let startedA = PreparationTestSignal()
        let releaseA = PreparationTestSignal()
        let runtimeA = PreparationTestRuntime()
        let runtimeB = PreparationTestRuntime()
        let service = LLMService(modelLoader: { model in
            if model == .qwen3_4B {
                await startedA.signal()
                await releaseA.wait()
                return LLMPreparedModel(runtime: runtimeA, backend: .mlxLLM)
            }
            return LLMPreparedModel(runtime: runtimeB, backend: .mlxVLM)
        }, modelSource: { await source.read() })
        let first = Task { try await service.prepare() }
        await startedA.wait()
        await source.select(.qwen35_4B_Vision)
        try await service.prepare()
        await releaseA.signal()
        do { try await first.value; XCTFail("Stale bundle must be retired") }
        catch LLMServiceError.preparationInvalidated {}
        _ = try await self.collect(await service.generate(messages: [], maxTokens: 1))
        let generatedA = await runtimeA.generationCount
        let generatedB = await runtimeB.generationCount
        let retiredA = await runtimeA.cleanupUnderGate
        XCTAssertEqual(generatedA, 0)
        XCTAssertEqual(generatedB, 1)
        XCTAssertEqual(retiredA, [true])
    }

    func testStaleFailureCannotClearNewerFlightInSameLifecycle() async throws {
        let source = MutablePreparationSource()
        let startedA = PreparationTestSignal()
        let startedB = PreparationTestSignal()
        let releaseA = PreparationTestSignal()
        let releaseB = PreparationTestSignal()
        let runtime = PreparationTestRuntime()
        let joined = expectation(description: "Third caller joins B rather than loading again")
        let service = LLMService(modelLoader: { model in
            if model == .qwen3_4B {
                await startedA.signal()
                await releaseA.wait()
                throw LLMServiceError.modelNotFound
            }
            await startedB.signal()
            await releaseB.wait()
            return LLMPreparedModel(runtime: runtime, backend: .mlxVLM)
        }, modelSource: { await source.read() }, preparationObserver: {
            if $0.phase == .joined { joined.fulfill() }
        })
        let first = Task { try await service.prepare() }
        await startedA.wait()
        await source.select(.qwen35_4B_Vision)
        let second = Task { try await service.prepare() }
        await startedB.wait()
        await releaseA.signal()
        do { try await first.value; XCTFail("Expected injected failure") }
        catch LLMServiceError.modelNotFound {}
        let third = Task { try await service.prepare() }
        await fulfillment(of: [joined], timeout: 2)
        await releaseB.signal()
        try await second.value
        try await third.value
    }

    func testUnloadRetiresUnderGateWithoutClearingNewPublicationAfterAwait() async throws {
        let cleanupStarted = PreparationTestSignal()
        let finishCleanup = PreparationTestSignal()
        let runtimeA = PreparationTestRuntime(cleanupStarted: cleanupStarted, finishCleanup: finishCleanup)
        let runtimeB = PreparationTestRuntime()
        let source = MutablePreparationSource()
        let service = LLMService(modelLoader: { model in
            LLMPreparedModel(runtime: model == .qwen3_4B ? runtimeA : runtimeB, backend: .mlxLLM)
        }, modelSource: { await source.read() })
        try await service.prepare()
        let unloading = Task { await service.unload() }
        await cleanupStarted.wait()
        await source.select(.qwen35_4B_Vision)
        try await service.prepare()
        await finishCleanup.signal()
        await unloading.value
        _ = try await self.collect(await service.generate(messages: [], maxTokens: 1))
        let generatedB = await runtimeB.generationCount
        let cleanup = await runtimeA.cleanupUnderGate
        XCTAssertEqual(generatedB, 1)
        XCTAssertEqual(cleanup, [true])
    }

    func testPreparationEventsUseInjectedClockAndStableFlightIdentity() async throws {
        let recorder = PreparationEventRecorder()
        let runtime = PreparationTestRuntime()
        let service = LLMService(modelLoader: { _ in
            recorder.setTime(11)
            return LLMPreparedModel(runtime: runtime, backend: .mlxLLM)
        }, monotonicNow: { recorder.now() }, preparationObserver: { recorder.record($0) })
        try await service.prepare()
        let events = recorder.events()
        XCTAssertEqual(events.map(\.phase), [.requested, .completed])
        XCTAssertEqual(events.map(\.durationMilliseconds), [0, 1000])
        XCTAssertEqual(events.map(\.joined), [false, false])
        XCTAssertEqual(Set(events.map(\.flightID)).count, 1)
        XCTAssertEqual(events.map(\.model), [.qwen3_4B, .qwen3_4B])
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
        } catch LLMServiceError.generationFailed(let reason) {
            XCTAssertEqual(reason, "test failure", "Cleanup must not replace the original error")
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
        let cleanups = await runtime.cleanups
        XCTAssertEqual(cleanups.map(\.taskWasCancelled), [true, false], "Consumer cancellation must still run cleanup")
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
        let cleanups = await runtime.cleanups
        XCTAssertTrue(cleanups.isEmpty, "No GPU cleanup before a runtime request starts")
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
        let cleanups = await runtime.cleanups
        XCTAssertTrue(cleanups.isEmpty)
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
        let cleanups = await runtime.cleanups
        XCTAssertEqual(cleanups.count, prompts.count, "Every runtime request must clean up exactly once", file: file, line: line)
        for cleanup in cleanups {
            XCTAssertTrue(cleanup.underMetalGate, "GPU cleanup must precede gate release", file: file, line: line)
            XCTAssertTrue(cleanup.requestCacheReleased, "Request cache wrapper must be released before cleanup", file: file, line: line)
            XCTAssertTrue(cleanup.kvCacheReleased, "Actual KV state must be released before cleanup", file: file, line: line)
        }
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

private struct RuntimeCleanupRecord: Sendable {
    let underMetalGate: Bool
    let requestCacheReleased: Bool
    let kvCacheReleased: Bool
    let taskWasCancelled: Bool
}

private actor RecordingLLMRuntime: LLMGenerationRuntime {
    private(set) var records: [RuntimeRecord] = []
    private(set) var cleanups: [RuntimeCleanupRecord] = []
    private(set) var allocations = 0
    private(set) var observedCancellation = false
    private weak var lastCache: LLMRequestCache?
    private weak var lastKVCache: CountingKVCache?
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

    func cleanup() async {
        self.cleanups.append(RuntimeCleanupRecord(
            underMetalGate: await MLXMetalGate.shared.isAcquired,
            requestCacheReleased: self.lastCache == nil,
            kvCacheReleased: self.lastKVCache == nil,
            taskWasCancelled: Task.isCancelled
        ))
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
        self.lastKVCache = state
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

private actor PreparationLoader {
    private(set) var loadCount = 0
    private var startedContinuation: CheckedContinuation<Void, Never>?
    private var releaseContinuations: [CheckedContinuation<Void, Never>] = []
    private var released = false

    func started() {
        loadCount += 1
        startedContinuation?.resume()
        startedContinuation = nil
    }

    func waitUntilStarted() async {
        guard loadCount == 0 else { return }
        await withCheckedContinuation { continuation in
            startedContinuation = continuation
        }
    }

    func waitUntilReleased() async {
        guard !released else { return }
        await withCheckedContinuation { continuation in
            releaseContinuations.append(continuation)
        }
    }

    func release() {
        released = true
        let continuations = releaseContinuations
        releaseContinuations.removeAll()
        continuations.forEach { $0.resume() }
    }
}

private actor RetryPreparationLoader {
    private(set) var loadCount = 0

    func succeed() { loadCount += 1 }

    func load() throws {
        loadCount += 1
        if loadCount == 1 {
            throw LLMServiceError.generationFailed("injected")
        }
    }
}

private final class PreparationEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var time: Double = 10
    private var recorded: [LLMPreparationEvent] = []
    func now() -> Double { self.lock.withLock { self.time } }
    func setTime(_ time: Double) { self.lock.withLock { self.time = time } }
    func record(_ event: LLMPreparationEvent) { self.lock.withLock { self.recorded.append(event) } }
    func events() -> [LLMPreparationEvent] { self.lock.withLock { self.recorded } }
}

private actor MutablePreparationSource {
    private var model: ModelIdentifier = .qwen3_4B
    func read() -> ModelIdentifier { model }
    func select(_ model: ModelIdentifier) { self.model = model }
}

private actor SuspendedPreparationSource {
    private var readers: [CheckedContinuation<ModelIdentifier, Never>] = []
    private var observer: CheckedContinuation<Void, Never>?
    private var released = false

    func read() async -> ModelIdentifier {
        guard !released else { return .qwen3_4B }
        return await withCheckedContinuation { continuation in
            readers.append(continuation)
            if readers.count == 2 { observer?.resume(); observer = nil }
        }
    }
    func waitForTwoReaders() async {
        guard readers.count < 2 else { return }
        await withCheckedContinuation { observer = $0 }
    }
    func releaseReaders() {
        released = true
        readers.forEach { $0.resume(returning: .qwen3_4B) }
        readers.removeAll()
    }
}

// Helper actor for thread-safe counting
private actor Counter {
    var count = 0
    func increment() { count += 1 }
}
