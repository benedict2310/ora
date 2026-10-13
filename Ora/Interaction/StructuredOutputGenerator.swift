import Foundation

enum StructuredOutputGenerationError: Error, Sendable, Equatable {
    case validationFailed
}

enum StructuredAssistantOutput: Sendable, Equatable {
    case response(message: String)
    case action(name: String)
}

protocol StructuredOutputGenerating: Sendable {
    func generate(for request: AssistantTextRequest) async throws -> StructuredAssistantOutput
}
