import Foundation
@testable import Ora

@MainActor
final class MockOverlayPresenter: OverlayPresenting {
    var mode: OverlayMode = .hidden
    let model = OverlayViewModel()
    private(set) var isVisible = false

    func show() {
        self.isVisible = true
    }

    func hide(animated: Bool) {
        self.isVisible = false
    }
}

actor MockAudioService: AudioServicing {
    private(set) var startCallCount = 0
    private(set) var stopCallCount = 0
    private(set) var cancelCallCount = 0

    func start() async throws -> AsyncStream<AudioFrame> {
        self.startCallCount += 1
        return AsyncStream { continuation in
            continuation.finish()
        }
    }

    func stop() async {
        self.stopCallCount += 1
    }

    func cancel() async {
        self.cancelCallCount += 1
    }
}

final class MockTTSService: TTSServicing, @unchecked Sendable {
    private(set) var speakCallCount = 0
    private(set) var stopCallCount = 0

    func speak(_ text: String) -> AsyncThrowingStream<AudioChunk, Error> {
        self.speakCallCount += 1
        return AsyncThrowingStream { continuation in
            continuation.finish()
        }
    }

    func stop() async {
        self.stopCallCount += 1
    }
}

@MainActor
final class MockPersistenceService: PersistenceServicing {
    let settings: AppSettings

    init(conversationModeEnabled: Bool = true, silenceTimeout: Double = 1.0) {
        let settings = AppSettings()
        settings.conversationModeEnabled = conversationModeEnabled
        settings.silenceTimeout = silenceTimeout
        self.settings = settings
    }
}
