import XCTest
@testable import Ora

/// Deterministic, level-triggered signals; no scheduling sleeps or hardware.
actor PreparationTestSignal {
    private var signalled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !self.signalled else { return }
        await withCheckedContinuation { self.waiters.append($0) }
    }

    func signal() {
        self.signalled = true
        self.waiters.forEach { $0.resume() }
        self.waiters.removeAll()
    }
}

actor PreparationTestRuntime: LLMGenerationRuntime {
    private(set) var cleanupUnderGate: [Bool] = []
    private(set) var generationCount = 0
    private let cleanupStarted: PreparationTestSignal?
    private let finishCleanup: PreparationTestSignal?
    init(cleanupStarted: PreparationTestSignal? = nil, finishCleanup: PreparationTestSignal? = nil) {
        self.cleanupStarted = cleanupStarted
        self.finishCleanup = finishCleanup
    }
    func makeCache(parameters: LLMGenerationParameters) async -> LLMRequestCache { LLMRequestCache(storage: []) }
    func cleanup() async {
        self.cleanupUnderGate.append(await MLXMetalGate.shared.isAcquired)
        await self.cleanupStarted?.signal()
        await self.finishCleanup?.wait()
    }
    func generate(
        request: LLMPreparedRequest,
        cache: LLMRequestCache,
        parameters: LLMGenerationParameters,
        emit: @escaping @Sendable (String) -> Bool,
        didReceiveFirstToken: @escaping @Sendable (Int) -> Void
    ) async throws -> Int {
        self.generationCount += 1
        _ = emit("fake")
        return 1
    }
}

actor PreparationTestLoader {
    let started = PreparationTestSignal()
    let release = PreparationTestSignal()
    let runtime = PreparationTestRuntime()
    private(set) var count = 0
    private let suspendFirst: Bool
    private let failFirst: Bool

    init(suspendFirst: Bool = true, failFirst: Bool = false) {
        self.suspendFirst = suspendFirst
        self.failFirst = failFirst
    }

    func load(_ model: ModelIdentifier) async throws -> LLMPreparedModel {
        self.count += 1
        let first = self.count == 1
        await self.started.signal()
        if first && self.suspendFirst { await self.release.wait() }
        if first && self.failFirst { throw LLMServiceError.modelNotFound }
        return LLMPreparedModel(runtime: self.runtime, backend: .mlxLLM)
    }
}
