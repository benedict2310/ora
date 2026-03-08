import XCTest
@testable import Ora

@MainActor
final class ModelMigrationCoordinatorTests: XCTestCase {

    func test_runIfNeeded_skipsWhenPrimaryAlreadyMigrated() async throws {
        let (coordinator, modelManager, _, _, defaults) = self.makeCoordinator(
            primaryLLM: .qwen35_4B_Vision
        )

        await coordinator.runIfNeeded()
        try await self.waitForCoordinatorToSettle(coordinator)

        let state = await modelManager.currentState()
        let downloadedModels = await modelManager.downloadedModelsSnapshot()
        XCTAssertEqual(state.primaryLLM, .qwen35_4B_Vision)
        XCTAssertTrue(defaults.bool(forKey: "com.ora.migration.qwen35VisionMigrationComplete"))
        XCTAssertEqual(downloadedModels, [])
    }

    func test_runIfNeeded_migratesRetiredPrimaryModel() async throws {
        let (coordinator, modelManager, overlay, notifier, defaults) = self.makeCoordinator(
            primaryLLM: .qwen3_4B
        )

        await coordinator.runIfNeeded()
        try await self.waitForCoordinatorToSettle(coordinator)

        let state = await modelManager.currentState()
        let downloadedModels = await modelManager.downloadedModelsSnapshot()
        let setPrimaryModels = await modelManager.setPrimaryModelsSnapshot()
        XCTAssertEqual(state.primaryLLM, .qwen35_4B_Vision)
        XCTAssertEqual(downloadedModels, [.qwen35_4B_Vision])
        XCTAssertEqual(setPrimaryModels, [.qwen35_4B_Vision])
        XCTAssertTrue(defaults.bool(forKey: "com.ora.migration.qwen35VisionMigrationComplete"))
        XCTAssertFalse(defaults.bool(forKey: "com.ora.migration.qwen35VisionMigrationManualRetryRequired"))
        XCTAssertEqual(notifier.posts.count, 1)
        XCTAssertTrue(overlay.notices.contains { $0.message.contains("Qwen3 VL 4B") })
        XCTAssertEqual(coordinator.status, .completed)
    }

    func test_runIfNeeded_isIdempotentAfterCompletion() async throws {
        let (coordinator, modelManager, _, _, defaults) = self.makeCoordinator(
            primaryLLM: .qwen3_4B
        )

        await coordinator.runIfNeeded()
        try await self.waitForCoordinatorToSettle(coordinator)

        defaults.set(true, forKey: "com.ora.migration.qwen35VisionMigrationComplete")
        await coordinator.runIfNeeded()
        try await self.waitForCoordinatorToSettle(coordinator)

        let downloadedModels = await modelManager.downloadedModelsSnapshot()
        XCTAssertEqual(downloadedModels, [.qwen35_4B_Vision])
    }

    func test_runIfNeeded_failureRequiresManualRetry() async throws {
        let (coordinator, modelManager, overlay, notifier, defaults) = self.makeCoordinator(
            primaryLLM: .qwen3_4B,
            shouldDownloadSucceed: false
        )

        await coordinator.runIfNeeded()
        try await self.waitForCoordinatorToSettle(coordinator)

        let state = await modelManager.currentState()
        XCTAssertEqual(state.primaryLLM, .qwen3_4B)
        XCTAssertTrue(defaults.bool(forKey: "com.ora.migration.qwen35VisionMigrationManualRetryRequired"))
        XCTAssertFalse(defaults.bool(forKey: "com.ora.migration.qwen35VisionMigrationComplete"))
        XCTAssertEqual(notifier.posts.count, 1)
        XCTAssertEqual(overlay.notices.last?.action, .openModelsPreferences)

        if case .failed(let message) = coordinator.status {
            XCTAssertTrue(message.contains("retry"))
        } else {
            XCTFail("Expected failure status")
        }
    }

    func test_retryFromPreferences_retriesAfterFailure() async throws {
        let suiteName = "ModelMigrationCoordinatorTests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            return XCTFail("Failed to create isolated UserDefaults suite")
        }
        defaults.removePersistentDomain(forName: suiteName)
        defaults.oraSetupComplete = true

        let overlay = MockMigrationOverlayPresenter()
        let notifier = MockMigrationNotificationDeliverer()
        let modelManager = MockMigrationModelManager(primaryLLM: .qwen3_4B, shouldDownloadSucceed: false)
        let coordinator = ModelMigrationCoordinator(
            modelManager: modelManager,
            overlayPresenter: overlay,
            notificationDeliverer: notifier,
            userDefaults: defaults
        )

        await coordinator.runIfNeeded()
        try await self.waitForCoordinatorToSettle(coordinator)

        await modelManager.setShouldDownloadSucceed(true)
        await coordinator.retryFromPreferences()
        try await self.waitForCoordinatorToSettle(coordinator)

        let state = await modelManager.currentState()
        XCTAssertEqual(state.primaryLLM, .qwen35_4B_Vision)
        XCTAssertFalse(defaults.bool(forKey: "com.ora.migration.qwen35VisionMigrationManualRetryRequired"))
    }

    private func makeCoordinator(
        primaryLLM: ModelIdentifier,
        shouldDownloadSucceed: Bool = true
    ) -> (
        coordinator: ModelMigrationCoordinator,
        modelManager: MockMigrationModelManager,
        overlay: MockMigrationOverlayPresenter,
        notifier: MockMigrationNotificationDeliverer,
        defaults: UserDefaults
    ) {
        let suiteName = "ModelMigrationCoordinatorTests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            fatalError("Failed to create isolated UserDefaults suite")
        }
        defaults.removePersistentDomain(forName: suiteName)
        defaults.oraSetupComplete = true

        let overlay = MockMigrationOverlayPresenter()
        let notifier = MockMigrationNotificationDeliverer()
        let modelManager = MockMigrationModelManager(
            primaryLLM: primaryLLM,
            shouldDownloadSucceed: shouldDownloadSucceed
        )
        let coordinator = ModelMigrationCoordinator(
            modelManager: modelManager,
            overlayPresenter: overlay,
            notificationDeliverer: notifier,
            userDefaults: defaults
        )

        return (coordinator, modelManager, overlay, notifier, defaults)
    }

    private func waitForCoordinatorToSettle(_ coordinator: ModelMigrationCoordinator) async throws {
        for _ in 0..<100 {
            if case .migrating = coordinator.status {
                try await Task.sleep(for: .milliseconds(10))
                continue
            }
            return
        }

        XCTFail("Timed out waiting for migration coordinator to settle")
    }
}

@MainActor
private final class MockMigrationOverlayPresenter: ModelMigrationOverlayPresenting {
    private(set) var notices: [OverlayMigrationNotice] = []
    private(set) var clearCount = 0

    func showMigrationNotice(_ notice: OverlayMigrationNotice) {
        self.notices.append(notice)
    }

    func clearMigrationNotice() {
        self.clearCount += 1
    }
}

@MainActor
private final class MockMigrationNotificationDeliverer: ModelMigrationNotificationDelivering {
    private(set) var posts: [(title: String, body: String)] = []

    func post(title: String, body: String) async {
        self.posts.append((title, body))
    }
}

private actor MockMigrationModelManager: ModelMigrationModelManaging {
    private var stateValue: ModelsState
    private var shouldDownloadSucceed: Bool
    private(set) var downloadedModels: [ModelIdentifier] = []
    private(set) var setPrimaryModels: [ModelIdentifier] = []

    init(primaryLLM: ModelIdentifier, shouldDownloadSucceed: Bool) {
        var state = ModelsState()
        state.primaryLLM = primaryLLM
        state.statuses[primaryLLM] = .ready
        self.stateValue = state
        self.shouldDownloadSucceed = shouldDownloadSucceed
    }

    func ensureInitialized() async {}

    func currentState() async -> ModelsState {
        return self.stateValue
    }

    func downloadModel(
        _ model: ModelIdentifier,
        progress: (@Sendable (ModelDownloadProgress) -> Void)?
    ) async throws {
        guard self.shouldDownloadSucceed else {
            throw ModelError.downloadFailed(model, "Mock download failure")
        }

        for value in [0.15, 0.55, 1.0] {
            progress?(ModelDownloadProgress(identifier: model, progress: value))
            try await Task.sleep(for: .milliseconds(5))
        }

        self.downloadedModels.append(model)
        self.stateValue.statuses[model] = .ready
    }

    func setPrimaryLLM(_ model: ModelIdentifier, totalRAMBytes: UInt64) async {
        self.setPrimaryModels.append(model)
        self.stateValue.primaryLLM = model
        self.stateValue.statuses[model] = .ready
    }

    func setShouldDownloadSucceed(_ value: Bool) async {
        self.shouldDownloadSucceed = value
    }

    func downloadedModelsSnapshot() async -> [ModelIdentifier] {
        return self.downloadedModels
    }

    func setPrimaryModelsSnapshot() async -> [ModelIdentifier] {
        return self.setPrimaryModels
    }
}
