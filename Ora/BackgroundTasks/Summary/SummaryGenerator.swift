//
//  SummaryGenerator.swift
//  Ora
//
//  Background summary job queue using the local LLM runtime.
//

import Foundation
import os

/// Generates markdown summaries from stored research artifacts using the local LLM.
///
/// Summary jobs run only when the foreground pipeline is idle. If the foreground
/// becomes active during generation, the job is cancelled and requeued (up to
/// `maxRequeueAttempts` times). After exhausting retries or on LLM failure,
/// an extractive fallback summary is written instead.
actor SummaryGenerator {

    // MARK: - Constants

    static let maxRequeueAttempts = 3
    static let maxLLMFailures = 3
    static let minimumIdleWindowSeconds: TimeInterval = 5
    static let extractiveFallbackCharsPerPage = 500
    static let extractiveFallbackMaxPages = 5

    // MARK: - Types

    struct PendingJob: Sendable {
        let taskID: UUID
        var requeueCount: Int
        var llmFailureCount: Int
    }

    // MARK: - Dependencies

    private let llmService: any LLMServicing
    private let artifactStore: ArtifactStore
    private let taskManagerProvider: @Sendable () async -> BackgroundTaskManager?
    private let logger = Logger.ora(category: "summary")

    // MARK: - State

    private var pendingJobs: [PendingJob] = []
    private var currentTask: Task<Void, Never>?
    private var isRunning = false
    private var lastIdleTimestamp: Date?
    private var foregroundObservers: [Any] = []

    // MARK: - Init

    init(
        llmService: any LLMServicing = LLMService.shared,
        artifactStore: ArtifactStore = .shared,
        taskManagerProvider: @escaping @Sendable () async -> BackgroundTaskManager? = {
            await BackgroundTaskManager.resolveShared()
        }
    ) {
        self.llmService = llmService
        self.artifactStore = artifactStore
        self.taskManagerProvider = taskManagerProvider
    }

    // MARK: - Public API

    func enqueueSummary(taskID: UUID) {
        // Avoid duplicates
        guard !self.pendingJobs.contains(where: { $0.taskID == taskID }) else {
            return
        }

        self.logger.info("Enqueued summary job for task \(taskID.uuidString)")
        self.pendingJobs.append(PendingJob(taskID: taskID, requeueCount: 0, llmFailureCount: 0))
        self.scheduleNextIfIdle()
    }

    func start() {
        guard !self.isRunning else {
            return
        }
        self.isRunning = true
        self.lastIdleTimestamp = Date()

        let startedObserver = NotificationCenter.default.addObserver(
            forName: .oraForegroundWorkStarted,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            Task {
                await self.handleForegroundStarted()
            }
        }

        let idleObserver = NotificationCenter.default.addObserver(
            forName: .oraForegroundWorkIdle,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            Task {
                await self.handleForegroundIdle()
            }
        }

        self.foregroundObservers = [startedObserver, idleObserver]
        self.logger.info("SummaryGenerator started")
    }

    func stop() {
        self.isRunning = false
        self.currentTask?.cancel()
        self.currentTask = nil

        for observer in self.foregroundObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        self.foregroundObservers = []
        self.logger.info("SummaryGenerator stopped")
    }

    /// Visible for testing: current pending job count.
    var pendingJobCount: Int {
        self.pendingJobs.count
    }

    // MARK: - Foreground Activity Handling

    private func handleForegroundStarted() {
        self.lastIdleTimestamp = nil

        // Cancel running summary generation
        if let task = self.currentTask {
            self.logger.info("Foreground active - cancelling current summary job")
            task.cancel()
            self.currentTask = nil
        }
    }

    private func handleForegroundIdle() {
        self.lastIdleTimestamp = Date()
        self.scheduleNextIfIdle()
    }

    // MARK: - Scheduling

    private func scheduleNextIfIdle() {
        guard self.isRunning,
              self.currentTask == nil,
              !self.pendingJobs.isEmpty else {
            return
        }

        self.currentTask = Task { [weak self] in
            guard let self else { return }

            // Wait for minimum idle window
            do {
                try await Task.sleep(for: .seconds(Self.minimumIdleWindowSeconds))
            } catch {
                return
            }

            guard !Task.isCancelled else {
                return
            }

            // Verify we're still idle
            guard await self.isStillIdle() else {
                return
            }

            await self.processNextJob()
        }
    }

    private func isStillIdle() -> Bool {
        guard let lastIdle = self.lastIdleTimestamp else {
            return false
        }
        return Date().timeIntervalSince(lastIdle) >= Self.minimumIdleWindowSeconds
    }

    // MARK: - Job Processing

    private func processNextJob() {
        guard !self.pendingJobs.isEmpty else {
            self.currentTask = nil
            return
        }

        let job = self.pendingJobs.removeFirst()

        self.currentTask = Task { [weak self] in
            guard let self else { return }
            await self.executeJob(job)
            await self.onJobFinished()
        }
    }

    private func onJobFinished() {
        self.currentTask = nil
        self.scheduleNextIfIdle()
    }

    private func executeJob(_ job: PendingJob) async {
        do {
            // Load artifact
            let artifact = try await self.artifactStore.read(taskID: job.taskID)
            let pages = artifact.result.pages

            guard !pages.isEmpty else {
                self.logger.warning("No pages for task \(job.taskID.uuidString), writing fallback")
                let fallback = Self.buildExtractiveFallback(pages: pages)
                try await self.writeSummary(fallback, taskID: job.taskID, artifactPath: artifact.manifest.artifactPath)
                await self.updateSummaryState(taskID: job.taskID, state: .completed)
                return
            }

            // Sanitize content
            let sanitizer = SummaryContentSanitizer()
            let sanitizablePages = pages.map { page in
                SanitizablePageInput(
                    url: page.url,
                    title: page.title,
                    extractedText: page.extractedText
                )
            }
            let sanitizedPages = sanitizer.sanitize(pages: sanitizablePages)

            guard !sanitizedPages.isEmpty else {
                self.logger.warning("All pages empty after sanitization for task \(job.taskID.uuidString)")
                let fallback = Self.buildExtractiveFallback(pages: pages)
                try await self.writeSummary(fallback, taskID: job.taskID, artifactPath: artifact.manifest.artifactPath)
                await self.updateSummaryState(taskID: job.taskID, state: .completed)
                return
            }

            // Build prompt and generate
            let prompt = SummaryPrompt.build(
                sanitizedPages: sanitizedPages,
                label: artifact.result.label
            )

            let summaryText: String
            do {
                summaryText = try await self.llmService.generateOneShot(prompt: prompt, maxTokens: 800)
            } catch is CancellationError {
                // Requeue on foreground interruption
                await self.handleInterruption(job: job, pages: pages, artifactPath: artifact.manifest.artifactPath)
                return
            } catch {
                // LLM failure
                await self.handleLLMFailure(job: job, error: error, pages: pages, artifactPath: artifact.manifest.artifactPath)
                return
            }

            guard !Task.isCancelled else {
                await self.handleInterruption(job: job, pages: pages, artifactPath: artifact.manifest.artifactPath)
                return
            }

            // Write summary
            let markdown = self.formatSummaryMarkdown(
                text: summaryText,
                label: artifact.result.label,
                pages: pages
            )
            try await self.writeSummary(markdown, taskID: job.taskID, artifactPath: artifact.manifest.artifactPath)
            await self.updateSummaryState(taskID: job.taskID, state: .completed)
            self.logger.info("Summary generated for task \(job.taskID.uuidString)")

        } catch {
            self.logger.error("Summary generation failed for task \(job.taskID.uuidString): \(error.localizedDescription)")
            await self.updateSummaryState(taskID: job.taskID, state: .failed)
        }
    }

    // MARK: - Interruption & Failure Handling

    private func handleInterruption(job: PendingJob, pages: [ArtifactStoredPage], artifactPath: String) async {
        var updatedJob = job
        updatedJob.requeueCount += 1

        if updatedJob.requeueCount >= Self.maxRequeueAttempts {
            self.logger.info("Max requeue attempts reached for task \(job.taskID.uuidString), writing extractive fallback")
            let fallback = Self.buildExtractiveFallback(pages: pages)
            do {
                try await self.writeSummary(fallback, taskID: job.taskID, artifactPath: artifactPath)
                await self.updateSummaryState(taskID: job.taskID, state: .completed)
            } catch {
                self.logger.error("Failed to write extractive fallback: \(error.localizedDescription)")
                await self.updateSummaryState(taskID: job.taskID, state: .failed)
            }
        } else {
            self.logger.info("Requeuing summary job for task \(job.taskID.uuidString) (attempt \(updatedJob.requeueCount))")
            self.pendingJobs.append(updatedJob)
        }
    }

    private func handleLLMFailure(job: PendingJob, error: Error, pages: [ArtifactStoredPage], artifactPath: String) async {
        var updatedJob = job
        updatedJob.llmFailureCount += 1

        self.logger.error("LLM failure for task \(job.taskID.uuidString) (attempt \(updatedJob.llmFailureCount)): \(error.localizedDescription)")

        if updatedJob.llmFailureCount >= Self.maxLLMFailures {
            self.logger.info("Max LLM failures for task \(job.taskID.uuidString), writing extractive fallback")
            let fallback = Self.buildExtractiveFallback(pages: pages)
            do {
                try await self.writeSummary(fallback, taskID: job.taskID, artifactPath: artifactPath)
                await self.updateSummaryState(taskID: job.taskID, state: .completed)
            } catch {
                self.logger.error("Failed to write extractive fallback: \(error.localizedDescription)")
                await self.updateSummaryState(taskID: job.taskID, state: .failed)
            }
        } else {
            self.pendingJobs.append(updatedJob)
        }
    }

    // MARK: - Summary Writing

    private func writeSummary(_ content: String, taskID: UUID, artifactPath: String) async throws {
        let directoryURL = URL(fileURLWithPath: artifactPath, isDirectory: true)
        let summaryURL = directoryURL.appendingPathComponent("summary.md")
        try content.write(to: summaryURL, atomically: true, encoding: .utf8)
        self.logger.info("Wrote summary.md for task \(taskID.uuidString)")
    }

    private func formatSummaryMarkdown(
        text: String,
        label: String?,
        pages: [ArtifactStoredPage]
    ) -> String {
        var markdown = ""

        if let label {
            markdown += "# \(label)\n\n"
        }

        markdown += text.trimmingCharacters(in: .whitespacesAndNewlines)

        if !pages.isEmpty {
            markdown += "\n\n---\n\n## Sources\n\n"
            for page in pages {
                let title = page.title ?? page.url
                markdown += "- [\(title)](\(page.url))\n"
            }
        }

        return markdown
    }

    // MARK: - Extractive Fallback

    static func buildExtractiveFallback(pages: [ArtifactStoredPage]) -> String {
        let limitedPages = Array(pages.prefix(Self.extractiveFallbackMaxPages))
        var sections: [String] = []

        for page in limitedPages {
            let title = page.title ?? "Untitled"
            let excerpt = String(page.extractedText.prefix(Self.extractiveFallbackCharsPerPage))

            var section = "## \(title)\n\(excerpt)"
            section += "\n\nSource: \(page.url)"
            sections.append(section)
        }

        return sections.joined(separator: "\n\n---\n\n")
    }

    // MARK: - Task State Updates

    private func updateSummaryState(taskID: UUID, state: BackgroundTaskSummaryState) async {
        guard let manager = await self.taskManagerProvider() else {
            self.logger.error("BackgroundTaskManager not available for summary state update")
            return
        }
        await manager.updateSummaryState(taskID: taskID, state: state)
    }
}
