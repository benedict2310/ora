//
//  TaskProgressObserver.swift
//  Ora
//
//  Shared UI-facing observer for background task progress.
//

import Combine
import Foundation
import os

enum TaskProgressPhase: Equatable, Sendable {
    case queued(urlCount: Int)
    case fetching(urlCount: Int)
    case summarizing

    var displayText: String {
        switch self {
        case .queued(let urlCount):
            return urlCount == 1 ? "Queued 1 URL" : "Queued \(urlCount) URLs"
        case .fetching(let urlCount):
            return urlCount == 1 ? "Fetching 1 URL" : "Fetching \(urlCount) URLs"
        case .summarizing:
            return "Summarizing"
        }
    }

    var iconName: String {
        switch self {
        case .queued:
            return "clock"
        case .fetching:
            return "arrow.down.circle"
        case .summarizing:
            return "text.alignleft"
        }
    }
}

struct TaskProgressItem: Identifiable, Equatable, Sendable {
    let id: UUID
    let label: String
    let detail: String
    let phase: TaskProgressPhase
    let createdAt: Date

    var menuTitle: String {
        return "\(self.label) - \(self.phase.displayText)"
    }
}

@MainActor
final class TaskProgressObserver: ObservableObject {

    static let shared = TaskProgressObserver()

    @Published private(set) var activeTasks: [TaskProgressItem] = []

    private let logger = Logger.ora(category: "ui")
    private let managerProvider: @MainActor @Sendable () -> BackgroundTaskManager?
    private let menuPresenter: @MainActor @Sendable () -> Void
    private var observationTask: Task<Void, Never>?

    init(
        managerProvider: @escaping @MainActor @Sendable () -> BackgroundTaskManager? = {
            BackgroundTaskManager.resolveShared()
        },
        menuPresenter: @escaping @MainActor @Sendable () -> Void = {
            StatusBarController.shared?.presentMenu()
        }
    ) {
        self.managerProvider = managerProvider
        self.menuPresenter = menuPresenter
        self.startObserving()
    }

    deinit {
        self.observationTask?.cancel()
    }

    var hasActiveTasks: Bool {
        return !self.activeTasks.isEmpty
    }

    var primaryTask: TaskProgressItem? {
        return self.activeTasks.first
    }

    var statusLineText: String {
        guard let primaryTask = self.primaryTask else {
            return ""
        }
        if self.activeTasks.count == 1 {
            return "\(Self.truncatedLabel(primaryTask.label)) - \(primaryTask.phase.displayText)"
        }
        return "\(self.activeTasks.count) tasks running"
    }

    func cancel(taskID: UUID) {
        guard let manager = self.managerProvider() else {
            return
        }
        Task {
            _ = await manager.cancel(taskID: taskID)
        }
    }

    func cancelPrimaryTask() {
        guard let taskID = self.primaryTask?.id else {
            return
        }
        self.cancel(taskID: taskID)
    }

    func openTaskMenu() {
        self.menuPresenter()
    }

    func refreshObservation() {
        self.startObserving()
    }

    private func startObserving() {
        self.observationTask?.cancel()
        let managerProvider = self.managerProvider
        self.observationTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let manager = await MainActor.run(body: { managerProvider() }) else {
                    await MainActor.run {
                        self?.activeTasks = []
                    }
                    try? await Task.sleep(for: .milliseconds(250))
                    continue
                }

                let snapshots = await manager.list(limit: 50)
                await MainActor.run {
                    self?.applySnapshots(snapshots)
                }

                let stream = await manager.observe()
                for await event in stream {
                    guard !Task.isCancelled else {
                        break
                    }
                    await MainActor.run {
                        self?.applySnapshot(event.record)
                    }
                }

                if !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(100))
                }
            }
        }
    }

    private func applySnapshots(_ snapshots: [BackgroundTaskRecordSnapshot]) {
        self.activeTasks = snapshots
            .compactMap(Self.makeItem(from:))
            .sorted { lhs, rhs in
                if lhs.createdAt == rhs.createdAt {
                    return lhs.label < rhs.label
                }
                return lhs.createdAt > rhs.createdAt
            }
    }

    private func applySnapshot(_ snapshot: BackgroundTaskRecordSnapshot) {
        let updatedItem = Self.makeItem(from: snapshot)
        self.activeTasks.removeAll { $0.id == snapshot.id }
        if let updatedItem {
            self.activeTasks.append(updatedItem)
            self.activeTasks.sort { lhs, rhs in
                if lhs.createdAt == rhs.createdAt {
                    return lhs.label < rhs.label
                }
                return lhs.createdAt > rhs.createdAt
            }
        }
        self.logger.debug("Task progress updated (active: \(self.activeTasks.count))")
    }

    private static func makeItem(from snapshot: BackgroundTaskRecordSnapshot) -> TaskProgressItem? {
        guard let phase = Self.phase(for: snapshot) else {
            return nil
        }

        return TaskProgressItem(
            id: snapshot.id,
            label: Self.label(for: snapshot),
            detail: Self.detail(for: snapshot),
            phase: phase,
            createdAt: snapshot.createdAt
        )
    }

    private static func phase(for snapshot: BackgroundTaskRecordSnapshot) -> TaskProgressPhase? {
        switch snapshot.state {
        case .queued:
            return .queued(urlCount: snapshot.inputs.urls.count)
        case .running:
            return .fetching(urlCount: snapshot.inputs.urls.count)
        case .completed where snapshot.summaryState == .pending:
            return .summarizing
        case .completed, .failed, .canceled:
            return nil
        }
    }

    private static func label(for snapshot: BackgroundTaskRecordSnapshot) -> String {
        if let label = snapshot.inputs.label?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty {
            return label
        }

        if let firstURL = snapshot.inputs.urls.first,
           let host = URL(string: firstURL)?.host,
           !host.isEmpty {
            return "Research: \(host)"
        }

        return "Research Task"
    }

    private static func detail(for snapshot: BackgroundTaskRecordSnapshot) -> String {
        guard let firstURL = snapshot.inputs.urls.first else {
            return ""
        }
        return firstURL
    }

    private static func truncatedLabel(_ label: String, limit: Int = 36) -> String {
        guard label.count > limit else {
            return label
        }
        return String(label.prefix(limit - 1)) + "\u{2026}"
    }
}
