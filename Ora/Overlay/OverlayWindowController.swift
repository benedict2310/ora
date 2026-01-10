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
    private var currentSessionID: UUID = UUID()
    private let panelSize = NSSize(width: 560, height: 380)

    private var escapeMonitor: Any?
    private var appDeactivationObserver: NSObjectProtocol?
    private var permissionPromptEndObserver: NSObjectProtocol?

    /// Default cancel action (override in tests)
    var cancelHandler: (() -> Void) = {
        SimplePipelineController.shared.cancel()
    }

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

        // Invalidate any pending hide operations
        self.currentSessionID = UUID()

        // Position the panel
        self.positionPanel()
        
        // Show the window - set alpha directly to ensure visibility
        // Note: NSAnimationContext.runAnimationGroup was unreliable in Release builds
        // Reset alpha to 1 in case it was animating to 0
        panel.alphaValue = 1
        panel.makeKeyAndOrderFront(nil)
        
        // Ensure app is active to receive input (required for accessory apps)
        NSApp.activate(ignoringOtherApps: true)

        // Add dismiss monitors
        self.addDismissMonitors()

        self.logger.debug("Overlay shown")
    }

    /// Hide the overlay window
    func hide(animated: Bool = true) {
        guard let panel = self.panel else { return }

        // Remove dismiss monitors
        self.removeDismissMonitors()
        
        let hideSessionID = self.currentSessionID

        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                panel.animator().alphaValue = 0
            } completionHandler: {
                Task { @MainActor [weak self] in
                    // Only hide if we haven't started a new show session
                    guard let self = self, self.currentSessionID == hideSessionID else { return }
                    panel.orderOut(nil)
                    self.viewModel.reset()
                }
            }
        } else {
            // Only hide if we haven't started a new show session
            guard self.currentSessionID == hideSessionID else { return }
            panel.orderOut(nil)
            self.viewModel.reset()
        }

        self.logger.debug("Overlay hidden")
    }

    // MARK: - Private

    private func createPanel() {
        let contentView = OverlayView()
            .environmentObject(self.viewModel)

        let hostingView = NSHostingView(rootView: contentView)
        hostingView.setFrameSize(self.panelSize)

        // Create floating panel
        let panel = OverlayPanel(
            contentRect: NSRect(origin: .zero, size: self.panelSize),
            styleMask: [.borderless],
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
        // We want it to become key immediately when shown
        panel.becomesKeyOnlyIfNeeded = false

        self.panel = panel
        self.logger.debug("Overlay panel created")
    }

    private func positionPanel() {
        guard let panel = self.panel, let screen = NSScreen.main else { return }

        // Position in upper-center of screen
        let screenFrame = screen.visibleFrame
        let panelSize = panel.frame.size

        let x = screenFrame.midX - (panelSize.width / 2)
        let y = screenFrame.maxY - panelSize.height - 10 // 10pt from top

        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    // MARK: - Dismiss Monitors

    private func addDismissMonitors() {
        guard self.escapeMonitor == nil else { return }

        // Local keyboard monitor (when our panel has focus)
        self.escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return event }
            
            if event.keyCode == 53 { // Escape key
                // Cancel the pipeline session (which will hide the overlay)
                SimplePipelineController.shared.cancel()
                return nil // Consume the event
            }
            
            if event.keyCode == 36 { // Enter key
                // Check state and decide action
                switch self.viewModel.mode {
                case .listening:
                    // Stop recording and submit
                    SimplePipelineController.shared.submitTranscript()
                    return nil
                    
                case .awaitingFollowUp:
                    // Start follow-up recording
                    SimplePipelineController.shared.startFollowUp()
                    return nil
                    
                case .thinking, .responding:
                    // Ignore Enter during processing
                    return nil
                    
                default:
                    // Let other cases pass through (e.g. confirming proposals)
                    break
                }
            }
            
            return event
        }

        self.appDeactivationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleAppDeactivated()
        }

        self.permissionPromptEndObserver = NotificationCenter.default.addObserver(
            forName: .permissionPromptDidEnd,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handlePermissionPromptEnded()
        }
    }

    private func removeDismissMonitors() {
        if let monitor = self.escapeMonitor {
            NSEvent.removeMonitor(monitor)
            self.escapeMonitor = nil
        }

        if let observer = self.appDeactivationObserver {
            NotificationCenter.default.removeObserver(observer)
            self.appDeactivationObserver = nil
        }

        if let observer = self.permissionPromptEndObserver {
            NotificationCenter.default.removeObserver(observer)
            self.permissionPromptEndObserver = nil
        }
    }

    private func handleAppDeactivated() {
        guard self.isVisible else { return }
        guard !PermissionPromptTracker.shared.isPromptActive else {
            self.logger.debug("App deactivated during permission prompt; keeping overlay")
            return
        }
        guard !ExternalFocusTracker.shared.isExternalOperationActive else {
            self.logger.debug("App deactivated during external focus operation; keeping overlay")
            return
        }

        self.logger.info("App deactivated; cancelling session")
        self.cancelHandler()
    }

    private func handlePermissionPromptEnded() {
        guard SimplePipelineController.shared.isSessionActive else { return }
        self.logger.debug("Permission prompt ended; restoring overlay focus")
        self.show()
    }
}

// MARK: - Notifications

extension Notification.Name {
    /// Posted when a tool proposal is confirmed by the user
    static let proposalConfirmed = Notification.Name("proposalConfirmed")

    /// Posted when a tool proposal is denied by the user
    static let proposalDenied = Notification.Name("proposalDenied")
}

// MARK: - Overlay Panel Subclass

private class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool {
        return true
    }
}
