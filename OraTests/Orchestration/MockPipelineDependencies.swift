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

    func startCalls() -> Int {
        return self.startCallCount
    }

    func stopCalls() -> Int {
        return self.stopCallCount
    }

    func cancelCalls() -> Int {
        return self.cancelCallCount
    }
}

final class MockASRService: ASRServicing, @unchecked Sendable {
    private let lock = NSLock()
    private var transcribeCallCount = 0
    private var resetCallCount = 0
    var events: [ASREvent] = []

    func transcribe(frames: AsyncStream<AudioFrame>) -> AsyncThrowingStream<ASREvent, Error> {
        let emittedEvents = self.lock.withLock { () -> [ASREvent] in
            self.transcribeCallCount += 1
            return self.events
        }
        return AsyncThrowingStream { continuation in
            for event in emittedEvents {
                continuation.yield(event)
            }
            continuation.finish()
        }
    }

    func transcribe(
        frames: AsyncStream<AudioFrame>,
        onVADStateChange: @escaping @Sendable @MainActor (Bool) -> Void
    ) -> AsyncThrowingStream<ASREvent, Error> {
        let emittedEvents = self.lock.withLock { () -> [ASREvent] in
            self.transcribeCallCount += 1
            return self.events
        }
        return AsyncThrowingStream { continuation in
            for event in emittedEvents {
                switch event {
                case .partial:
                    Task { @MainActor in
                        onVADStateChange(true)
                    }
                case .final:
                    Task { @MainActor in
                        onVADStateChange(false)
                    }
                }
                continuation.yield(event)
            }
            continuation.finish()
        }
    }

    func reset() async {
        self.lock.withLock {
            self.resetCallCount += 1
        }
    }

    func transcribeCalls() -> Int {
        return self.lock.withLock { self.transcribeCallCount }
    }

    func resetCalls() -> Int {
        return self.lock.withLock { self.resetCallCount }
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

actor MockAttachmentStore: AttachmentStoring {
    private(set) var removedAttachmentIDs: [UUID] = []
    private(set) var stagedDataRequests = 0
    private(set) var stagedFileRequests = 0

    var stageDataResult: Result<StagedImageAttachment, Error> = .failure(AttachmentStoreError.invalidImageData)
    var stageFileResult: Result<StagedImageAttachment, Error> = .failure(AttachmentStoreError.invalidImageData)

    func stageImageData(
        _ data: Data,
        source: ImageAttachmentSource,
        originalFilename: String?
    ) async throws -> StagedImageAttachment {
        self.stagedDataRequests += 1
        return try self.stageDataResult.get()
    }

    func stageImageFile(at sourceURL: URL) async throws -> StagedImageAttachment {
        self.stagedFileRequests += 1
        return try self.stageFileResult.get()
    }

    func removeAttachment(id: UUID) async {
        self.removedAttachmentIDs.append(id)
    }

    func removeAttachments(ids: [UUID]) async {
        self.removedAttachmentIDs.append(contentsOf: ids)
    }

    func removeAllTrackedAttachments() async {}
}

final class MockScreenshotCaptureService: ScreenshotCapturing, @unchecked Sendable {
    var screenshotResult: Result<Data, Error> = .failure(ScreenshotCaptureError.captureFailed)
    private(set) var openSettingsCallCount = 0

    func captureScreenshotPNG() async throws -> Data {
        try self.screenshotResult.get()
    }

    @MainActor
    func openScreenRecordingSettings() {
        self.openSettingsCallCount += 1
    }
}
