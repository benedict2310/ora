//
//  UpdateController.swift
//  Ora
//
//  Sparkle update controller wrapper
//

import Foundation
import Sparkle
import os
import Security

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

    // MARK: - Eligibility

    typealias UpdateEligibilityProvider = @MainActor () -> UpdateEligibility

    struct UpdateEligibility: Equatable {
        let isEligible: Bool
        let reason: String?
        let teamIdentifier: String?

        static func eligible(teamIdentifier: String?) -> UpdateEligibility {
            return UpdateEligibility(isEligible: true, reason: nil, teamIdentifier: teamIdentifier)
        }

        static func ineligible(reason: String, teamIdentifier: String?) -> UpdateEligibility {
            return UpdateEligibility(isEligible: false, reason: reason, teamIdentifier: teamIdentifier)
        }
    }

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
    private let eligibilityProvider: UpdateEligibilityProvider
    private var isApplyingUpdaterState = false

    // MARK: - Initialization

    init(
        updater: UpdateDriver = SparkleUpdateDriver(),
        eligibilityProvider: @escaping UpdateEligibilityProvider = UpdateController.defaultEligibilityProvider
    ) {
        self.updater = updater
        self.eligibilityProvider = eligibilityProvider
        self.refreshFromUpdater()
        self.updater.observeChanges { [weak self] in
            guard let self else { return }
            self.refreshFromUpdater()
        }
    }

    // MARK: - UpdateChecking

    func checkForUpdates() {
        let eligibility = self.eligibilityProvider()
        guard eligibility.isEligible else {
            let reason = eligibility.reason ?? "Unknown"
            self.logger.error("UPDATE_CHECK_BLOCKED reason=\(reason, privacy: .public) teamId=\(eligibility.teamIdentifier ?? "nil", privacy: .public)")
            return
        }

        self.logger.info("User initiated update check teamId=\(eligibility.teamIdentifier ?? "nil", privacy: .public)")
        self.updater.checkForUpdates()
    }

    // MARK: - Private

    private func refreshFromUpdater() {
        self.isApplyingUpdaterState = true
        let eligibility = self.eligibilityProvider()
        if !eligibility.isEligible, let reason = eligibility.reason {
            self.logger.info("Update checks disabled: \(reason, privacy: .public)")
        }
        self.canCheckForUpdates = eligibility.isEligible && self.updater.canCheckForUpdates
        self.lastUpdateCheck = self.updater.lastUpdateCheckDate
        self.automaticallyChecksForUpdates = self.updater.automaticallyChecksForUpdates
        self.updateCheckInterval = UpdateCheckInterval.nearest(to: self.updater.updateCheckInterval)
        self.isApplyingUpdaterState = false
    }

    private static func defaultEligibilityProvider() -> UpdateEligibility {
        // Sparkle's Autoupdate enforces an XPC code-signing requirement based on Team ID.
        // Ad-hoc/dev builds (TeamIdentifier == nil) will hit an update install failure.
        let bundlePath = Bundle.main.bundleURL.path
        if bundlePath.contains("/build/Build/Products/") {
            return .ineligible(reason: "Running from a build product; Sparkle updates are disabled for development builds.", teamIdentifier: Self.currentTeamIdentifier())
        }

        guard let teamId = Self.currentTeamIdentifier() else {
            return .ineligible(reason: "App is not Team-signed (ad-hoc); Sparkle updates require a signed release build.", teamIdentifier: nil)
        }

        return .eligible(teamIdentifier: teamId)
    }

    private static func currentTeamIdentifier() -> String? {
        var code: SecCode?
        let copySelfStatus = SecCodeCopySelf(SecCSFlags(), &code)
        guard copySelfStatus == errSecSuccess, let code else { return nil }

        var staticCode: SecStaticCode?
        let staticStatus = SecCodeCopyStaticCode(code, SecCSFlags(), &staticCode)
        guard staticStatus == errSecSuccess, let staticCode else { return nil }

        var info: CFDictionary?
        let status = SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info)
        guard status == errSecSuccess, let dict = info as? [CFString: Any] else { return nil }

        return dict[kSecCodeInfoTeamIdentifier] as? String
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
        // Unit tests run inside the host app and will initialize UpdateController.shared.
        // Starting Sparkle in tests can hang in CI/headless environments due to UI/TCC interactions.
        let isRunningUnitTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        self.updaterController = SPUStandardUpdaterController(
            startingUpdater: !isRunningUnitTests,
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
