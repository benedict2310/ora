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

    private static let defaultDebounceInterval: TimeInterval = OraConstants.Timing.memoryWatcherDebounceInterval

    // MARK: - Properties

    private let logger = Logger.ora(category: "memory")
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

    deinit {
        let state = self.state
        let logger = self.logger
        Task {
            await state.cancelDebounce()
            if let source = await state.clearSource() {
                source.cancel()
            }
            logger.debug("Stopped watching MEMORY.md in deinit")
        }
    }

    // MARK: - Public API

    func startWatching() async {
        let isAlreadyWatching = await self.state.isWatching
        guard !isAlreadyWatching else {
            return
        }

        await self.installSource()
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
        do {
            try await Task.sleep(for: OraConstants.Timing.memoryWatcherEndWriteDelay)
        } catch {
            return
        }
        await self.state.setWriteInProgress(false)
    }

    // MARK: - Private

    /// Open a file descriptor and install a DispatchSource to monitor changes.
    private func installSource() async {
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

        // Capture weak self in a @Sendable closure to avoid mutable-var capture in Task.
        let reopener: @Sendable () async -> Void = { [weak self] in
            await self?.reopenSource()
        }

        source.setEventHandler {
            let flags = source.data
            let needsReopen = flags.contains(.rename) || flags.contains(.delete)

            Task {
                // Atomic writes (tmp + rename) invalidate the old FD. Re-open for the new inode.
                if needsReopen {
                    await reopener()
                }

                let isWriteInProgress = await state.isWriteInProgress
                guard !isWriteInProgress else {
                    logger.debug("Suppressed re-index during Ora write")
                    return
                }

                await state.cancelDebounce()

                let task = Task {
                    do {
                        let delayMilliseconds = Int(debounceInterval * OraConstants.Timing.memoryWatcherDebounceGranularityMilliseconds)
                        try await Task.sleep(for: .milliseconds(delayMilliseconds))
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

    /// Re-open the file descriptor after a rename or delete event invalidated the old one.
    private func reopenSource() async {
        if let oldSource = await self.state.clearSource() {
            oldSource.cancel()
        }

        // Brief delay for filesystem to settle after atomic rename.
        do {
            try await Task.sleep(for: OraConstants.Timing.memoryWatcherReopenDelay)
        } catch {
            return
        }

        await self.installSource()
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
