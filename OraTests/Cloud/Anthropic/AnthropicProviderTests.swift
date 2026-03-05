//
//  AnthropicProviderTests.swift
//  OraTests
//
//  Tests for Anthropic Claude provider
//

import XCTest
@testable import Ora

final class AnthropicProviderTests: XCTestCase {

    // MARK: - Helpers

    private func makeProvider(apiKey: String = "sk-ant-test-key", model: String = "claude-sonnet-4-20250514") -> AnthropicProvider {
        return AnthropicProvider(apiKey: apiKey, model: model)
    }

    // MARK: - Tests

    func test_init_setsModelAndApiKey() {
        // Given
        let apiKey = "sk-ant-test-12345"
        let model = AnthropicModel.haiku.rawValue

        // When
        let provider = makeProvider(apiKey: apiKey, model: model)

        // Then
        XCTAssertNotNil(provider)
    }

    func test_factory_createsProvider() throws {
        // Given
        let factory = AnthropicProviderFactory(model: AnthropicModel.sonnet.rawValue)
        let apiKey = "sk-ant-test-key"

        // When
        let provider = try factory.create(apiKey: apiKey)

        // Then
        XCTAssertNotNil(provider)
        XCTAssert(provider is AnthropicProvider)
    }

    func test_models_haveCorrectMetadata() {
        // Given/When/Then
        XCTAssertEqual(AnthropicModel.sonnet.displayName, "Claude Sonnet 4")
        XCTAssertEqual(AnthropicModel.haiku.displayName, "Claude Haiku 4")
        XCTAssertEqual(AnthropicModel.opus.displayName, "Claude Opus 4")

        XCTAssertEqual(AnthropicModel.sonnet.maxOutputTokens, 8192)
        XCTAssertEqual(AnthropicModel.haiku.maxOutputTokens, 8192)
        XCTAssertEqual(AnthropicModel.opus.maxOutputTokens, 8192)
    }

    func test_generate_withImageAttachment_throwsUnsupportedInput() async throws {
        let provider = self.makeProvider()
        let image = LLMImageAttachmentReference(
            stagedFilePath: "/tmp/ora/staged/image.png",
            mimeType: "image/png"
        )
        let message = LLMMessage(
            role: .user,
            contentParts: [
                .text("Describe this image"),
                .image(image),
            ]
        )

        do {
            _ = try await self.collectDeltas(
                from: await provider.generate(messages: [message], maxTokens: 32)
            )
            XCTFail("Expected unsupported input error")
        } catch let error as CloudProviderError {
            guard case .unsupportedInput(let guidance) = error else {
                return XCTFail("Unexpected CloudProviderError: \(error)")
            }
            XCTAssertTrue(guidance.contains("text-only"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    // NOTE: Real API integration tests would require mocking URLSession
    // or using a test HTTP server. For now, we verify basic initialization.
    // Full SSE parsing and retry logic would be tested with mocked responses.

    private func collectDeltas(from stream: AsyncThrowingStream<LLMDelta, Error>) async throws -> [LLMDelta] {
        var deltas: [LLMDelta] = []
        for try await delta in stream {
            deltas.append(delta)
        }
        return deltas
    }
}
