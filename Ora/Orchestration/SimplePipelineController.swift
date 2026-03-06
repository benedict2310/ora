//
//  SimplePipelineController.swift
//  Ora
//
//  ASR → AgentLoop → TTS pipeline coordinator with tool execution support.
//

import Foundation
import AppKit
import UniformTypeIdentifiers
import os
import Combine

/// Coordinates ASR → AgentLoop → TTS pipeline with tool proposals and execution
///
/// ## State Machine
/// ```
/// idle ──(hotkey press)──► listening ──(submit)──► thinking
///   ▲                          │                       │
///   │                       (cancel)                   ▼
///   │                          │              ┌─── responding ───┐
///   │                          ▼              │                  │
///   └─────────────────────── idle ◄───────────┤   speaking       │
///                              ▲              │       ▼          │
///                              │              └─► awaitingFollowUp
///                              │                       │
///                              │              ┌───────────────────┐
///                              │              │    proposing      │
///                              │              │   (confirm/deny)  │
///                              │              └───────────────────┘
///                              │                       │
///                              │              ┌─── executing ────┐
///                              │              │       ▼          │
///                              └──────────────┤   speaking       │
///                                             └─► awaitingFollowUp
/// ```
@MainActor
final class SimplePipelineController: ObservableObject {
    
    // MARK: - Singleton
    
    static let shared = SimplePipelineController()
    
    // MARK: - Properties
    
    let logger = Logger.ora(category: "Pipeline")
    
    @Published var state: PipelineState = .idle
    @Published var currentTranscript: String = ""
    @Published var currentResponse: String = ""
    
    var sessionTask: Task<Void, Never>?
    var autoDismissTask: Task<Void, Never>?
    var ttsTask: Task<Void, Never>?
    var confirmationTask: Task<Void, Never>?
    let streamingResponseHandler = StreamingResponseHandler()
    
    /// The agent loop for processing requests
    let agentLoop: AgentLoop
    let overlayPresenter: any OverlayPresenting
    let audioService: any AudioServicing
    let ttsService: any TTSServicing
    let persistenceService: any PersistenceServicing
    let attachmentStore: any AttachmentStoring
    let screenshotCaptureService: any ScreenshotCapturing
    let stateMachine = PipelineStateMachine()
    let confirmationHandler: ConfirmationHandler

    /// Silence detector for auto-submit in conversation mode
    var silenceDetector: SilenceDetector?
    var pendingImageAttachments: [StagedImageAttachment] = []
    var sessionImageAttachmentIDs: Set<UUID> = []
    
    /// Delay before auto-recovering from error (seconds)
    let errorRecoveryDelay: TimeInterval = OraConstants.Timing.pipelineErrorRecoveryDelay
    /// Delay before auto-starting follow-up listening (conversation mode)
    let followUpAutoListenDelay: TimeInterval = OraConstants.Timing.pipelineFollowUpAutoListenDelay
    
    /// Whether conversation mode is enabled (combines silence detection + auto-listen)
    var isConversationModeEnabled: Bool {
        return self.fetchConversationModeSetting()
    }

    /// Whether there is an active conversation session
    var isSessionActive: Bool {
        Self.isSessionActive(for: self.state)
    }

    var isStreamingResponse: Bool {
        return self.streamingResponseHandler.isStreaming
    }

    // MARK: - Initialization
    
    init(
        agentLoop: AgentLoop = AgentLoop(),
        overlayPresenter: any OverlayPresenting = OverlayWindowController.shared,
        audioService: any AudioServicing = AudioService.shared,
        ttsService: any TTSServicing = TTSService.shared,
        persistenceService: any PersistenceServicing = PersistenceManager.shared,
        attachmentStore: any AttachmentStoring = AttachmentStore.shared,
        screenshotCaptureService: any ScreenshotCapturing = ScreenshotCaptureService.shared
    ) {
        self.agentLoop = agentLoop
        self.overlayPresenter = overlayPresenter
        self.audioService = audioService
        self.ttsService = ttsService
        self.persistenceService = persistenceService
        self.attachmentStore = attachmentStore
        self.screenshotCaptureService = screenshotCaptureService
        self.confirmationHandler = ConfirmationHandler()
        self.confirmationHandler.onConfirmProposal = { [weak self] in
            self?.handleProposalConfirmed()
        }
        self.confirmationHandler.onConfirmAndTrustProposal = { [weak self] in
            self?.handleProposalConfirmedAndTrust()
        }
        self.confirmationHandler.onDenyProposal = { [weak self] in
            self?.handleProposalDenied()
        }
        self.confirmationHandler.onStopSpeaking = { [weak self] in
            self?.interruptSpeech()
        }
        self.confirmationHandler.onPasteImageAttachment = { [weak self] in
            self?.pasteImageAttachment()
        }
        self.confirmationHandler.onChooseImageAttachmentFile = { [weak self] in
            self?.chooseImageAttachmentFile()
        }
        self.confirmationHandler.onCaptureScreenshotAttachment = { [weak self] in
            self?.captureScreenshotAttachment()
        }
        self.confirmationHandler.onRemovePendingImageAttachment = { [weak self] id in
            self?.removePendingImageAttachment(id)
        }
        self.confirmationHandler.onClearPendingImageAttachments = { [weak self] in
            self?.clearPendingImageAttachments()
        }
        self.confirmationHandler.onOpenScreenRecordingSettings = { [weak self] in
            self?.openScreenRecordingSettings()
        }
        self.overlayPresenter.model.actionHandler = self.confirmationHandler
        Task { @MainActor in
            self.agentLoop.setDelegate(self)
        }
    }
    
    func fetchConversationModeSetting() -> Bool {
        return self.persistenceService.settings.conversationModeEnabled
    }
    
    /// Create a test instance with injectable agent loop
    static func makeTestInstance(
        agentLoop: AgentLoop? = nil,
        overlayPresenter: (any OverlayPresenting)? = nil,
        audioService: (any AudioServicing)? = nil,
        ttsService: (any TTSServicing)? = nil,
        persistenceService: (any PersistenceServicing)? = nil,
        attachmentStore: (any AttachmentStoring)? = nil,
        screenshotCaptureService: (any ScreenshotCapturing)? = nil
    ) -> SimplePipelineController {
        return SimplePipelineController(
            agentLoop: agentLoop ?? AgentLoop(),
            overlayPresenter: overlayPresenter ?? OverlayWindowController.shared,
            audioService: audioService ?? AudioService.shared,
            ttsService: ttsService ?? TTSService.shared,
            persistenceService: persistenceService ?? PersistenceManager.shared,
            attachmentStore: attachmentStore ?? AttachmentStore.shared,
            screenshotCaptureService: screenshotCaptureService ?? ScreenshotCaptureService.shared
        )
    }
    
    // MARK: - Public API
    
    /// Start listening or toggle (hotkey pressed)
    func startListening() {
        // If overlay is visible and we are in a session, pressing hotkey should cancel
        if self.overlayPresenter.isVisible {
            self.logger.info("Hotkey pressed while overlay visible - cancelling")
            self.cancel()
            return
        }
        
        // Cancel any pending auto-dismiss (legacy check)
        self.autoDismissTask?.cancel()
        self.autoDismissTask = nil
        
        // Cancel any existing session
        self.sessionTask?.cancel()
        
        // Reset state for new session
        self.currentTranscript = ""
        self.currentResponse = ""
        self.resetStreamingResponse()
        
        // Reset overlay for new session
        self.logger.info("Resetting overlay for new session")
        self.clearPendingImageAttachmentsState()
        self.overlayPresenter.model.reset()
        self.refreshSkillsHint()
        
        self.transition(to: .listening)

        // Show overlay in listening mode with activity
        self.overlayPresenter.mode = .listening
        self.setOverlayActivity(.listening)
        self.overlayPresenter.show()
        
        // Start the session task
        self.sessionTask = Task {
            // Initialize agent session (with tool definitions)
            await self.agentLoop.startSession()
            await self.runListeningSession()
        }
        
        self.logger.info("Started listening")
    }
    
    /// Submit transcript manually (Enter key) or via silence detection
    func submitTranscript() {
        guard self.state == .listening else {
            self.logger.warning("Cannot submit transcript in state: \(self.state.description)")
            return
        }

        self.logger.debug("Submitting transcript")

        // Cancel silence detector to prevent double-submit (AC-9)
        self.silenceDetector?.cancel()

        // Stop audio capture - this will cause the ASR stream to finalize
        Task {
            await self.audioService.stop()
        }
    }
    
    /// Start follow-up recording (from awaiting follow-up)
    func startFollowUp() {
        guard self.state == .awaitingFollowUp else {
            self.logger.warning("Cannot start follow-up in state: \(self.state.description)")
            return
        }
        
        self.logger.info("Starting follow-up")

        self.transition(to: .listening)
        self.overlayPresenter.mode = .listening
        self.setOverlayActivity(.listening)
        
        // Reset current transcript for new turn
        self.currentTranscript = ""
        
        // Start listening again (keeping conversation history via agent loop session)
        self.sessionTask = Task {
            await self.runListeningSession()
        }
    }
    
    /// Stop listening (Legacy/Unused for tap-to-talk)
    func stopListening() {
        // No-op for tap-to-talk flow
    }
    
    /// Cancel current operation and return to idle (AC-10)
    func cancel() {
        self.logger.info("Cancelling current operation from state: \(self.state.description)")
        self.clearPendingImageAttachments()

        // Cancel silence detector
        self.silenceDetector?.cancel()
        self.silenceDetector = nil

        // Cancel all tasks
        self.sessionTask?.cancel()
        self.sessionTask = nil
        self.autoDismissTask?.cancel()
        self.autoDismissTask = nil
        self.ttsTask?.cancel()
        self.ttsTask = nil
        self.confirmationTask?.cancel()
        self.confirmationTask = nil
        self.resetStreamingResponse()

        // Stop audio capture and TTS playback
        Task {
            await self.ttsService.stop()
            await AudioPlaybackService.shared.stop()
            await self.audioService.cancel()
            await self.agentLoop.endSession()
            await self.agentLoop.clearPendingAuthorization()
        }

        self.transition(to: .idle)
        self.setOverlayActivity(.none)
        self.overlayPresenter.hide(animated: true)
        self.clearSessionImageAttachments()
    }

    private func refreshSkillsHint() {
        Task { @MainActor in
            let hintText: String?
            if await SkillsFeatureGate.isEnabled() {
                let skills = await SkillStore.shared.list()
                hintText = OverlayLayout.skillsHintText(for: skills)
            } else {
                hintText = nil
            }

            self.overlayPresenter.model.skillsHintText = hintText
        }
    }

    /// Stop speaking without closing the overlay
    func interruptSpeech() {
        guard self.state == .speaking else {
            self.logger.debug("Ignoring interruptSpeech in state: \(self.state.description)")
            return
        }

        self.logger.info("Interrupting TTS playback")

        self.ttsTask?.cancel()
        self.ttsTask = nil

        Task {
            await self.ttsService.stop()
            await AudioPlaybackService.shared.stop()
        }

        self.transitionToAwaitingFollowUp(autoListen: self.isConversationModeEnabled)
    }

    // MARK: - Attachment Actions

    func pasteImageAttachment() {
        guard let payload = self.clipboardImagePayload() else {
            self.overlayPresenter.model.showAttachmentNotice(
                OverlayAttachmentNotice(message: "No image found in the clipboard.")
            )
            return
        }

        Task { @MainActor in
            do {
                let attachment = try await self.attachmentStore.stageImageData(
                    payload,
                    source: .clipboard,
                    originalFilename: nil
                )
                self.pendingImageAttachments.append(attachment)
                self.syncPendingAttachmentsToOverlay()
                self.overlayPresenter.model.clearAttachmentNotice()
            } catch {
                self.logger.error("Failed to stage clipboard image: \(error.localizedDescription)")
                self.overlayPresenter.model.showAttachmentNotice(
                    OverlayAttachmentNotice(message: "Ora could not attach that clipboard image.")
                )
            }
        }
    }

    func chooseImageAttachmentFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.image]
        panel.prompt = "Attach"

        guard panel.runModal() == .OK, let selectedURL = panel.url else {
            return
        }

        Task { @MainActor in
            do {
                let attachment = try await self.attachmentStore.stageImageFile(at: selectedURL)
                self.pendingImageAttachments.append(attachment)
                self.syncPendingAttachmentsToOverlay()
                self.overlayPresenter.model.clearAttachmentNotice()
            } catch {
                self.logger.error("Failed to stage imported image: \(error.localizedDescription)")
                self.overlayPresenter.model.showAttachmentNotice(
                    OverlayAttachmentNotice(message: "Ora could not attach that image file.")
                )
            }
        }
    }

    func captureScreenshotAttachment() {
        Task { @MainActor in
            ExternalFocusTracker.shared.beginExternalOperation()
            defer {
                ExternalFocusTracker.shared.endExternalOperation()
            }

            do {
                let screenshotData = try await self.screenshotCaptureService.captureScreenshotPNG()
                let attachment = try await self.attachmentStore.stageImageData(
                    screenshotData,
                    source: .screenshot,
                    originalFilename: nil
                )
                self.pendingImageAttachments.append(attachment)
                self.syncPendingAttachmentsToOverlay()
                self.overlayPresenter.model.clearAttachmentNotice()
            } catch let screenshotError as ScreenshotCaptureError {
                self.handleScreenshotCaptureError(screenshotError)
            } catch {
                self.logger.error("Screenshot attachment failed: \(error.localizedDescription)")
                self.overlayPresenter.model.showAttachmentNotice(
                    OverlayAttachmentNotice(message: "Ora could not capture a screenshot right now.")
                )
            }
        }
    }

    func removePendingImageAttachment(_ id: UUID) {
        self.pendingImageAttachments.removeAll { $0.id == id }
        self.syncPendingAttachmentsToOverlay()

        Task {
            await self.attachmentStore.removeAttachment(id: id)
        }
    }

    func clearPendingImageAttachments() {
        let ids = self.pendingImageAttachments.map(\.id)
        self.clearPendingImageAttachmentsState()

        Task {
            await self.attachmentStore.removeAttachments(ids: ids)
        }
    }

    func openScreenRecordingSettings() {
        Task { @MainActor in
            ExternalFocusTracker.shared.beginExternalOperation()
            self.screenshotCaptureService.openScreenRecordingSettings()
            try? await Task.sleep(for: .milliseconds(500))
            ExternalFocusTracker.shared.endExternalOperation()
        }
    }

    func clearPendingImageAttachmentsState() {
        self.pendingImageAttachments.removeAll()
        self.syncPendingAttachmentsToOverlay()
        self.overlayPresenter.model.clearAttachmentNotice()
    }

    func clearSessionImageAttachments() {
        let attachmentIDs = Array(self.sessionImageAttachmentIDs)
        self.sessionImageAttachmentIDs.removeAll()

        Task {
            await self.attachmentStore.removeAttachments(ids: attachmentIDs)
        }
    }

    func consumePendingImageAttachmentsForTurn() -> [StagedImageAttachment] {
        let attachments = self.pendingImageAttachments
        self.clearPendingImageAttachmentsState()
        return attachments
    }

    func syncPendingAttachmentsToOverlay() {
        self.overlayPresenter.model.setPendingImageAttachments(self.pendingImageAttachments)
    }

    func setPendingImageAttachmentsForTesting(_ attachments: [StagedImageAttachment]) {
        self.pendingImageAttachments = attachments
        self.syncPendingAttachmentsToOverlay()
    }

    // MARK: - Private

    private func clipboardImagePayload() -> Data? {
        let pasteboard = NSPasteboard.general

        if let pngData = pasteboard.data(forType: .png) {
            return pngData
        }

        if let image = pasteboard.readObjects(forClasses: [NSImage.self], options: nil)?.first as? NSImage,
           let tiffData = image.tiffRepresentation,
           let bitmap = NSBitmapImageRep(data: tiffData),
           let pngData = bitmap.representation(using: .png, properties: [:]) {
            return pngData
        }

        return nil
    }

    private func handleScreenshotCaptureError(_ error: ScreenshotCaptureError) {
        switch error {
        case .permissionDenied:
            self.overlayPresenter.model.showAttachmentNotice(
                OverlayAttachmentNotice(
                    message: "Screenshot access is denied. You can still paste or choose an image file.",
                    offersOpenSettings: true
                )
            )
        case .noDisplayAvailable:
            self.overlayPresenter.model.showAttachmentNotice(
                OverlayAttachmentNotice(message: "Ora could not find a display to capture.")
            )
        case .captureFailed, .encodingFailed:
            self.overlayPresenter.model.showAttachmentNotice(
                OverlayAttachmentNotice(message: "Ora could not capture a screenshot right now.")
            )
        }
    }

}
