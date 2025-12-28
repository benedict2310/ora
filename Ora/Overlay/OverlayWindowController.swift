//
//  OverlayWindowController.swift
//  Ora
//
//  Manages the floating overlay window
//

import AppKit
import SwiftUI
import os

@MainActor
final class OverlayWindowController {

    // MARK: - Singleton

    static let shared = OverlayWindowController()

    // MARK: - Properties

    private let logger = Logger(subsystem: "com.ora.app", category: "OverlayWindow")
    private var panel: NSPanel?
    private let viewModel = OverlayViewModel()

    private var autoDismissTask: Task<Void, Never>?
    private let autoDismissDelay: TimeInterval = 3.0

    /// Current overlay mode
    var mode: OverlayMode {
        get { self.viewModel.mode }
        set { self.viewModel.mode = newValue }
    }

    /// View model for external updates
    var model: OverlayViewModel {
        self.viewModel
    }

    /// Whether the overlay is currently visible
    var isVisible: Bool {
        self.panel?.isVisible ?? false
    }

    // MARK: - Initialization

    private init() {}

    // MARK: - Public API

    /// Show the overlay window
    func show() {
        print("DEBUG: OverlayWindowController.show() called")
        if self.panel == nil {
            print("DEBUG: Panel is nil, creating...")
            self.createPanel()
        }

        guard let panel = self.panel else {
            print("DEBUG: FAILED to create panel!")
            self.logger.error("Failed to create panel")
            return
        }
        print("DEBUG: Panel exists, frame = \(NSStringFromRect(panel.frame))")

        // Cancel any pending auto-dismiss
        self.autoDismissTask?.cancel()
        self.autoDismissTask = nil

        // Position and show
        self.positionPanel()
        print("DEBUG: Panel positioned at \(NSStringFromRect(panel.frame))")
        panel.makeKeyAndOrderFront(nil)
        print("DEBUG: makeKeyAndOrderFront called, isVisible = \(panel.isVisible)")

        // Animate in
        panel.alphaValue = 0
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            panel.animator().alphaValue = 1
        }

        print("DEBUG: Animation started, panel.alphaValue = \(panel.alphaValue)")
        self.logger.debug("Overlay shown")
    }

    /// Hide the overlay window
    func hide(animated: Bool = true) {
        guard let panel = self.panel else { return }

        self.autoDismissTask?.cancel()
        self.autoDismissTask = nil

        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                panel.animator().alphaValue = 0
            } completionHandler: {
                Task { @MainActor [weak self] in
                    panel.orderOut(nil)
                    self?.viewModel.reset()
                }
            }
        } else {
            panel.orderOut(nil)
            self.viewModel.reset()
        }

        self.logger.debug("Overlay hidden")
    }

    /// Schedule auto-dismiss after response completes
    func scheduleAutoDismiss() {
        self.autoDismissTask?.cancel()
        self.autoDismissTask = Task {
            try? await Task.sleep(for: .seconds(self.autoDismissDelay))
            guard !Task.isCancelled else { return }
            self.hide()
        }
    }

    /// Cancel scheduled auto-dismiss
    func cancelAutoDismiss() {
        self.autoDismissTask?.cancel()
        self.autoDismissTask = nil
    }

    // MARK: - Private

    private func createPanel() {
        let contentView = OverlayView()
            .environmentObject(self.viewModel)

        let hostingView = NSHostingView(rootView: contentView)
        hostingView.setFrameSize(NSSize(width: 400, height: 300))

        // Create floating panel
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )

        panel.contentView = hostingView
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true

        // Enable key events for keyboard navigation
        panel.becomesKeyOnlyIfNeeded = true

        self.panel = panel
        self.logger.debug("Overlay panel created")
    }

    private func positionPanel() {
        guard let panel = self.panel, let screen = NSScreen.main else { return }

        // Position in upper-center of screen
        let screenFrame = screen.visibleFrame
        let panelSize = panel.frame.size

        let x = screenFrame.midX - (panelSize.width / 2)
        let y = screenFrame.maxY - panelSize.height - 100 // 100pt from top

        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

// MARK: - Notifications

extension Notification.Name {
    /// Posted when a tool proposal is confirmed by the user
    static let proposalConfirmed = Notification.Name("proposalConfirmed")

    /// Posted when a tool proposal is denied by the user
    static let proposalDenied = Notification.Name("proposalDenied")
}
