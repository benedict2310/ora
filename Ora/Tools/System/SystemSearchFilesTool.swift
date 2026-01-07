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
        
        let results = await searchWithSpotlight(query: query, limit: limit)
        
        let resultArray = results.map { result in
            JSONValue.object([
                "name": .string(result.name),
                "path": .string(result.path)
            ])
        }
        
        let summary = results.isEmpty 
            ? "No files found for '\(query)'."
            : "Found \(results.count) file\(results.count == 1 ? "" : "s")."
        
        return .success(
            .object(["results": .array(resultArray)]),
            summary: summary
        )
    }
    
    @MainActor
    private func searchWithSpotlight(query: String, limit: Int) async -> [(name: String, path: String)] {
        await withCheckedContinuation { continuation in
            let metadataQuery = NSMetadataQuery()
            metadataQuery.predicate = NSPredicate(format: "kMDItemDisplayName CONTAINS[cd] %@", query)
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
                
                var results: [(name: String, path: String)] = []
                let count = min(metadataQuery.resultCount, limit)
                
                for i in 0..<count {
                    if let item = metadataQuery.result(at: i) as? NSMetadataItem,
                       let path = item.value(forAttribute: kMDItemPath as String) as? String {
                        let name = (path as NSString).lastPathComponent
                        results.append((name: name, path: path))
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
}
