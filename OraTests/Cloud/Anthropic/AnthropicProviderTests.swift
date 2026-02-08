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

    // NOTE: Real API integration tests would require mocking URLSession
    // or using a test HTTP server. For now, we verify basic initialization.
    // Full SSE parsing and retry logic would be tested with mocked responses.
}
