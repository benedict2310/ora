//
//  PreferencesCoordinator.swift
//  Ora
//
//  Manages preferences window state
//

import Foundation
import SwiftUI
import os

@MainActor
final class PreferencesCoordinator: ObservableObject {

    // MARK: - Singleton

    static let shared = PreferencesCoordinator()

    // MARK: - Properties

    private let logger = Logger.ora(category: "Preferences")
    private var window: NSWindow?

    // MARK: - Published State

    @Published var selectedTab: PreferencesTab = .general

    // MARK: - Initialization

    private init() {}

    // MARK: - Public API

    func showPreferences() {
        if let window = self.window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        // Create window
        let contentView = PreferencesWindow()
            .environmentObject(self)

        let hostingController = NSHostingController(rootView: contentView)

        let newWindow = NSWindow(contentViewController: hostingController)
        newWindow.title = "Ora Preferences"
        newWindow.styleMask = [.titled, .closable]
        newWindow.setContentSize(NSSize(width: 550, height: 450))
        newWindow.center()
        newWindow.isReleasedWhenClosed = false

        // Track window closing
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: newWindow,
            queue: .main
        ) { [weak self] _ in
            self?.window = nil
        }

        newWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        self.window = newWindow

        self.logger.debug("Preferences window opened")
    }

    func closePreferences() {
        self.window?.close()
    }

    func selectTab(_ tab: PreferencesTab) {
        self.selectedTab = tab
        self.showPreferences()
    }
}

// MARK: - Tab Enum

enum PreferencesTab: String, CaseIterable {
    case general
    case providers
    case models
    case memory
    case permissions
    case about

    var title: String {
        switch self {
        case .general: return "General"
        case .providers: return "Providers"
        case .models: return "Models"
        case .memory: return "Memory"
        case .permissions: return "Permissions"
        case .about: return "About"
        }
    }

    var icon: String {
        switch self {
        case .general: return "gear"
        case .providers: return "icloud"
        case .models: return "cpu"
        case .memory: return "brain"
        case .permissions: return "lock.shield"
        case .about: return "info.circle"
        }
    }
}
