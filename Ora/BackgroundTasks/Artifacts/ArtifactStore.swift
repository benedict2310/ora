//
//  ArtifactStore.swift
//  Ora
//
//  File-backed persistence for background task artifacts.
//

import AppKit
import Foundation
import os

enum ArtifactStoreError: LocalizedError, Equatable {
    case artifactNotFound(taskID: UUID)
    case symlinkDetected(path: String)
    case diskQuotaExceeded(limitBytes: Int64, currentBytes: Int64, requiredBytes: Int64)

    var errorDescription: String? {
        switch self {
        case .artifactNotFound(let taskID):
            return "No artifact was found for task \(taskID.uuidString)."
        case .symlinkDetected(let path):
            return "Refusing to write artifacts through symlinked path: \(path)"
        case .diskQuotaExceeded(let limitBytes, let currentBytes, let requiredBytes):
            return "Ora artifact storage quota exceeded (limit: \(limitBytes) bytes, current: \(currentBytes), required: \(requiredBytes))."
        }
    }
}

actor ArtifactStore {

    // MARK: - Constants

    static let shared = ArtifactStore()
    static let defaultCleanupAge: TimeInterval = 30 * 24 * 60 * 60
    static let defaultDiskQuotaBytes: Int64 = 500 * 1024 * 1024

    // MARK: - Properties

    private let logger = Logger.ora(category: "persistence")
    private let configuredRootURL: URL?
    private let fileManager: FileManager
    private let diskQuotaBytes: Int64
    private let revealer: @Sendable (URL) async -> Void
    private let now: @Sendable () -> Date
    private let atomicWriteObserver: (@Sendable (URL, URL) -> Void)?

    // MARK: - Init

    init(
        rootURL: URL? = nil,
        fileManager: FileManager = .default,
        diskQuotaBytes: Int64 = ArtifactStore.defaultDiskQuotaBytes,
        revealer: @escaping @Sendable (URL) async -> Void = ArtifactStore.defaultRevealer,
        now: @escaping @Sendable () -> Date = ArtifactStore.defaultNow,
        atomicWriteObserver: (@Sendable (URL, URL) -> Void)? = nil
    ) {
        self.configuredRootURL = rootURL
        self.fileManager = fileManager
        self.diskQuotaBytes = diskQuotaBytes
        self.revealer = revealer
        self.now = now
        self.atomicWriteObserver = atomicWriteObserver
    }

    // MARK: - Public API

    func save(
        task: BackgroundTaskRecordSnapshot,
        workerResult: BackgroundTaskWorkerResult,
        persistRawHTML: Bool = false
    ) async throws -> ArtifactManifest {
        let layout = try self.makeLayout()
        let taskDirectoryURL = try layout.taskDirectoryURL(for: task)
        let completedAt = self.now()

        let rawPages = workerResult.pages.compactMap { page -> (String, Data)? in
            guard persistRawHTML, let rawHTML = page.rawHTML else {
                return nil
            }
            let filename = "page-\(page.pageNumber).html"
            return (filename, Data(rawHTML.utf8))
        }

        let result = ArtifactResult(
            taskID: task.id,
            taskKind: task.taskKind,
            label: task.inputs.label,
            sourceURLs: task.inputs.urls,
            title: workerResult.title,
            summary: workerResult.summary,
            markdown: workerResult.markdown,
            pages: workerResult.pages.map { page in
                ArtifactStoredPage(
                    pageNumber: page.pageNumber,
                    url: page.url,
                    title: page.title,
                    extractedText: page.extractedText,
                    rawHTMLFilename: rawPages.contains(where: { $0.0 == "page-\(page.pageNumber).html" }) ? "page-\(page.pageNumber).html" : nil
                )
            },
            createdAt: task.createdAt,
            completedAt: completedAt
        )
        let manifest = ArtifactManifest(
            taskID: task.id,
            taskKind: task.taskKind,
            label: task.inputs.label,
            sourceURLs: task.inputs.urls,
            artifactPath: taskDirectoryURL.path,
            createdAt: task.createdAt,
            completedAt: completedAt,
            citationCount: workerResult.citations.count,
            pageCount: workerResult.pages.count,
            rawHTMLPageCount: rawPages.count
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        let manifestData = try encoder.encode(manifest)
        let resultData = try encoder.encode(result)
        let citationsData = try encoder.encode(workerResult.citations)
        let estimatedWriteBytes = Int64(manifestData.count + resultData.count + citationsData.count + rawPages.reduce(0) { $0 + $1.1.count })
        try self.ensurePathHasNoSymlinks(from: layout.rootURL, through: taskDirectoryURL)
        try await self.enforceDiskQuota(rootURL: layout.rootURL, requiredBytes: estimatedWriteBytes)
        try self.fileManager.createDirectory(at: taskDirectoryURL, withIntermediateDirectories: true)
        try self.ensurePathHasNoSymlinks(from: layout.rootURL, through: taskDirectoryURL)

        try self.writeAtomically(manifestData, to: taskDirectoryURL.appendingPathComponent("manifest.json"))
        try self.writeAtomically(resultData, to: taskDirectoryURL.appendingPathComponent("result.json"))
        try self.writeAtomically(citationsData, to: taskDirectoryURL.appendingPathComponent("citations.json"))

        if !rawPages.isEmpty {
            let rawDirectoryURL = taskDirectoryURL.appendingPathComponent("raw", isDirectory: true)
            try self.fileManager.createDirectory(at: rawDirectoryURL, withIntermediateDirectories: true)
            try self.ensurePathHasNoSymlinks(from: layout.rootURL, through: rawDirectoryURL)
            for (filename, rawData) in rawPages {
                try self.writeAtomically(rawData, to: rawDirectoryURL.appendingPathComponent(filename))
            }
        }

        return manifest
    }

    func read(taskID: UUID) async throws -> StoredArtifact {
        let entry = try self.findEntry(taskID: taskID)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let resultData = try Data(contentsOf: entry.directoryURL.appendingPathComponent("result.json"))
        let citationsData = try Data(contentsOf: entry.directoryURL.appendingPathComponent("citations.json"))
        let result = try decoder.decode(ArtifactResult.self, from: resultData)
        let citations = try decoder.decode([BackgroundTaskArtifactCitation].self, from: citationsData)

        let rawHTMLPages: [ArtifactRawHTMLPage] = try result.pages.compactMap { page in
            guard let rawHTMLFilename = page.rawHTMLFilename else {
                return nil
            }
            let rawURL = entry.directoryURL
                .appendingPathComponent("raw", isDirectory: true)
                .appendingPathComponent(rawHTMLFilename)
            let html = try String(contentsOf: rawURL, encoding: .utf8)
            return ArtifactRawHTMLPage(
                pageNumber: page.pageNumber,
                filename: rawHTMLFilename,
                html: html
            )
        }

        return StoredArtifact(
            manifest: entry.manifest,
            result: result,
            citations: citations,
            rawHTMLPages: rawHTMLPages
        )
    }

    func list(limit: Int = 50) async -> [ArtifactManifest] {
        let clampedLimit = max(1, limit)
        do {
            let entries = try self.scanEntries()
            return entries
                .map(\.manifest)
                .sorted {
                    if $0.completedAt == $1.completedAt {
                        return $0.createdAt > $1.createdAt
                    }
                    return $0.completedAt > $1.completedAt
                }
                .prefix(clampedLimit)
                .map { $0 }
        } catch {
            self.logger.warning("Failed to list artifacts: \(error.localizedDescription)")
            return []
        }
    }

    func revealInFinder(taskID: UUID) async throws {
        let entry = try self.findEntry(taskID: taskID)
        await self.revealer(entry.directoryURL)
    }

    @discardableResult
    func cleanup(olderThan cutoff: Date) async -> Int {
        do {
            let layout = try self.makeLayout()
            guard self.fileManager.fileExists(atPath: layout.rootURL.path) else {
                return 0
            }

            let entries = try self.scanEntries()
            var removedCount = 0
            for entry in entries where entry.manifest.completedAt < cutoff {
                do {
                    try self.fileManager.removeItem(at: entry.directoryURL)
                    removedCount += 1
                } catch {
                    self.logger.warning("Failed to remove expired artifact at \(entry.directoryURL.path): \(error.localizedDescription)")
                }
            }

            try self.removeEmptyDateDirectories(in: layout.rootURL)
            return removedCount
        } catch {
            self.logger.warning("Artifact cleanup skipped: \(error.localizedDescription)")
            return 0
        }
    }

    // MARK: - Helpers

    private func makeLayout() throws -> ArtifactLayout {
        return try ArtifactLayout(rootURL: self.configuredRootURL)
    }

    private func findEntry(taskID: UUID) throws -> ArtifactScanEntry {
        guard let entry = try self.scanEntries().first(where: { $0.manifest.taskID == taskID }) else {
            throw ArtifactStoreError.artifactNotFound(taskID: taskID)
        }
        return entry
    }

    private func scanEntries() throws -> [ArtifactScanEntry] {
        let layout = try self.makeLayout()
        guard self.fileManager.fileExists(atPath: layout.rootURL.path) else {
            return []
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let dateDirectories = try self.fileManager.contentsOfDirectory(
            at: layout.rootURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )
        var entries: [ArtifactScanEntry] = []

        for dateDirectory in dateDirectories {
            let values = try dateDirectory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                continue
            }

            let taskDirectories = try self.fileManager.contentsOfDirectory(
                at: dateDirectory,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            )

            for taskDirectory in taskDirectories {
                let taskValues = try taskDirectory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard taskValues.isDirectory == true, taskValues.isSymbolicLink != true else {
                    continue
                }

                let manifestURL = taskDirectory.appendingPathComponent("manifest.json")
                guard self.fileManager.fileExists(atPath: manifestURL.path) else {
                    continue
                }

                let decodedManifest = try decoder.decode(ArtifactManifest.self, from: Data(contentsOf: manifestURL))
                let canonicalDirectoryURL = try layout.validatedArtifactURL(taskDirectory)
                let manifest = ArtifactManifest(
                    taskID: decodedManifest.taskID,
                    taskKind: decodedManifest.taskKind,
                    label: decodedManifest.label,
                    sourceURLs: decodedManifest.sourceURLs,
                    artifactPath: canonicalDirectoryURL.path,
                    createdAt: decodedManifest.createdAt,
                    completedAt: decodedManifest.completedAt,
                    citationCount: decodedManifest.citationCount,
                    pageCount: decodedManifest.pageCount,
                    rawHTMLPageCount: decodedManifest.rawHTMLPageCount
                )
                entries.append(ArtifactScanEntry(manifest: manifest, directoryURL: canonicalDirectoryURL))
            }
        }

        return entries
    }

    private func ensurePathHasNoSymlinks(from rootURL: URL, through targetURL: URL) throws {
        let canonicalRootURL = rootURL.standardizedFileURL
        let canonicalTargetURL = try ArtifactLayout(rootURL: canonicalRootURL).validatedArtifactURL(targetURL)
        var currentURL = canonicalRootURL

        try self.assertPathIsNotSymlink(currentURL)

        let rootComponents = canonicalRootURL.pathComponents
        let targetComponents = canonicalTargetURL.pathComponents
        let components = targetComponents.dropFirst(rootComponents.count)

        for component in components {
            currentURL.appendPathComponent(component, isDirectory: true)
            try self.assertPathIsNotSymlink(currentURL)
        }
    }

    private func assertPathIsNotSymlink(_ url: URL) throws {
        guard self.fileManager.fileExists(atPath: url.path) else {
            return
        }

        let attributes = try self.fileManager.attributesOfItem(atPath: url.path)
        if let fileType = attributes[.type] as? FileAttributeType, fileType == .typeSymbolicLink {
            throw ArtifactStoreError.symlinkDetected(path: url.path)
        }
    }

    private func enforceDiskQuota(rootURL: URL, requiredBytes: Int64) async throws {
        let currentBytes = try self.directorySize(at: rootURL)
        guard currentBytes + requiredBytes > self.diskQuotaBytes else {
            return
        }

        _ = await self.cleanup(olderThan: self.now().addingTimeInterval(-Self.defaultCleanupAge))
        let bytesAfterCleanup = try self.directorySize(at: rootURL)
        guard bytesAfterCleanup + requiredBytes <= self.diskQuotaBytes else {
            throw ArtifactStoreError.diskQuotaExceeded(
                limitBytes: self.diskQuotaBytes,
                currentBytes: bytesAfterCleanup,
                requiredBytes: requiredBytes
            )
        }
    }

    private func directorySize(at rootURL: URL) throws -> Int64 {
        guard self.fileManager.fileExists(atPath: rootURL.path) else {
            return 0
        }

        guard let enumerator = self.fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }

        var totalSize: Int64 = 0
        for case let fileURL as URL in enumerator {
            let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true else {
                continue
            }
            totalSize += Int64(values.fileSize ?? 0)
        }
        return totalSize
    }

    private func writeAtomically(_ data: Data, to destinationURL: URL) throws {
        let parentURL = destinationURL.deletingLastPathComponent()
        try self.fileManager.createDirectory(at: parentURL, withIntermediateDirectories: true)

        let tempURL = parentURL.appendingPathComponent(".\(destinationURL.lastPathComponent).\(UUID().uuidString).tmp")
        do {
            try data.write(to: tempURL)
            self.atomicWriteObserver?(tempURL, destinationURL)

            if self.fileManager.fileExists(atPath: destinationURL.path) {
                _ = try self.fileManager.replaceItemAt(destinationURL, withItemAt: tempURL)
            } else {
                try self.fileManager.moveItem(at: tempURL, to: destinationURL)
            }
        } catch {
            try? self.fileManager.removeItem(at: tempURL)
            throw error
        }
    }

    private func removeEmptyDateDirectories(in rootURL: URL) throws {
        let directories = try self.fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        for directory in directories {
            let values = try directory.resourceValues(forKeys: [.isDirectoryKey])
            guard values.isDirectory == true else {
                continue
            }

            let children = try self.fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
            if children.isEmpty {
                try? self.fileManager.removeItem(at: directory)
            }
        }
    }

    private static let defaultRevealer: @Sendable (URL) async -> Void = { url in
        await ExternalFocusTracker.shared.withExternalOperation {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    private static let defaultNow: @Sendable () -> Date = {
        return Date()
    }
}

private struct ArtifactScanEntry: Sendable {
    let manifest: ArtifactManifest
    let directoryURL: URL
}
