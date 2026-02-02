//
//  UpdateController.swift
//  Ora
//
//  Sparkle update controller wrapper
//

import Foundation
import Sparkle
import os

// MARK: - Update Checking Protocol

@MainActor
protocol UpdateChecking: AnyObject {
    var canCheckForUpdates: Bool { get }
    func checkForUpdates()
}

// MARK: - Update Check Interval

enum UpdateCheckInterval: TimeInterval, CaseIterable, Identifiable {
    case daily = 86400
    case weekly = 604800
    case monthly = 2592000

    var id: TimeInterval { self.rawValue }

    var title: String {
        switch self {
        case .daily:
            return "Daily"
        case .weekly:
            return "Weekly"
        case .monthly:
            return "Monthly"
        }
    }

    static func nearest(to interval: TimeInterval) -> UpdateCheckInterval {
        let sorted = self.allCases.sorted { abs($0.rawValue - interval) < abs($1.rawValue - interval) }
        return sorted.first ?? .daily
    }
}

// MARK: - Update Controller

@MainActor
final class UpdateController: ObservableObject, UpdateChecking {

    // MARK: - Singleton

    static let shared = UpdateController()

    // MARK: - Published State

    @Published private(set) var canCheckForUpdates: Bool = false
    @Published private(set) var lastUpdateCheck: Date?
    @Published var automaticallyChecksForUpdates: Bool = true {
        didSet {
            guard !self.isApplyingUpdaterState else { return }
            self.updater.automaticallyChecksForUpdates = self.automaticallyChecksForUpdates
        }
    }
    @Published var updateCheckInterval: UpdateCheckInterval = .daily {
        didSet {
            guard !self.isApplyingUpdaterState else { return }
            self.updater.updateCheckInterval = self.updateCheckInterval.rawValue
        }
    }

    // MARK: - Properties

    private let logger = Logger(subsystem: "com.ora.app", category: "Updates")
    private let updater: UpdateDriver
    private var isApplyingUpdaterState = false

    // MARK: - Initialization

    init(updater: UpdateDriver = SparkleUpdateDriver()) {
        self.updater = updater
        self.refreshFromUpdater()
        self.updater.observeChanges { [weak self] in
            guard let self else { return }
            self.refreshFromUpdater()
        }
    }

    // MARK: - UpdateChecking

    func checkForUpdates() {
        self.logger.info("User initiated update check")
        self.updater.checkForUpdates()
    }

    // MARK: - Private

    private func refreshFromUpdater() {
        self.isApplyingUpdaterState = true
        self.canCheckForUpdates = self.updater.canCheckForUpdates
        self.lastUpdateCheck = self.updater.lastUpdateCheckDate
        self.automaticallyChecksForUpdates = self.updater.automaticallyChecksForUpdates
        self.updateCheckInterval = UpdateCheckInterval.nearest(to: self.updater.updateCheckInterval)
        self.isApplyingUpdaterState = false
    }
}

// MARK: - Update Driver Protocol

@MainActor
protocol UpdateDriver: AnyObject {
    var canCheckForUpdates: Bool { get }
    var lastUpdateCheckDate: Date? { get }
    var automaticallyChecksForUpdates: Bool { get set }
    var updateCheckInterval: TimeInterval { get set }

    func checkForUpdates()
    func observeChanges(_ handler: @escaping () -> Void)
}

// MARK: - Sparkle Driver

@MainActor
final class SparkleUpdateDriver: UpdateDriver {

    // MARK: - Properties

    private let updaterController: SPUStandardUpdaterController
    private var observations: [NSKeyValueObservation] = []
    private var changeHandler: (() -> Void)?

    // MARK: - Initialization

    init() {
        self.updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    // MARK: - UpdateDriver

    var canCheckForUpdates: Bool {
        return self.updaterController.updater.canCheckForUpdates
    }

    var lastUpdateCheckDate: Date? {
        return self.updaterController.updater.lastUpdateCheckDate
    }

    var automaticallyChecksForUpdates: Bool {
        get { self.updaterController.updater.automaticallyChecksForUpdates }
        set { self.updaterController.updater.automaticallyChecksForUpdates = newValue }
    }

    var updateCheckInterval: TimeInterval {
        get { self.updaterController.updater.updateCheckInterval }
        set { self.updaterController.updater.updateCheckInterval = newValue }
    }

    func checkForUpdates() {
        self.updaterController.checkForUpdates(nil)
    }

    func observeChanges(_ handler: @escaping () -> Void) {
        self.changeHandler = handler

        self.observations = [
            self.updaterController.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] _, _ in
                Task { @MainActor in
                    self?.notifyChange()
                }
            },
            self.updaterController.updater.observe(\.lastUpdateCheckDate, options: [.initial, .new]) { [weak self] _, _ in
                Task { @MainActor in
                    self?.notifyChange()
                }
            }
        ]
    }

    private func notifyChange() {
        self.changeHandler?()
    }
}
