//
//  FluidAudioStrategyTests.swift
//  OraTests
//
//  Tests for FluidAudioStrategy progress mapping
//

import XCTest
@testable import Ora

final class FluidAudioStrategyTests: XCTestCase {

    func test_progress_mapping() {
        let model = ModelIdentifier.parakeetTDT

        let running = ParakeetModelDownloader.State.running(
            progress: 0.42,
            fileIndex: 1,
            fileCount: 3,
            currentFile: "encoder.mlmodelc"
        )
        let runningProgress = FluidAudioStrategy.progress(for: running, model: model)
        XCTAssertEqual(runningProgress?.identifier, model)
        XCTAssertEqual(runningProgress?.progress, 0.42)
        XCTAssertEqual(runningProgress?.currentFile, "encoder.mlmodelc")

        let verifyingProgress = FluidAudioStrategy.progress(for: .verifying, model: model)
        XCTAssertEqual(verifyingProgress?.progress, 0.95)

        let doneProgress = FluidAudioStrategy.progress(for: .done(URL(fileURLWithPath: "/tmp")), model: model)
        XCTAssertEqual(doneProgress?.progress, 1.0)

        XCTAssertNil(FluidAudioStrategy.progress(for: .idle, model: model))
        XCTAssertNil(FluidAudioStrategy.progress(for: .failed(ParakeetModelDownloader.DownloadError.invalidResponse), model: model))
    }

    func test_estimatedProgressFromDirectorySize_clampsAtNinetyPercent() {
        let model = ModelIdentifier.parakeetTDT
        let halfSize = model.estimatedSizeBytes / 2
        XCTAssertEqual(
            FluidAudioStrategy.estimatedProgressFromDirectorySize(halfSize, model: model),
            0.5,
            accuracy: 0.001
        )

        let oversized = model.estimatedSizeBytes * 2
        XCTAssertEqual(
            FluidAudioStrategy.estimatedProgressFromDirectorySize(oversized, model: model),
            FluidAudioStrategy.maxEstimatedProgressBeforeVerification,
            accuracy: 0.001
        )

        XCTAssertEqual(
            FluidAudioStrategy.estimatedProgressFromDirectorySize(0, model: model),
            0.0
        )
    }
}
