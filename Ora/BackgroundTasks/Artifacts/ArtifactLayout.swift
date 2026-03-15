//
//  ArtifactLayout.swift
//  Ora
//
//  Deterministic artifact paths rooted in the user's Documents folder.
//

import Foundation

enum ArtifactLayoutError: LocalizedError, Equatable {
    case unableToResolveDocumentsDirectory
    case invalidArtifactPath(path: String)

    var errorDescription: String? {
        switch self {
        case .unableToResolveDocumentsDirectory:
            return "Unable to resolve the Ora artifact storage root."
        case .invalidArtifactPath(let path):
            return "Artifact path escapes the canonical Ora Research root: \(path)"
        }
    }
}

struct ArtifactLayout: Sendable {

    // MARK: - Constants

    static let rootFolderName = "Ora Research"
    static let fallbackSlug = "artifact"
    static let maxSlugLength = 40

    // MARK: - Properties

    let rootURL: URL

    // MARK: - Init

    init(rootURL: URL? = nil) throws {
        if let rootURL {
            self.rootURL = rootURL.standardizedFileURL
        } else {
            self.rootURL = try Self.defaultRootURL()
        }
    }

    // MARK: - Path Building

    func taskDirectoryURL(for task: BackgroundTaskRecordSnapshot) throws -> URL {
        let dateComponent = Self.directoryDateFormatter.string(from: task.createdAt)
        let folderName = "task-\(self.shortID(for: task.id))-\(self.slug(for: task))"
        let directoryURL = self.rootURL
            .appendingPathComponent(dateComponent, isDirectory: true)
            .appendingPathComponent(folderName, isDirectory: true)
        return try self.validatedArtifactURL(directoryURL)
    }

    func validatedArtifactURL(_ url: URL) throws -> URL {
        let standardizedURL = url.standardizedFileURL
        let rootPath = self.rootURL.path
        let rootPrefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        let standardizedPath = standardizedURL.path
        guard standardizedPath == rootPath || standardizedPath.hasPrefix(rootPrefix) else {
            throw ArtifactLayoutError.invalidArtifactPath(path: standardizedPath)
        }
        return standardizedURL
    }

    func shortID(for taskID: UUID) -> String {
        return taskID.uuidString
            .lowercased()
            .replacingOccurrences(of: "-", with: "")
            .prefix(8)
            .description
    }

    func slug(for task: BackgroundTaskRecordSnapshot) -> String {
        let candidates = [
            task.inputs.label,
            Self.urlHint(from: task.inputs.urls.first),
            task.inputs.urls.first
        ]

        for candidate in candidates {
            guard let candidate else {
                continue
            }
            let slug = Self.sanitizedSlug(from: candidate)
            if !slug.isEmpty {
                return slug
            }
        }

        return Self.fallbackSlug
    }

    // MARK: - Helpers

    static func defaultRootURL() throws -> URL {
        do {
            let documentsURL = try FileManager.default.url(
                for: .documentDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            return documentsURL
                .appendingPathComponent(Self.rootFolderName, isDirectory: true)
                .standardizedFileURL
        } catch {
            throw ArtifactLayoutError.unableToResolveDocumentsDirectory
        }
    }

    static func sanitizedSlug(from source: String) -> String {
        let lowered = source.lowercased()
        var scalars: [UnicodeScalar] = []
        var lastWasHyphen = false

        for scalar in lowered.unicodeScalars {
            if Self.isASCIIAlphaNumeric(scalar) {
                scalars.append(scalar)
                lastWasHyphen = false
                continue
            }

            guard !lastWasHyphen else {
                continue
            }

            scalars.append("-")
            lastWasHyphen = true
        }

        let sanitized = String(String.UnicodeScalarView(scalars))
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))

        guard !sanitized.isEmpty else {
            return ""
        }

        return String(sanitized.prefix(Self.maxSlugLength))
    }

    private static func urlHint(from rawURL: String?) -> String? {
        guard let rawURL, let url = URL(string: rawURL) else {
            return nil
        }

        var parts: [String] = []
        if let host = url.host(percentEncoded: false), !host.isEmpty {
            parts.append(host)
        }

        let pathComponents = url.pathComponents
            .filter { $0 != "/" && !$0.isEmpty }
            .suffix(2)
        parts.append(contentsOf: pathComponents)

        guard !parts.isEmpty else {
            return nil
        }

        return parts.joined(separator: "-")
    }

    private static func isASCIIAlphaNumeric(_ scalar: UnicodeScalar) -> Bool {
        switch scalar.value {
        case 48...57, 97...122:
            return true
        default:
            return false
        }
    }

    private static let directoryDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}
