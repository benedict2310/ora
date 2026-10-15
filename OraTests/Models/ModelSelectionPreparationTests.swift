import XCTest
@testable import Ora

final class ModelSelectionPreparationTests: XCTestCase {
    func test_concurrentSelectionsKeepPrimaryFlagsAndPersistedSelectionCoherent() async throws {
        let fixture = try ModelSelectionFixture()
        defer { fixture.remove() }
        let invalidator = DelayedSelectionInvalidator()
        let manager = fixture.manager(invalidate: { await invalidator.invalidate() })
        await manager.ensureInitialized()

        let first = Task { await manager.setPrimaryLLM(.qwen3_4B, totalRAMBytes: 16_000_000_000) }
        await invalidator.entered.wait()
        let whileInvalidating = await manager.state
        self.assertSelection(whileInvalidating, is: .qwen3_4B)

        // B completes while A is still retiring its old preparation resources.
        await manager.setPrimaryLLM(.qwen3B, totalRAMBytes: 16_000_000_000)
        let secondState = await manager.state
        self.assertSelection(secondState, is: .qwen3B)
        await invalidator.release.signal()
        await first.value

        let finalState = await manager.state
        self.assertSelection(finalState, is: .qwen3B)
        let persisted = try fixture.metadata()
        XCTAssertEqual(Set(persisted.filter { $0.isPrimary }.map(\.identifier)), [.qwen3B])
        let restarted = fixture.manager()
        await restarted.ensureInitialized()
        let restartedState = await restarted.state
        self.assertSelection(restartedState, is: .qwen3B)
        let calls = await invalidator.calls
        XCTAssertEqual(calls, 2)
    }

    func test_singleSelectionWithSafeDefaultInvalidatorPersistsAndReloads() async throws {
        let fixture = try ModelSelectionFixture()
        defer { fixture.remove() }
        let manager = fixture.manager()
        await manager.ensureInitialized()
        await manager.setPrimaryLLM(.qwen3_4B, totalRAMBytes: 16_000_000_000)
        let state = await manager.state
        self.assertSelection(state, is: .qwen3_4B)
        let restarted = fixture.manager()
        await restarted.ensureInitialized()
        let restartedState = await restarted.state
        self.assertSelection(restartedState, is: .qwen3_4B)
    }

    func test_rejectedSelectionsDoNotInvalidateOrRewriteMetadata() async throws {
        let fixture = try ModelSelectionFixture()
        defer { fixture.remove() }
        let invalidator = DelayedSelectionInvalidator(suspendFirst: false)
        let manager = fixture.manager(invalidate: { await invalidator.invalidate() })
        await manager.ensureInitialized()
        let originalData = try Data(contentsOf: fixture.metadataFile)
        await manager.setPrimaryLLM(.parakeetTDT, totalRAMBytes: 16_000_000_000)
        await manager.setPrimaryLLM(.qwen35_8B_Vision, totalRAMBytes: 16_000_000_000)
        let state = await manager.state
        self.assertSelection(state, is: .qwen3B)
        let calls = await invalidator.calls
        XCTAssertEqual(calls, 0)
        XCTAssertEqual(try Data(contentsOf: fixture.metadataFile), originalData)
    }

    private func assertSelection(_ state: ModelsState, is model: ModelIdentifier, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(state.primaryLLM, model, file: file, line: line)
        let flags = Set(state.metadata.values.filter { $0.identifier.category == .llm && $0.isPrimary }.map(\.identifier))
        XCTAssertEqual(flags, [model], "Published selection and persisted flags must agree", file: file, line: line)
        XCTAssertEqual(state.metadata[.kokoro]?.isPrimary, false, file: file, line: line)
    }
}

private actor DelayedSelectionInvalidator {
    let entered = PreparationTestSignal()
    let release = PreparationTestSignal()
    private(set) var calls = 0
    private let suspendFirst: Bool
    init(suspendFirst: Bool = true) { self.suspendFirst = suspendFirst }
    func invalidate() async {
        self.calls += 1
        if self.calls == 1 && self.suspendFirst {
            await self.entered.signal()
            await self.release.wait()
        }
    }
}

private struct ModelSelectionFixture {
    let directory: URL
    let metadataFile: URL

    init() throws {
        self.directory = FileManager.default.temporaryDirectory.appendingPathComponent("ora-model-selection-\(UUID().uuidString)", isDirectory: true)
        self.metadataFile = self.directory.appendingPathComponent("model-metadata.json")
        try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
        let metadata = [ModelMetadata(identifier: .qwen3_4B), ModelMetadata(identifier: .qwen3B, isPrimary: true), ModelMetadata(identifier: .kokoro)]
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(metadata).write(to: self.metadataFile)
    }

    func manager(invalidate: @escaping @Sendable () async -> Void = {}) -> ModelManager {
        ModelManager(downloader: MockModelDownloader(), totalRAMBytes: 16_000_000_000,
                     metadataFile: self.metadataFile, invalidateLLMPreparation: invalidate)
    }

    func metadata() throws -> [ModelMetadata] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([ModelMetadata].self, from: Data(contentsOf: self.metadataFile))
    }

    func remove() { try? FileManager.default.removeItem(at: self.directory) }
}
