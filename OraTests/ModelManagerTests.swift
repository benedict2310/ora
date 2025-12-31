//
//  ModelManagerTests.swift
//  OraTests
//
//  Unit tests for ModelManager
//

import XCTest
@testable import Ora

final class ModelManagerTests: XCTestCase {

    // MARK: - Model Types Tests

    func test_modelIdentifier_categoryMapping() {
        XCTAssertEqual(ModelIdentifier.parakeetTDT.category, .asr)
        XCTAssertEqual(ModelIdentifier.qwen7B.category, .llm)
        XCTAssertEqual(ModelIdentifier.qwen3B.category, .llm)
        XCTAssertEqual(ModelIdentifier.kokoro.category, .tts)
    }

    func test_modelIdentifier_displayName() {
        XCTAssertEqual(ModelIdentifier.parakeetTDT.displayName, "Parakeet TDT 0.6B")
        XCTAssertEqual(ModelIdentifier.qwen7B.displayName, "Qwen 2.5 7B")
        XCTAssertEqual(ModelIdentifier.qwen3B.displayName, "Qwen 2.5 3B")
        XCTAssertEqual(ModelIdentifier.kokoro.displayName, "Kokoro TTS")
    }

    func test_modelIdentifier_storagePath() {
        XCTAssertEqual(ModelIdentifier.parakeetTDT.storagePath, "asr/parakeet-tdt-0.6b-v3-coreml")
        XCTAssertEqual(ModelIdentifier.qwen7B.storagePath, "llm/qwen2.5-7b-instruct-4bit")
        XCTAssertEqual(ModelIdentifier.qwen3B.storagePath, "llm/qwen2.5-3b-instruct-4bit")
        XCTAssertEqual(ModelIdentifier.kokoro.storagePath, "tts/kokoro")
    }

    func test_modelIdentifier_requiredFiles() {
        // ASR requires Core ML model files (matching FluidAudio's capitalized names)
        XCTAssertTrue(ModelIdentifier.parakeetTDT.requiredFiles.contains("Encoder.mlmodelc"))
        XCTAssertTrue(ModelIdentifier.parakeetTDT.requiredFiles.contains("parakeet_vocab.json"))

        // LLM requires config, tokenizer, and weights
        XCTAssertTrue(ModelIdentifier.qwen7B.requiredFiles.contains("config.json"))
        XCTAssertTrue(ModelIdentifier.qwen7B.requiredFiles.contains("tokenizer.json"))
        XCTAssertTrue(ModelIdentifier.qwen7B.requiredFiles.contains("model.safetensors"))

        // TTS requires config and weights
        XCTAssertTrue(ModelIdentifier.kokoro.requiredFiles.contains("config.json"))
        XCTAssertTrue(ModelIdentifier.kokoro.requiredFiles.contains("kokoro-v1_0.safetensors"))
    }

    // MARK: - Model Paths Tests

    func test_modelPaths_path_containsStoragePath() {
        let asrPath = ModelPaths.path(for: .parakeetTDT)
        XCTAssertTrue(asrPath.path.contains("Ora/Models/asr/parakeet-tdt-0.6b-v3-coreml"))

        let llmPath = ModelPaths.path(for: .qwen7B)
        XCTAssertTrue(llmPath.path.contains("Ora/Models/llm/qwen2.5-7b-instruct-4bit"))

        let ttsPath = ModelPaths.path(for: .kokoro)
        XCTAssertTrue(ttsPath.path.contains("Ora/Models/tts/kokoro"))
    }

    func test_modelPaths_metadataFile_isJSON() {
        let metadataPath = ModelPaths.metadataFile
        XCTAssertTrue(metadataPath.path.hasSuffix("model-metadata.json"))
    }

    // MARK: - Models State Tests

    func test_modelsState_requiredModelsReady_allReady() {
        var state = ModelsState()
        state.statuses[.parakeetTDT] = .ready
        state.statuses[.qwen7B] = .ready
        state.statuses[.kokoro] = .ready
        state.primaryLLM = .qwen7B

        XCTAssertTrue(state.requiredModelsReady)
    }

    func test_modelsState_requiredModelsReady_missingASR() {
        var state = ModelsState()
        state.statuses[.parakeetTDT] = .notDownloaded
        state.statuses[.qwen7B] = .ready
        state.statuses[.kokoro] = .ready
        state.primaryLLM = .qwen7B

        XCTAssertFalse(state.requiredModelsReady)
    }

    func test_modelsState_requiredModelsReady_missingTTS() {
        var state = ModelsState()
        state.statuses[.parakeetTDT] = .ready
        state.statuses[.qwen7B] = .ready
        state.statuses[.kokoro] = .notDownloaded
        state.primaryLLM = .qwen7B

        XCTAssertFalse(state.requiredModelsReady)
    }

    func test_modelsState_requiredModelsReady_missingLLM() {
        var state = ModelsState()
        state.statuses[.parakeetTDT] = .ready
        state.statuses[.qwen7B] = .notDownloaded
        state.statuses[.kokoro] = .ready
        state.primaryLLM = .qwen7B

        XCTAssertFalse(state.requiredModelsReady)
    }

    func test_modelsState_overallProgress_noProgress() {
        var state = ModelsState()
        state.primaryLLM = .qwen7B

        XCTAssertEqual(state.overallProgress, 0.0, accuracy: 0.01)
    }

    func test_modelsState_overallProgress_allReady() {
        var state = ModelsState()
        state.statuses[.parakeetTDT] = .ready
        state.statuses[.qwen7B] = .ready
        state.statuses[.kokoro] = .ready
        state.primaryLLM = .qwen7B

        XCTAssertEqual(state.overallProgress, 1.0, accuracy: 0.01)
    }

    func test_modelsState_overallProgress_partialDownload() {
        var state = ModelsState()
        state.statuses[.parakeetTDT] = .downloading(progress: 0.5)
        state.statuses[.qwen7B] = .downloading(progress: 0.5)
        state.statuses[.kokoro] = .downloading(progress: 0.5)
        state.primaryLLM = .qwen7B

        XCTAssertEqual(state.overallProgress, 0.5, accuracy: 0.01)
    }

    func test_modelsState_subscript() {
        var state = ModelsState()
        state.statuses[.parakeetTDT] = .ready

        XCTAssertEqual(state[.parakeetTDT], .ready)
        XCTAssertEqual(state[.kokoro], .notDownloaded) // Default for missing
    }

    // MARK: - Model Status Tests

    func test_modelStatus_isReady() {
        XCTAssertTrue(ModelStatus.ready.isReady)
        XCTAssertFalse(ModelStatus.notDownloaded.isReady)
        XCTAssertFalse(ModelStatus.downloading(progress: 0.5).isReady)
    }

    func test_modelStatus_isDownloading() {
        XCTAssertTrue(ModelStatus.downloading(progress: 0.5).isDownloading)
        XCTAssertFalse(ModelStatus.ready.isDownloading)
        XCTAssertFalse(ModelStatus.notDownloaded.isDownloading)
    }

    func test_modelStatus_progress() {
        XCTAssertEqual(ModelStatus.downloading(progress: 0.75).progress, 0.75)
        XCTAssertNil(ModelStatus.ready.progress)
        XCTAssertNil(ModelStatus.notDownloaded.progress)
    }

    // MARK: - Download Progress Tests

    func test_downloadProgress_progressPercent() {
        let progress = ModelDownloadProgress(
            identifier: .qwen7B,
            bytesDownloaded: 500_000_000,
            totalBytes: 1_000_000_000
        )

        XCTAssertEqual(progress.progressPercent, 50)
    }

    func test_downloadProgress_initFromPercentage() {
        let progress = ModelDownloadProgress(identifier: .kokoro, progress: 0.75)

        XCTAssertEqual(progress.progressPercent, 75)
        XCTAssertEqual(progress.progress, 0.75)
    }

    func test_overallDownloadProgress_calculate() {
        var progressMap: [ModelIdentifier: ModelDownloadProgress] = [:]
        progressMap[.parakeetTDT] = ModelDownloadProgress(identifier: .parakeetTDT, progress: 1.0)
        progressMap[.qwen7B] = ModelDownloadProgress(identifier: .qwen7B, progress: 0.5)
        progressMap[.kokoro] = ModelDownloadProgress(identifier: .kokoro, progress: 0.0)

        let overall = OverallDownloadProgress.calculate(
            from: progressMap,
            models: [.parakeetTDT, .qwen7B, .kokoro]
        )

        // Progress should be weighted by estimated size
        XCTAssertGreaterThan(overall.overallProgress, 0)
        XCTAssertLessThan(overall.overallProgress, 1.0)
    }

    // MARK: - Model Manager Tests with Mock

    func test_modelManager_recommendedLLM_basedOnRAM() async {
        let manager = ModelManager(downloader: MockModelDownloader())

        let recommended = await manager.recommendedLLM()

        // On any modern Mac, we should get either 7B or 3B
        XCTAssertTrue(recommended == .qwen7B || recommended == .qwen3B)
    }

    func test_modelManager_refreshStatuses_updatesState() async {
        let mock = MockModelDownloader()
        mock.existingModels = [.parakeetTDT]

        let manager = ModelManager(downloader: mock)

        await manager.refreshStatuses()
        let state = await manager.state

        XCTAssertEqual(state.statuses[.parakeetTDT], .ready)
        XCTAssertEqual(state.statuses[.qwen7B], .notDownloaded)
    }

    func test_modelManager_downloadModel_success() async throws {
        let mock = MockModelDownloader()
        mock.shouldSucceed = true
        mock.downloadDelay = 0.01 // Fast for tests

        let manager = ModelManager(downloader: mock)

        try await manager.downloadModel(.kokoro)

        let state = await manager.state
        XCTAssertEqual(state.statuses[.kokoro], .ready)
        XCTAssertTrue(mock.downloadedModels.contains(.kokoro))
    }

    func test_modelManager_downloadModel_failure() async {
        let mock = MockModelDownloader()
        mock.shouldSucceed = false

        let manager = ModelManager(downloader: mock)

        do {
            try await manager.downloadModel(.kokoro)
            XCTFail("Expected download to fail")
        } catch {
            let state = await manager.state
            if case .failed = state.statuses[.kokoro] {
                // Expected
            } else {
                XCTFail("Expected failed status")
            }
        }
    }

    func test_modelManager_setPrimaryLLM() async {
        let manager = ModelManager(downloader: MockModelDownloader())

        await manager.setPrimaryLLM(.qwen3B)

        let state = await manager.state
        XCTAssertEqual(state.primaryLLM, .qwen3B)
    }

    func test_modelManager_setPrimaryLLM_ignoresNonLLM() async {
        let manager = ModelManager(downloader: MockModelDownloader())

        await manager.setPrimaryLLM(.parakeetTDT) // This should be ignored

        let state = await manager.state
        XCTAssertEqual(state.primaryLLM, .qwen7B) // Should remain default
    }

    func test_modelManager_requiredModelsAvailable_false() async {
        let manager = ModelManager(downloader: MockModelDownloader())

        let available = await manager.requiredModelsAvailable()

        XCTAssertFalse(available)
    }

    func test_modelManager_requiredModelsAvailable_true() async {
        let mock = MockModelDownloader()
        mock.existingModels = [.parakeetTDT, .qwen7B, .kokoro]

        let manager = ModelManager(downloader: mock)

        let available = await manager.requiredModelsAvailable()

        XCTAssertTrue(available)
    }

    func test_modelManager_pathForModel_returnsNilWhenNotReady() async {
        let manager = ModelManager(downloader: MockModelDownloader())

        let path = await manager.pathForModel(.kokoro)

        XCTAssertNil(path)
    }

    func test_modelManager_pathForModel_returnsPathWhenReady() async {
        let mock = MockModelDownloader()
        mock.existingModels = [.kokoro]

        let manager = ModelManager(downloader: mock)
        await manager.refreshStatuses()

        let path = await manager.pathForModel(.kokoro)

        XCTAssertNotNil(path)
        XCTAssertTrue(path!.path.contains("tts/kokoro"))
    }

    // MARK: - Model Error Tests

    func test_modelError_descriptions() {
        let verifyError = ModelError.verificationFailed(.qwen7B)
        XCTAssertTrue(verifyError.localizedDescription.contains("Qwen 2.5 7B"))

        let downloadError = ModelError.downloadFailed(.kokoro, "Network error")
        XCTAssertTrue(downloadError.localizedDescription.contains("Network error"))

        let notFoundError = ModelError.modelNotFound(.parakeetTDT)
        XCTAssertTrue(notFoundError.localizedDescription.contains("Parakeet TDT 0.6B"))

        let cancelledError = ModelError.downloadCancelled(.qwen3B)
        XCTAssertTrue(cancelledError.localizedDescription.contains("cancelled"))
    }

    // MARK: - Model Metadata Tests

    func test_modelMetadata_encoding() throws {
        let metadata = ModelMetadata(
            identifier: .qwen7B,
            version: "1.0",
            sizeBytes: 5_000_000_000,
            sha256: "abc123",
            isPrimary: true
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(metadata)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(ModelMetadata.self, from: data)

        XCTAssertEqual(decoded.identifier, .qwen7B)
        XCTAssertEqual(decoded.version, "1.0")
        XCTAssertEqual(decoded.sizeBytes, 5_000_000_000)
        XCTAssertEqual(decoded.sha256, "abc123")
        XCTAssertEqual(decoded.isPrimary, true)
    }

    // MARK: - Cancellation Tests

    func test_modelManager_cancelDownload_stopsDownload() async throws {
        let mock = MockModelDownloader()
        mock.shouldSucceed = true
        mock.downloadDelay = 1.0 // Long enough to guarantee cancellation

        let manager = ModelManager(downloader: mock)

        // Start download in background
        let downloadTask = Task {
            try await manager.downloadModel(.kokoro)
        }

        // Wait a bit then cancel
        try await Task.sleep(for: .milliseconds(50))
        await manager.cancelDownload(.kokoro)

        // Wait for task to complete - must throw cancellation error
        do {
            try await downloadTask.value
            XCTFail("Expected download to be cancelled, but it completed successfully")
        } catch let error as ModelError {
            // Verify it's specifically a cancellation error
            if case .downloadCancelled(let model) = error {
                XCTAssertEqual(model, .kokoro)
            } else {
                XCTFail("Expected downloadCancelled error, got: \(error)")
            }
            // Verify state is reset
            let state = await manager.state
            XCTAssertEqual(state.statuses[.kokoro], .notDownloaded)
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func test_modelManager_cancelDownload_noActiveDownload_noOp() async {
        let manager = ModelManager(downloader: MockModelDownloader())

        // Should not crash when cancelling non-existent download
        await manager.cancelDownload(.kokoro)

        let state = await manager.state
        // State should remain unchanged (notDownloaded or nil)
        XCTAssertFalse(state.statuses[.kokoro]?.isDownloading ?? false)
    }

    // MARK: - Progress Callback Tests

    func test_modelManager_downloadModel_callsProgressCallback() async throws {
        let mock = MockModelDownloader()
        mock.shouldSucceed = true
        mock.downloadDelay = 0.01

        let manager = ModelManager(downloader: mock)

        let progressCollector = ProgressCollector()
        let expectation = XCTestExpectation(description: "Progress callback called")
        expectation.expectedFulfillmentCount = 10 // Mock calls progress 10 times

        try await manager.downloadModel(.kokoro) { progress in
            progressCollector.append(progress.progress)
            expectation.fulfill()
        }

        await fulfillment(of: [expectation], timeout: 5.0)

        let values = progressCollector.values
        XCTAssertFalse(values.isEmpty)
        if let lastValue = values.last {
            XCTAssertEqual(lastValue, 1.0, accuracy: 0.01)
        }
    }

    func test_modelManager_downloadModel_progressIncreases() async throws {
        let mock = MockModelDownloader()
        mock.shouldSucceed = true
        mock.downloadDelay = 0.01

        let manager = ModelManager(downloader: mock)

        let progressCollector = ProgressCollector()

        try await manager.downloadModel(.kokoro) { progress in
            progressCollector.append(progress.progress)
        }

        // Verify progress increases monotonically
        let values = progressCollector.values
        for i in 1..<values.count {
            XCTAssertGreaterThanOrEqual(values[i], values[i - 1])
        }
    }

    // MARK: - State Regression Guard Tests

    func test_modelManager_progressUpdateAfterReady_doesNotRegress() async throws {
        let mock = MockModelDownloader()
        mock.shouldSucceed = true
        mock.downloadDelay = 0.01

        let manager = ModelManager(downloader: mock)

        try await manager.downloadModel(.kokoro)

        // Final state should be ready
        let state = await manager.state
        XCTAssertEqual(state.statuses[.kokoro], .ready)

        // Even if we wait, state should remain ready (progress updates should not regress)
        try await Task.sleep(for: .milliseconds(100))

        let stateAfter = await manager.state
        XCTAssertEqual(stateAfter.statuses[.kokoro], .ready)
    }

    // MARK: - Metadata Persistence Tests

    func test_modelManager_downloadModel_savesMetadata() async throws {
        let mock = MockModelDownloader()
        mock.shouldSucceed = true
        mock.downloadDelay = 0.01

        let manager = ModelManager(downloader: mock)

        try await manager.downloadModel(.kokoro)

        let state = await manager.state
        XCTAssertNotNil(state.metadata[.kokoro])
        XCTAssertEqual(state.metadata[.kokoro]?.identifier, .kokoro)
    }

    func test_modelManager_setPrimaryLLM_updatesMetadata() async throws {
        let mock = MockModelDownloader()
        mock.shouldSucceed = true
        mock.downloadDelay = 0.01

        let manager = ModelManager(downloader: mock)

        // Download both LLMs
        try await manager.downloadModel(.qwen7B)
        try await manager.downloadModel(.qwen3B)

        // Set primary
        await manager.setPrimaryLLM(.qwen3B)

        let state = await manager.state
        XCTAssertEqual(state.primaryLLM, .qwen3B)
        XCTAssertEqual(state.metadata[.qwen3B]?.isPrimary, true)
        XCTAssertEqual(state.metadata[.qwen7B]?.isPrimary, false)
    }

    func test_modelManager_deleteModel_removesMetadata() async throws {
        let mock = MockModelDownloader()
        mock.shouldSucceed = true
        mock.downloadDelay = 0.01

        let manager = ModelManager(downloader: mock)

        try await manager.downloadModel(.kokoro)

        // Verify metadata exists
        var state = await manager.state
        XCTAssertNotNil(state.metadata[.kokoro])

        // Delete
        try await manager.deleteModel(.kokoro)

        // Verify metadata removed
        state = await manager.state
        XCTAssertNil(state.metadata[.kokoro])
        XCTAssertEqual(state.statuses[.kokoro], .notDownloaded)
    }
}

// MARK: - Test Helpers

/// Thread-safe progress value collector for testing
final class ProgressCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var _values: [Double] = []

    var values: [Double] {
        lock.withLock { _values }
    }

    func append(_ value: Double) {
        lock.withLock { _values.append(value) }
    }
}
