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

    private var escapeMonitor: Any?
    private var clickOutsideMonitor: Any?

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
        if self.panel == nil {
            self.createPanel()
        }

        guard let panel = self.panel else {
            self.logger.error("Failed to create panel")
            return
        }

        // Cancel any pending auto-dismiss
        self.autoDismissTask?.cancel()
        self.autoDismissTask = nil

        // Position and show
        self.positionPanel()
        panel.makeKeyAndOrderFront(nil)

        // Animate in
        panel.alphaValue = 0
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            panel.animator().alphaValue = 1
        }

        // Add dismiss monitors
        self.addDismissMonitors()

        self.logger.debug("Overlay shown")
    }

    /// Hide the overlay window
    func hide(animated: Bool = true) {
        guard let panel = self.panel else { return }

        self.autoDismissTask?.cancel()
        self.autoDismissTask = nil

        // Remove dismiss monitors
        self.removeDismissMonitors()

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

    // MARK: - Dismiss Monitors

    private func addDismissMonitors() {
        // Escape key monitor (local - when our panel has focus)
        self.escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { // Escape key
                self?.hide()
                return nil // Consume the event
            }
            return event
        }

        // Click outside monitor (global - clicks anywhere)
        self.clickOutsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self = self, let panel = self.panel, panel.isVisible else { return }

            // Check if click is outside our panel
            let clickLocation = event.locationInWindow
            let screenLocation = NSEvent.mouseLocation

            // Convert panel frame to screen coordinates
            let panelFrame = panel.frame

            if !panelFrame.contains(screenLocation) {
                Task { @MainActor in
                    self.hide()
                }
            }
        }
    }

    private func removeDismissMonitors() {
        if let monitor = self.escapeMonitor {
            NSEvent.removeMonitor(monitor)
            self.escapeMonitor = nil
        }

        if let monitor = self.clickOutsideMonitor {
            NSEvent.removeMonitor(monitor)
            self.clickOutsideMonitor = nil
        }
    }
}

// MARK: - Notifications

extension Notification.Name {
    /// Posted when a tool proposal is confirmed by the user
    static let proposalConfirmed = Notification.Name("proposalConfirmed")

    /// Posted when a tool proposal is denied by the user
    static let proposalDenied = Notification.Name("proposalDenied")
}
