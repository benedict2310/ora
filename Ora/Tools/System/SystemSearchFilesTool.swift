//
//  SystemSearchFilesTool.swift
//  Ora
//
//  Search indexed files using Spotlight
//

@preconcurrency import Foundation

struct SystemSearchFilesTool: Tool {
    let name = "system.search_files"
    let kind: ToolKind = .read

    struct FileResult {
        let name: String
        let path: String
    }

    /// Minimum Jaro-Winkler score for fuzzy file name matching.
    static let fuzzyThreshold: Double = 0.80
    
    var schema: ToolSchema {
        ToolSchema(
            name: name,
            description: "Search for files using Spotlight index",
            parameters: [
                "query": ParameterSchema(type: "string", description: "Search query"),
                "limit": ParameterSchema(type: "number", description: "Maximum results (default 5)")
            ],
            requiredParameters: ["query"],
            requiresConfirmation: false
        )
    }
    
    func validate(args: [String: JSONValue]) throws {
        guard let query = args["query"]?.stringValue, !query.isEmpty else {
            throw ToolHostError.validationFailed(name, "Missing required parameter: query")
        }
    }
    
    func execute(args: [String: JSONValue]) async throws -> ToolResult {
        guard let query = args["query"]?.stringValue else {
            throw SystemToolError.invalidArgument("Query required")
        }
        
        let limit = Int(args["limit"]?.numberValue ?? 5)
        
        let results = await search(query: query, limit: limit)
        
        let resultArray = results.map { Self.fileToJSON($0) }
        
        let summary = results.isEmpty 
            ? "No files found for '\(query)'."
            : "Found \(results.count) file\(results.count == 1 ? "" : "s")."
        
        return .success(
            .object(["results": .array(resultArray)]),
            summary: summary
        )
    }

    private func search(query: String, limit: Int) async -> [FileResult] {
        let primaryResults = await searchWithSpotlight(
            predicate: Self.spotlightPredicate(for: query),
            limit: limit
        )
        if !primaryResults.isEmpty {
            return Self.rerank(query: query, results: primaryResults)
        }

        let retryCandidateLimit = Self.retryCandidateLimit(for: limit)
        let retryResults = await searchWithSpotlight(
            predicate: Self.broadenedPredicate(for: query),
            limit: retryCandidateLimit
        )
        return Self.fuzzyFilter(query: query, results: retryResults, limit: limit)
    }

    @MainActor
    private func searchWithSpotlight(predicate: NSPredicate, limit: Int) async -> [FileResult] {
        await withCheckedContinuation { continuation in
            let metadataQuery = NSMetadataQuery()
            metadataQuery.predicate = predicate
            metadataQuery.searchScopes = [
                NSMetadataQueryUserHomeScope,
                NSMetadataQueryLocalComputerScope
            ]
            
            // Guard against double-resume (race between notification and timeout)
            var hasResumed = false
            
            var observer: NSObjectProtocol?
            observer = NotificationCenter.default.addObserver(
                forName: .NSMetadataQueryDidFinishGathering,
                object: metadataQuery,
                queue: .main
            ) { _ in
                guard !hasResumed else { return }
                hasResumed = true
                
                metadataQuery.stop()
                
                var results: [FileResult] = []
                let count = min(metadataQuery.resultCount, limit)
                
                for i in 0..<count {
                    if let item = metadataQuery.result(at: i) as? NSMetadataItem,
                       let path = item.value(forAttribute: kMDItemPath as String) as? String {
                        let name = (path as NSString).lastPathComponent
                        results.append(FileResult(name: name, path: path))
                    }
                }
                
                if let observer = observer {
                    NotificationCenter.default.removeObserver(observer)
                }
                
                continuation.resume(returning: results)
            }
            
            metadataQuery.start()
            
            // Timeout after 5 seconds
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                guard !hasResumed else { return }
                hasResumed = true
                
                metadataQuery.stop()
                if let observer = observer {
                    NotificationCenter.default.removeObserver(observer)
                }
                continuation.resume(returning: [])
            }
        }
    }

    static func spotlightPredicate(for query: String) -> NSPredicate {
        NSPredicate(format: "kMDItemDisplayName CONTAINS[cd] %@", query)
    }

    static func broadenedPredicate(for query: String) -> NSPredicate {
        let terms = broadenedQueryTerms(for: query)
        guard terms.count > 1 else {
            return spotlightPredicate(for: query)
        }

        let subpredicates = terms.map {
            NSPredicate(format: "kMDItemDisplayName CONTAINS[cd] %@", $0)
        }
        return NSCompoundPredicate(orPredicateWithSubpredicates: subpredicates)
    }

    static func broadenedQueryTerms(for query: String) -> [String] {
        let rawTerms = query.split { $0.isWhitespace }
        var seen = Set<String>()
        var terms: [String] = []
        for term in rawTerms {
            let cleaned = String(term)
                .trimmingCharacters(in: .punctuationCharacters)
            guard !cleaned.isEmpty else { continue }
            let lowered = cleaned.lowercased()
            if seen.insert(lowered).inserted {
                terms.append(cleaned)
            }
        }
        return terms
    }

    static func retryCandidateLimit(for limit: Int) -> Int {
        let scaled: Int
        if limit > (Int.max / 4) {
            scaled = Int.max
        } else {
            scaled = limit * 4
        }
        return max(scaled, 20)
    }

    static func rerank(query: String, results: [FileResult]) -> [FileResult] {
        results
            .map { result in (result: result, score: matchScore(query: query, filename: result.name)) }
            .sorted { lhs, rhs in
                let delta = lhs.score - rhs.score
                if abs(delta) < 0.0001 {
                    return lhs.result.name.lowercased() < rhs.result.name.lowercased()
                }
                return lhs.score > rhs.score
            }
            .map { $0.result }
    }

    static func fuzzyFilter(
        query: String,
        results: [FileResult],
        threshold: Double = fuzzyThreshold,
        limit: Int = 5
    ) -> [FileResult] {
        results
            .map { result in (result: result, score: matchScore(query: query, filename: result.name)) }
            .filter { $0.score >= threshold }
            .sorted { lhs, rhs in
                let delta = lhs.score - rhs.score
                if abs(delta) < 0.0001 {
                    return lhs.result.name.lowercased() < rhs.result.name.lowercased()
                }
                return lhs.score > rhs.score
            }
            .prefix(limit)
            .map { $0.result }
    }

    static func matchScore(query: String, filename: String) -> Double {
        let scoringName = scoringName(for: filename)
        return StringSimilarity.jaroWinkler(query, scoringName)
    }

    static func scoringName(for filename: String) -> String {
        (filename as NSString).deletingPathExtension
    }

    static func fileToJSON(_ result: FileResult) -> JSONValue {
        .object([
            "name": .string(result.name),
            "path": .string(result.path)
        ])
    }
}
