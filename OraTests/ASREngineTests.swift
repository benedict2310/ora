//
//  ASREngineTests.swift
//  OraTests
//
//  Unit tests for ASR engine components
//

import XCTest
@testable import Ora

final class ASREngineTests: XCTestCase {

    // MARK: - Protocol Conformance Tests

    func test_ParakeetEngine_conformsToASREngine() {
        let engine = ParakeetEngine(bootstrap: ParakeetBootstrap(forTesting: true))
        // Verify type conforms to protocol by assigning to protocol type
        let _: ASREngine = engine
        XCTAssertNotNil(engine)
    }

    // MARK: - Data Structure Tests

    func test_ASRWord_isSendable() {
        let word = ASRWord(text: "hello", startTime: 0.0, endTime: 0.5, confidence: 0.95)
        // Sendable check - can be passed to Task
        Task {
            let _ = word
        }
        XCTAssertEqual(word.text, "hello")
    }

    func test_ASRWord_isEquatable() {
        let word1 = ASRWord(text: "hello", startTime: 0.0, endTime: 0.5, confidence: 0.95)
        let word2 = ASRWord(text: "hello", startTime: 0.0, endTime: 0.5, confidence: 0.95)
        let word3 = ASRWord(text: "world", startTime: 0.0, endTime: 0.5, confidence: 0.95)

        XCTAssertEqual(word1, word2)
        XCTAssertNotEqual(word1, word3)
    }

    func test_ASRWord_optionalFields() {
        let wordWithTiming = ASRWord(text: "test", startTime: 0.1, endTime: 0.5, confidence: 0.9)
        let wordWithoutTiming = ASRWord(text: "test", startTime: nil, endTime: nil, confidence: nil)

        XCTAssertNotNil(wordWithTiming.startTime)
        XCTAssertNotNil(wordWithTiming.confidence)
        XCTAssertNil(wordWithoutTiming.startTime)
        XCTAssertNil(wordWithoutTiming.confidence)
    }

    func test_ASRPartial_isSendable() {
        let partial = ASRPartial(text: "hello world", words: [])
        Task {
            let _ = partial
        }
        XCTAssertEqual(partial.text, "hello world")
    }

    func test_ASRPartial_isEquatable() {
        let words = [ASRWord(text: "hello", startTime: nil, endTime: nil, confidence: nil)]
        let partial1 = ASRPartial(text: "hello", words: words)
        let partial2 = ASRPartial(text: "hello", words: words)
        let partial3 = ASRPartial(text: "world", words: [])

        XCTAssertEqual(partial1, partial2)
        XCTAssertNotEqual(partial1, partial3)
    }

    func test_ASRFinalSegment_isSendable() {
        let segment = ASRFinalSegment(text: "final result", words: [])
        Task {
            let _ = segment
        }
        XCTAssertEqual(segment.text, "final result")
    }

    func test_ASRFinalSegment_isEquatable() {
        let segment1 = ASRFinalSegment(text: "test", words: [])
        let segment2 = ASRFinalSegment(text: "test", words: [])
        let segment3 = ASRFinalSegment(text: "different", words: [])

        XCTAssertEqual(segment1, segment2)
        XCTAssertNotEqual(segment1, segment3)
    }

    // MARK: - PCM Buffer Creation Tests

    func test_makePCMBuffer_createsValidBuffer() {
        let samples = [Float](repeating: 0.0, count: 16000)
        let buffer = ParakeetEngine.makePCMBuffer(samples: samples)

        XCTAssertNotNil(buffer)
        XCTAssertEqual(buffer?.frameLength, 16000)
        XCTAssertEqual(buffer?.format.sampleRate, 16000)
        XCTAssertEqual(buffer?.format.channelCount, 1)
    }

    func test_makePCMBuffer_returnsNilForEmptyArray() {
        let samples: [Float] = []
        let buffer = ParakeetEngine.makePCMBuffer(samples: samples)

        XCTAssertNil(buffer)
    }

    func test_makePCMBuffer_preservesSampleData() {
        let samples: [Float] = [0.1, 0.2, 0.3, 0.4, 0.5]
        let buffer = ParakeetEngine.makePCMBuffer(samples: samples)

        XCTAssertNotNil(buffer)
        if let channelData = buffer?.floatChannelData?[0] {
            XCTAssertEqual(channelData[0], 0.1, accuracy: 0.0001)
            XCTAssertEqual(channelData[1], 0.2, accuracy: 0.0001)
            XCTAssertEqual(channelData[4], 0.5, accuracy: 0.0001)
        } else {
            XCTFail("Expected channel data")
        }
    }
}

// MARK: - Bootstrap Tests

final class ParakeetBootstrapTests: XCTestCase {

    // MARK: - Singleton Tests

    func test_shared_returnsSameInstance() {
        let instance1 = ParakeetBootstrap.shared
        let instance2 = ParakeetBootstrap.shared
        XCTAssertTrue(instance1 === instance2)
    }

    // MARK: - State Tests

    func test_initialState_isIdle() {
        let bootstrap = ParakeetBootstrap(forTesting: true)
        XCTAssertEqual(bootstrap.currentState(), .idle)
    }

    func test_invalidate_resetsState() {
        let bootstrap = ParakeetBootstrap(forTesting: true)
        bootstrap.invalidate()
        XCTAssertEqual(bootstrap.currentState(), .idle)
        XCTAssertNil(bootstrap.currentManager())
    }

    func test_engineState_isReadyProperty() {
        XCTAssertFalse(ParakeetBootstrap.EngineState.idle.isReady)
        XCTAssertFalse(ParakeetBootstrap.EngineState.downloading.isReady)
        XCTAssertFalse(ParakeetBootstrap.EngineState.loading.isReady)
        XCTAssertTrue(ParakeetBootstrap.EngineState.ready.isReady)
        XCTAssertFalse(ParakeetBootstrap.EngineState.failed("error").isReady)
    }

    // MARK: - Error Tests

    func test_bootstrapError_descriptions() {
        let modelsNotAvailable = ParakeetBootstrap.BootstrapError.modelsNotAvailable
        XCTAssertTrue(modelsNotAvailable.localizedDescription.contains("not downloaded"))

        let loadFailed = ParakeetBootstrap.BootstrapError.loadFailed("Test error")
        XCTAssertTrue(loadFailed.localizedDescription.contains("Test error"))

        let deallocated = ParakeetBootstrap.BootstrapError.bootstrapDeallocated
        XCTAssertTrue(deallocated.localizedDescription.contains("deallocated"))
    }

    func test_bootstrapError_equatable() {
        XCTAssertEqual(
            ParakeetBootstrap.BootstrapError.modelsNotAvailable,
            ParakeetBootstrap.BootstrapError.modelsNotAvailable
        )
        XCTAssertEqual(
            ParakeetBootstrap.BootstrapError.loadFailed("same"),
            ParakeetBootstrap.BootstrapError.loadFailed("same")
        )
        XCTAssertNotEqual(
            ParakeetBootstrap.BootstrapError.loadFailed("a"),
            ParakeetBootstrap.BootstrapError.loadFailed("b")
        )
    }

    // MARK: - Models Not Available Tests

    func test_ensureReady_throwsWhenModelsMissing() async throws {
        let bootstrap = ParakeetBootstrap(forTesting: true)
        bootstrap.invalidate()

        // Skip if models are actually present
        guard !bootstrap.modelsAvailable() else {
            throw XCTSkip("Models available - cannot test missing scenario")
        }

        do {
            _ = try await bootstrap.ensureReady()
            XCTFail("Should throw modelsNotAvailable")
        } catch let error as ParakeetBootstrap.BootstrapError {
            XCTAssertEqual(error, .modelsNotAvailable)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}

// MARK: - Model Downloader Tests

final class ParakeetModelDownloaderTests: XCTestCase {

    func test_repoDirectory_containsParakeetPath() {
        let path = ParakeetModelDownloader.repoDirectory
        XCTAssertTrue(path.path.contains("Ora/Models/asr/parakeet"))
    }

    func test_downloadError_descriptions() {
        let invalidResponse = ParakeetModelDownloader.DownloadError.invalidResponse
        XCTAssertTrue(invalidResponse.localizedDescription.contains("Invalid"))

        let rateLimited = ParakeetModelDownloader.DownloadError.rateLimited(statusCode: 429)
        XCTAssertTrue(rateLimited.localizedDescription.contains("429"))
        XCTAssertTrue(rateLimited.localizedDescription.lowercased().contains("limit"))

        let noFiles = ParakeetModelDownloader.DownloadError.noFilesFound
        XCTAssertTrue(noFiles.localizedDescription.contains("No model files"))

        let downloadFailed = ParakeetModelDownloader.DownloadError.downloadFailed(path: "/test/path")
        XCTAssertTrue(downloadFailed.localizedDescription.contains("/test/path"))

        let modelMissing = ParakeetModelDownloader.DownloadError.modelFileMissing(name: "encoder.mlmodelc")
        XCTAssertTrue(modelMissing.localizedDescription.contains("encoder.mlmodelc"))

        let networkUnavailable = ParakeetModelDownloader.DownloadError.networkUnavailable
        XCTAssertTrue(networkUnavailable.localizedDescription.contains("Network"))
    }

    func test_state_equatable() {
        XCTAssertEqual(ParakeetModelDownloader.State.idle, ParakeetModelDownloader.State.idle)
        XCTAssertEqual(ParakeetModelDownloader.State.verifying, ParakeetModelDownloader.State.verifying)
        XCTAssertEqual(
            ParakeetModelDownloader.State.running(progress: 0.5, fileIndex: 1, fileCount: 3, currentFile: "test"),
            ParakeetModelDownloader.State.running(progress: 0.5, fileIndex: 1, fileCount: 3, currentFile: "test")
        )
        XCTAssertNotEqual(
            ParakeetModelDownloader.State.running(progress: 0.5, fileIndex: 1, fileCount: 3, currentFile: "test"),
            ParakeetModelDownloader.State.running(progress: 0.6, fileIndex: 1, fileCount: 3, currentFile: "test")
        )
    }

    func test_modelsAvailable_returnsBool() {
        let downloader = ParakeetModelDownloader()
        let available = downloader.modelsAvailable()
        // Just verify it returns a boolean without crashing
        XCTAssertNotNil(available)
    }
}

// MARK: - Notification Tests

final class ASRNotificationTests: XCTestCase {

    func test_notificationNames_areDefined() {
        XCTAssertEqual(
            Notification.Name.parakeetDownloadStateDidChange.rawValue,
            "parakeetDownloadStateDidChange"
        )
        XCTAssertEqual(
            Notification.Name.parakeetEngineStateDidChange.rawValue,
            "parakeetEngineStateDidChange"
        )
    }

    func test_engineStateNotification_postsOnStateChange() async throws {
        let expectation = XCTestExpectation(description: "State notification received")

        let observer = NotificationCenter.default.addObserver(
            forName: .parakeetEngineStateDidChange,
            object: nil,
            queue: .main
        ) { notification in
            XCTAssertNotNil(notification.object as? ParakeetBootstrap.EngineState)
            expectation.fulfill()
        }

        defer { NotificationCenter.default.removeObserver(observer) }

        let bootstrap = ParakeetBootstrap(forTesting: true)
        bootstrap.invalidate() // This triggers a state change notification

        await fulfillment(of: [expectation], timeout: 2.0)
    }
}

// MARK: - Thread Safety Tests

final class ASRConcurrencyTests: XCTestCase {

    func test_concurrentStateAccess_noDataRace() async {
        let bootstrap = ParakeetBootstrap(forTesting: true)
        bootstrap.invalidate()

        await withTaskGroup(of: ParakeetBootstrap.EngineState.self) { group in
            for _ in 0..<100 {
                group.addTask {
                    return bootstrap.currentState()
                }
            }

            var states: [ParakeetBootstrap.EngineState] = []
            for await state in group {
                states.append(state)
            }

            XCTAssertEqual(states.count, 100)
        }
    }

    func test_concurrentModelsAvailableAccess_noDataRace() async {
        let downloader = ParakeetModelDownloader()

        await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<100 {
                group.addTask {
                    return downloader.modelsAvailable()
                }
            }

            var results: [Bool] = []
            for await result in group {
                results.append(result)
            }

            XCTAssertEqual(results.count, 100)
            // All results should be the same (consistent state)
            let uniqueResults = Set(results)
            XCTAssertEqual(uniqueResults.count, 1)
        }
    }
}

// MARK: - Memory Tests

final class ASRMemoryTests: XCTestCase {

    func test_engineDeallocates_afterUse() async throws {
        weak var weakEngine: ParakeetEngine?

        autoreleasepool {
            let bootstrap = ParakeetBootstrap(forTesting: true)
            let engine = ParakeetEngine(bootstrap: bootstrap)
            weakEngine = engine
        }

        // Allow deallocation
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertNil(weakEngine)
    }
}
