//
//  MemoryFileWatcher.swift
//  Ora
//
//  Watches MEMORY.md for external edits and triggers re-indexing.
//

import Foundation
import os

final class MemoryFileWatcher: Sendable {

    // MARK: - Constants

    private static let defaultDebounceInterval: TimeInterval = 0.75

    // MARK: - Properties

    private let logger = Logger(subsystem: "com.ora.app", category: "memory")
    private let fileURL: URL
    private let debounceInterval: TimeInterval
    private let onFileChanged: @Sendable () async -> Void

    private let state = WatcherState()

    // MARK: - Initialization

    init(
        fileURL: URL,
        debounceInterval: TimeInterval = MemoryFileWatcher.defaultDebounceInterval,
        onFileChanged: @Sendable @escaping () async -> Void
    ) {
        self.fileURL = fileURL
        self.debounceInterval = debounceInterval
        self.onFileChanged = onFileChanged
    }

    // MARK: - Public API

    func startWatching() async {
        let isAlreadyWatching = await self.state.isWatching
        guard !isAlreadyWatching else {
            return
        }

        let fd = open(self.fileURL.path, O_EVTONLY)
        guard fd >= 0 else {
            self.logger.warning("Cannot watch MEMORY.md: failed to open file descriptor")
            return
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete],
            queue: .global(qos: .utility)
        )

        let debounceInterval = self.debounceInterval
        let onFileChanged = self.onFileChanged
        let state = self.state
        let logger = self.logger

        source.setEventHandler {
            Task {
                let isWriteInProgress = await state.isWriteInProgress
                guard !isWriteInProgress else {
                    logger.debug("Suppressed re-index during Ora write")
                    return
                }

                await state.cancelDebounce()

                let task = Task {
                    do {
                        try await Task.sleep(for: .milliseconds(Int(debounceInterval * 1000)))
                    } catch {
                        return
                    }

                    guard !Task.isCancelled else {
                        return
                    }

                    let stillWriting = await state.isWriteInProgress
                    guard !stillWriting else {
                        return
                    }

                    logger.info("MEMORY.md changed externally — triggering re-index")
                    await onFileChanged()
                }

                await state.setDebounceTask(task)
            }
        }

        source.setCancelHandler {
            close(fd)
        }

        await self.state.setSource(source)
        source.resume()

        self.logger.debug("Started watching MEMORY.md for external edits")
    }

    func stopWatching() async {
        await self.state.cancelDebounce()

        if let source = await self.state.clearSource() {
            source.cancel()
        }

        self.logger.debug("Stopped watching MEMORY.md")
    }

    func beginOraWrite() async {
        await self.state.setWriteInProgress(true)
    }

    func endOraWrite() async {
        // Delay clearing the flag so the DispatchSource event is still suppressed.
        try? await Task.sleep(for: .milliseconds(200))
        await self.state.setWriteInProgress(false)
    }
}

// MARK: - Actor State

private actor WatcherState {
    var source: DispatchSourceFileSystemObject?
    var debounceTask: Task<Void, Never>?
    var isWriteInProgress = false

    var isWatching: Bool {
        return self.source != nil
    }

    func setSource(_ source: DispatchSourceFileSystemObject) {
        self.source = source
    }

    func clearSource() -> DispatchSourceFileSystemObject? {
        let current = self.source
        self.source = nil
        return current
    }

    func setDebounceTask(_ task: Task<Void, Never>) {
        self.debounceTask = task
    }

    func cancelDebounce() {
        self.debounceTask?.cancel()
        self.debounceTask = nil
    }

    func setWriteInProgress(_ value: Bool) {
        self.isWriteInProgress = value
    }
}
