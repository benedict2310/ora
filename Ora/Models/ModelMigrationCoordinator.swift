//
//  ModelMigrationCoordinator.swift
//  Ora
//
//  Coordinates one-time migration from the retired Qwen 3 4B model
//  to the default Qwen3 VL 4B local model.
//

import Foundation
import UserNotifications
import os

@MainActor
protocol ModelMigrationOverlayPresenting: AnyObject {
    func showMigrationNotice(_ notice: OverlayMigrationNotice)
    func clearMigrationNotice()
}

extension OverlayViewModel: ModelMigrationOverlayPresenting {}

protocol ModelMigrationModelManaging: Sendable {
    func ensureInitialized() async
    func currentState() async -> ModelsState
    func downloadModel(
        _ model: ModelIdentifier,
        progress: (@Sendable (ModelDownloadProgress) -> Void)?
    ) async throws
    func setPrimaryLLM(_ model: ModelIdentifier, totalRAMBytes: UInt64) async
}

extension ModelManager: ModelMigrationModelManaging {
    func currentState() async -> ModelsState {
        return self.state
    }
}

@MainActor
protocol ModelMigrationNotificationDelivering {
    func post(title: String, body: String) async
}

@MainActor
struct UserNotificationMigrationNotifier: ModelMigrationNotificationDelivering {
    func post(title: String, body: String) async {
        let center = UNUserNotificationCenter.current()
        let granted = await self.requestAuthorizationIfNeeded(center: center)
        guard granted else { return }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "com.ora.model-migration.\(title)",
            content: content,
            trigger: nil
        )

        do {
            try await center.add(request)
        } catch {
            Logger.ora(category: "ModelMigration").warning("Failed to post model migration notification: \(error.localizedDescription)")
        }
    }

    private func requestAuthorizationIfNeeded(center: UNUserNotificationCenter) async -> Bool {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional:
            return true
        case .denied:
            return false
        case .notDetermined:
            do {
                return try await center.requestAuthorization(options: [.alert, .sound])
            } catch {
                Logger.ora(category: "ModelMigration").warning("Notification authorization request failed: \(error.localizedDescription)")
                return false
            }
        @unknown default:
            return false
        }
    }
}

@MainActor
enum ModelMigrationStatus: Equatable {
    case idle
    case migrating(progress: Double)
    case failed(message: String)
    case completed

    var progressValue: Double? {
        if case .migrating(let progress) = self {
            return progress
        }
        return nil
    }
}

@MainActor
final class ModelMigrationCoordinator: ObservableObject {

    static let shared = ModelMigrationCoordinator()

    @Published private(set) var status: ModelMigrationStatus = .idle

    private let logger = Logger.ora(category: "ModelMigration")
    private let modelManager: any ModelMigrationModelManaging
    private weak var overlayPresenter: (any ModelMigrationOverlayPresenting)?
    private let notificationDeliverer: any ModelMigrationNotificationDelivering
    private let userDefaults: UserDefaults
    private let totalRAMBytes: UInt64
    private var migrationTask: Task<Void, Never>?
    private var clearSuccessNoticeTask: Task<Void, Never>?

    private static let completionKey = "com.ora.migration.qwen35VisionMigrationComplete"
    private static let manualRetryRequiredKey = "com.ora.migration.qwen35VisionMigrationManualRetryRequired"

    init(
        modelManager: any ModelMigrationModelManaging = ModelManager.shared,
        overlayPresenter: (any ModelMigrationOverlayPresenting)? = OverlayWindowController.shared.model,
        notificationDeliverer: any ModelMigrationNotificationDelivering = UserNotificationMigrationNotifier(),
        userDefaults: UserDefaults = .standard,
        totalRAMBytes: UInt64 = ProcessInfo.processInfo.physicalMemory
    ) {
        self.modelManager = modelManager
        self.overlayPresenter = overlayPresenter
        self.notificationDeliverer = notificationDeliverer
        self.userDefaults = userDefaults
        self.totalRAMBytes = totalRAMBytes
    }

    var manualRetryRequired: Bool {
        return self.userDefaults.bool(forKey: Self.manualRetryRequiredKey)
    }

    var migrationCompleted: Bool {
        return self.userDefaults.bool(forKey: Self.completionKey)
    }

    func runIfNeeded() async {
        await self.evaluateMigration(forceRetry: false)
    }

    func retryFromPreferences() async {
        self.userDefaults.set(false, forKey: Self.manualRetryRequiredKey)
        await self.evaluateMigration(forceRetry: true)
    }

    private func evaluateMigration(forceRetry: Bool) async {
        guard self.userDefaults.oraSetupComplete else { return }
        guard self.migrationTask == nil else { return }
        guard !self.userDefaults.bool(forKey: Self.completionKey) || forceRetry else { return }

        await self.modelManager.ensureInitialized()
        let state = await self.modelManager.currentState()

        guard state.primaryLLM == .qwen3_4B else {
            if state.primaryLLM == .qwen35_4B_Vision {
                self.userDefaults.set(true, forKey: Self.completionKey)
                self.userDefaults.set(false, forKey: Self.manualRetryRequiredKey)
            }
            return
        }

        guard ModelIdentifier.qwen35_4B_Vision.isSupported(on: self.totalRAMBytes) else {
            self.completeUnsupportedHardwareSkip()
            return
        }

        if state.statuses[.qwen35_4B_Vision]?.isReady == true {
            await self.completeMigration(shouldNotify: true)
            return
        }

        if self.manualRetryRequired && !forceRetry {
            let message = "Model upgrade paused. Open Preferences > Models to retry."
            self.status = .failed(message: message)
            self.overlayPresenter?.showMigrationNotice(
                OverlayMigrationNotice(
                    message: message,
                    iconName: "exclamationmark.triangle.fill",
                    action: .openModelsPreferences
                )
            )
            return
        }

        self.startMigration()
    }

    private func startMigration() {
        self.clearSuccessNoticeTask?.cancel()
        self.status = .migrating(progress: 0)
        self.overlayPresenter?.showMigrationNotice(self.progressNotice(for: 0))

        self.migrationTask = Task { [weak self] in
            guard let self else { return }

            do {
                try await self.modelManager.downloadModel(.qwen35_4B_Vision) { progress in
                    Task { @MainActor [weak self] in
                        self?.handleProgress(progress.progress)
                    }
                }
                await self.completeMigration(shouldNotify: true)
            } catch is CancellationError {
                await self.cancelMigration()
            } catch {
                await self.failMigration(error: error)
            }
        }
    }

    private func handleProgress(_ progress: Double) {
        let clampedProgress = min(max(progress, 0), 1)
        self.status = .migrating(progress: clampedProgress)
        self.overlayPresenter?.showMigrationNotice(self.progressNotice(for: clampedProgress))
    }

    private func completeMigration(shouldNotify: Bool) async {
        self.migrationTask = nil
        await self.modelManager.setPrimaryLLM(.qwen35_4B_Vision, totalRAMBytes: self.totalRAMBytes)
        let state = await self.modelManager.currentState()
        guard state.primaryLLM == .qwen35_4B_Vision else {
            await self.failMigration(error: MigrationError.primarySwitchFailed)
            return
        }

        self.userDefaults.set(true, forKey: Self.completionKey)
        self.userDefaults.set(false, forKey: Self.manualRetryRequiredKey)

        self.status = .completed
        self.overlayPresenter?.showMigrationNotice(
            OverlayMigrationNotice(
                message: "Ora upgraded your local model to Qwen3 VL 4B.",
                iconName: "checkmark.circle.fill"
            )
        )

        if shouldNotify {
            await self.notificationDeliverer.post(
                title: "Ora model upgrade complete",
                body: "Ora upgraded your local model to Qwen3 VL 4B."
            )
        }

        self.scheduleSuccessNoticeClear()
        self.logger.info("Model migration completed successfully")
    }

    private func completeUnsupportedHardwareSkip() {
        self.migrationTask = nil
        self.status = .idle
        self.userDefaults.set(true, forKey: Self.completionKey)
        self.userDefaults.set(false, forKey: Self.manualRetryRequiredKey)
        self.overlayPresenter?.clearMigrationNotice()
        self.logger.info("Skipping Qwen3 VL 4B migration because this Mac does not meet the 16 GB RAM requirement")
    }

    private func cancelMigration() async {
        self.migrationTask = nil
        self.status = .idle
        self.overlayPresenter?.clearMigrationNotice()
    }

    private func failMigration(error: Error) async {
        self.migrationTask = nil
        self.userDefaults.set(true, forKey: Self.manualRetryRequiredKey)

        let message = "Ora could not upgrade to Qwen3 VL 4B. Open Preferences > Models to retry."
        self.status = .failed(message: message)
        self.overlayPresenter?.showMigrationNotice(
            OverlayMigrationNotice(
                message: message,
                iconName: "exclamationmark.triangle.fill",
                action: .openModelsPreferences
            )
        )

        await self.notificationDeliverer.post(
            title: "Ora model upgrade failed",
            body: "Ora could not upgrade to Qwen3 VL 4B. Open Preferences > Models to retry."
        )

        self.logger.error("Model migration failed: \(error.localizedDescription)")
    }

    private func scheduleSuccessNoticeClear() {
        self.clearSuccessNoticeTask?.cancel()
        self.clearSuccessNoticeTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(8))
            } catch {
                return
            }

            guard let self, self.status == .completed else { return }
            self.overlayPresenter?.clearMigrationNotice()
        }
    }

    private func progressNotice(for progress: Double) -> OverlayMigrationNotice {
        let percent = Int((progress * 100).rounded())
        return OverlayMigrationNotice(
            message: "Upgrading local model to Qwen3 VL 4B (\(percent)% complete)."
        )
    }
}

private enum MigrationError: Error {
    case primarySwitchFailed
}
