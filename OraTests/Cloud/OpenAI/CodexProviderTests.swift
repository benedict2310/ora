//
//  CodexProviderTests.swift
//  OraTests
//
//  Tests for Codex OAuth-backed provider behavior.
//

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import Ora

final class CodexProviderTests: XCTestCase {
    override func tearDown() async throws {
        CodexProviderMockURLProtocol.reset()
        UserDefaults.standard.removeObject(forKey: "com.ora.openAI.discoveredModelIdentifiers")
        UserDefaults.standard.removeObject(forKey: "com.ora.openAI.discoveredModels")
    }

    func test_codexProvider_setsCorrectHeaders() async throws {
        // Given
        var capturedAuthorization: String?
        var capturedAccountID: String?
        var capturedOriginator: String?
        var capturedVersion: String?
        var capturedUserAgent: String?
        var capturedURL: URL?
        CodexProviderMockURLProtocol.setHandler { request, _ in
            capturedAuthorization = request.value(forHTTPHeaderField: "Authorization")
            capturedAccountID = request.value(forHTTPHeaderField: "chatgpt-account-id")
            capturedOriginator = request.value(forHTTPHeaderField: "originator")
            capturedVersion = request.value(forHTTPHeaderField: "version")
            capturedUserAgent = request.value(forHTTPHeaderField: "User-Agent")
            capturedURL = request.url
            return .sse(events: ["[DONE]"])
        }
        let provider = self.makeProvider()

        // When
        _ = try await self.collectDeltas(
            from: await provider.generate(
                messages: [LLMMessage(role: .user, content: "Hello")],
                maxTokens: 32
            )
        )

        // Then
        XCTAssertEqual(capturedAuthorization, "Bearer access_token")
        XCTAssertEqual(capturedAccountID, "acct_123")
        XCTAssertEqual(capturedOriginator, CodexOAuthManager.originator)
        XCTAssertNotNil(capturedVersion)
        XCTAssertTrue((capturedUserAgent ?? "").contains(CodexOAuthManager.originator))
        XCTAssertEqual(capturedURL?.absoluteString, "https://chatgpt.com/backend-api/codex/responses")
    }

    func test_codexProvider_usesResponsesRequestShape() async throws {
        // Given
        var capturedBody: [String: Any]?
        CodexProviderMockURLProtocol.setHandler { request, _ in
            if let body = self.requestBodyData(from: request) {
                capturedBody = try JSONSerialization.jsonObject(with: body) as? [String: Any]
            }
            return .sse(events: ["[DONE]"])
        }
        let provider = self.makeProvider()

        // When
        _ = try await self.collectDeltas(
            from: await provider.generate(
                messages: [
                    LLMMessage(role: .system, content: "System instruction"),
                    LLMMessage(role: .user, content: "Hello"),
                ],
                maxTokens: 32
            )
        )

        // Then
        XCTAssertEqual(capturedBody?["model"] as? String, OpenAIModel.gpt4o.rawValue)
        XCTAssertEqual(capturedBody?["instructions"] as? String, "System instruction")
        XCTAssertEqual(capturedBody?["stream"] as? Bool, true)
        XCTAssertEqual(capturedBody?["tool_choice"] as? String, "auto")
        XCTAssertEqual(capturedBody?["parallel_tool_calls"] as? Bool, true)
        XCTAssertEqual(capturedBody?["store"] as? Bool, false)
        XCTAssertNil(capturedBody?["max_output_tokens"])

        let input = try XCTUnwrap(capturedBody?["input"] as? [[String: Any]])
        XCTAssertEqual(input.count, 1)
        XCTAssertEqual(input[0]["type"] as? String, "message")
        XCTAssertEqual(input[0]["role"] as? String, "user")
    }

    func test_codexProvider_streamsTokens() async throws {
        // Given
        CodexProviderMockURLProtocol.setHandler { _, _ in
            return .sse(events: [
                #"{"type":"response.output_text.delta","delta":"Hello"}"#,
                #"{"type":"response.output_text.delta","delta":" world"}"#,
                #"{"type":"response.completed","response":{"id":"resp_1","usage":{"input_tokens":10,"output_tokens":5,"total_tokens":15}}}"#,
            ])
        }
        let provider = self.makeProvider()

        // When
        let deltas = try await self.collectDeltas(
            from: await provider.generate(
                messages: [LLMMessage(role: .user, content: "Hello")],
                maxTokens: 32
            )
        )

        // Then
        XCTAssertEqual(self.tokenTexts(in: deltas), ["Hello", " world"])
    }

    func test_codexProvider_capabilities_reportsMultimodal_whenSelectedModelSupportsImages() async {
        UserDefaults.standard.openAIDiscoveredModels = [
            OpenAIModelOption(identifier: "gpt-5.2-codex", source: .discovered, supportsImageInput: true),
        ]
        let provider = self.makeProvider(model: "gpt-5.2-codex")

        let capabilities = await provider.capabilities()

        XCTAssertTrue(capabilities.supportsImageInput)
    }

    func test_codexProvider_capabilities_usesCuratedFallback_whenMetadataUnavailable() async {
        let provider = self.makeProvider(model: "gpt-5.2")

        let capabilities = await provider.capabilities()

        XCTAssertTrue(capabilities.supportsImageInput)
    }

    func test_codexProvider_capabilities_respectsExplicitDiscoveredFalse_overCuratedFallback() async {
        UserDefaults.standard.openAIDiscoveredModels = [
            OpenAIModelOption(identifier: "gpt-5.2", source: .discovered, supportsImageInput: false),
        ]
        let provider = self.makeProvider(model: "gpt-5.2")

        let capabilities = await provider.capabilities()

        XCTAssertFalse(capabilities.supportsImageInput)
    }

    func test_codexProvider_serializesImagePart_asInputImageDataURL() async throws {
        let imageURL = try self.writePNGFixture(width: 64, height: 32)
        defer { try? FileManager.default.removeItem(at: imageURL) }

        UserDefaults.standard.openAIDiscoveredModels = [
            OpenAIModelOption(identifier: "gpt-5.2-codex", source: .discovered, supportsImageInput: true),
        ]

        var capturedBody: [String: Any]?
        CodexProviderMockURLProtocol.setHandler { request, _ in
            if let body = self.requestBodyData(from: request) {
                capturedBody = try JSONSerialization.jsonObject(with: body) as? [String: Any]
            }
            return .sse(events: ["[DONE]"])
        }
        let provider = self.makeProvider(model: "gpt-5.2-codex")
        let image = LLMImageAttachmentReference(stagedFilePath: imageURL.path, mimeType: "image/png")

        _ = try await self.collectDeltas(
            from: await provider.generate(
                messages: [
                    LLMMessage(
                        role: .user,
                        contentParts: [
                            .text("What is in this screenshot?"),
                            .image(image),
                        ]
                    ),
                ],
                maxTokens: 32
            )
        )

        let input = try XCTUnwrap(capturedBody?["input"] as? [[String: Any]])
        let content = try XCTUnwrap(input.first?["content"] as? [[String: Any]])
        XCTAssertEqual(content.count, 2)
        XCTAssertEqual(content[0]["type"] as? String, "input_text")
        XCTAssertEqual(content[1]["type"] as? String, "input_image")
        let encodedURL = try XCTUnwrap(content[1]["image_url"] as? String)
        XCTAssertTrue(encodedURL.hasPrefix("data:image/png;base64,"))
    }

    func test_codexProvider_preservesImageOnlyUserTurn() async throws {
        let imageURL = try self.writePNGFixture(width: 40, height: 40)
        defer { try? FileManager.default.removeItem(at: imageURL) }

        UserDefaults.standard.openAIDiscoveredModels = [
            OpenAIModelOption(identifier: "gpt-5.2-codex", source: .discovered, supportsImageInput: true),
        ]

        var capturedBody: [String: Any]?
        CodexProviderMockURLProtocol.setHandler { request, _ in
            if let body = self.requestBodyData(from: request) {
                capturedBody = try JSONSerialization.jsonObject(with: body) as? [String: Any]
            }
            return .sse(events: ["[DONE]"])
        }
        let provider = self.makeProvider(model: "gpt-5.2-codex")
        let image = LLMImageAttachmentReference(stagedFilePath: imageURL.path, mimeType: "image/png")

        _ = try await self.collectDeltas(
            from: await provider.generate(
                messages: [
                    LLMMessage(role: .user, contentParts: [.image(image)]),
                ],
                maxTokens: 32
            )
        )

        let input = try XCTUnwrap(capturedBody?["input"] as? [[String: Any]])
        let content = try XCTUnwrap(input.first?["content"] as? [[String: Any]])
        XCTAssertEqual(content.count, 1)
        XCTAssertEqual(content[0]["type"] as? String, "input_image")
    }

    func test_codexProvider_preservesPriorImageTurnInHistory() async throws {
        let imageURL = try self.writePNGFixture(width: 48, height: 48)
        defer { try? FileManager.default.removeItem(at: imageURL) }

        UserDefaults.standard.openAIDiscoveredModels = [
            OpenAIModelOption(identifier: "gpt-5.2-codex", source: .discovered, supportsImageInput: true),
        ]

        var capturedBody: [String: Any]?
        CodexProviderMockURLProtocol.setHandler { request, _ in
            if let body = self.requestBodyData(from: request) {
                capturedBody = try JSONSerialization.jsonObject(with: body) as? [String: Any]
            }
            return .sse(events: ["[DONE]"])
        }
        let provider = self.makeProvider(model: "gpt-5.2-codex")
        let image = LLMImageAttachmentReference(stagedFilePath: imageURL.path, mimeType: "image/png")

        _ = try await self.collectDeltas(
            from: await provider.generate(
                messages: [
                    LLMMessage(role: .user, contentParts: [.text("What do you see?"), .image(image)]),
                    LLMMessage(role: .assistant, content: "I see a graph."),
                    LLMMessage(role: .user, content: "What is the max value?"),
                ],
                maxTokens: 32
            )
        )

        let input = try XCTUnwrap(capturedBody?["input"] as? [[String: Any]])
        let firstContent = try XCTUnwrap(input.first?["content"] as? [[String: Any]])
        XCTAssertEqual(firstContent.map { $0["type"] as? String }, ["input_text", "input_image"])
    }

    func test_codexProvider_missingAttachment_failsBeforeNetworkCall() async throws {
        UserDefaults.standard.openAIDiscoveredModels = [
            OpenAIModelOption(identifier: "gpt-5.2-codex", source: .discovered, supportsImageInput: true),
        ]
        CodexProviderMockURLProtocol.setHandler { _, _ in
            return .sse(events: ["[DONE]"])
        }
        let provider = self.makeProvider(model: "gpt-5.2-codex")
        let image = LLMImageAttachmentReference(stagedFilePath: "/tmp/ora/missing-image.png", mimeType: "image/png")

        do {
            _ = try await self.collectDeltas(
                from: await provider.generate(
                    messages: [LLMMessage(role: .user, contentParts: [.image(image)])],
                    maxTokens: 32
                )
            )
            XCTFail("Expected unsupported input error")
        } catch let error as CloudProviderError {
            guard case .unsupportedInput(let message) = error else {
                return XCTFail("Unexpected CloudProviderError: \(error)")
            }
            XCTAssertTrue(message.contains("attach the image again"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(CodexProviderMockURLProtocol.requestCount, 0)
    }

    func test_codexProvider_invalidImageAttachment_failsBeforeNetworkCall() async throws {
        let invalidURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".txt")
        try Data("not an image".utf8).write(to: invalidURL, options: [.atomic])
        defer { try? FileManager.default.removeItem(at: invalidURL) }

        UserDefaults.standard.openAIDiscoveredModels = [
            OpenAIModelOption(identifier: "gpt-5.2-codex", source: .discovered, supportsImageInput: true),
        ]
        CodexProviderMockURLProtocol.setHandler { _, _ in
            return .sse(events: ["[DONE]"])
        }
        let provider = self.makeProvider(model: "gpt-5.2-codex")
        let image = LLMImageAttachmentReference(stagedFilePath: invalidURL.path, mimeType: "text/plain")

        do {
            _ = try await self.collectDeltas(
                from: await provider.generate(
                    messages: [LLMMessage(role: .user, contentParts: [.image(image)])],
                    maxTokens: 32
                )
            )
            XCTFail("Expected unsupported input error")
        } catch let error as CloudProviderError {
            guard case .unsupportedInput(let message) = error else {
                return XCTFail("Unexpected CloudProviderError: \(error)")
            }
            XCTAssertTrue(message.contains("could not read that image"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(CodexProviderMockURLProtocol.requestCount, 0)
    }

    func test_codexProvider_mapsMultiTurnHistoryToUserInputMessages() async throws {
        // Given
        var capturedBody: [String: Any]?
        CodexProviderMockURLProtocol.setHandler { request, _ in
            if let body = self.requestBodyData(from: request) {
                capturedBody = try JSONSerialization.jsonObject(with: body) as? [String: Any]
            }
            return .sse(events: ["[DONE]"])
        }
        let provider = self.makeProvider()

        // When
        _ = try await self.collectDeltas(
            from: await provider.generate(
                messages: [
                    LLMMessage(role: .system, content: "System instruction"),
                    LLMMessage(role: .user, content: "What is on my calendar?"),
                    LLMMessage(role: .assistant, content: "{\"type\":\"tool_call\",\"tool\":\"calendar.query\",\"args\":{}}"),
                    LLMMessage(role: .tool, content: "Tool calendar.query returned: {...}"),
                    LLMMessage(role: .assistant, content: "{\"type\":\"response\",\"text\":\"You have two meetings.\"}"),
                    LLMMessage(role: .user, content: "And tomorrow?"),
                ],
                maxTokens: 64
            )
        )

        // Then
        let input = try XCTUnwrap(capturedBody?["input"] as? [[String: Any]])
        XCTAssertEqual(input.count, 5)
        XCTAssertTrue(input.allSatisfy { ($0["role"] as? String) == "user" })

        let inputTexts: [String] = input.compactMap { message in
            guard
                let content = message["content"] as? [[String: Any]],
                let first = content.first,
                let text = first["text"] as? String
            else { return nil }
            return text
        }
        XCTAssertEqual(inputTexts.count, 5)
        XCTAssertTrue(inputTexts.contains(where: { $0.contains("Previous assistant response:") }))
        XCTAssertTrue(inputTexts.contains(where: { $0.contains("Tool result context:") }))
    }

    func test_codexProvider_resizesLargeImageBeforeUpload() async throws {
        let imageURL = try self.writePNGFixture(width: 4096, height: 2048)
        defer { try? FileManager.default.removeItem(at: imageURL) }

        UserDefaults.standard.openAIDiscoveredModels = [
            OpenAIModelOption(
                identifier: "gpt-5.2-codex",
                source: .discovered,
                supportsImageInput: true,
                supportsImageDetailOriginal: false
            ),
        ]

        var capturedBody: [String: Any]?
        CodexProviderMockURLProtocol.setHandler { request, _ in
            if let body = self.requestBodyData(from: request) {
                capturedBody = try JSONSerialization.jsonObject(with: body) as? [String: Any]
            }
            return .sse(events: ["[DONE]"])
        }
        let provider = self.makeProvider(model: "gpt-5.2-codex")
        let image = LLMImageAttachmentReference(stagedFilePath: imageURL.path, mimeType: "image/png")

        _ = try await self.collectDeltas(
            from: await provider.generate(
                messages: [LLMMessage(role: .user, contentParts: [.image(image)])],
                maxTokens: 32
            )
        )

        let input = try XCTUnwrap(capturedBody?["input"] as? [[String: Any]])
        let content = try XCTUnwrap(input.first?["content"] as? [[String: Any]])
        let dataURL = try XCTUnwrap(content.first?["image_url"] as? String)
        let encodedData = try XCTUnwrap(Data(base64Encoded: String(dataURL.split(separator: ",").last ?? "")))
        let source = try XCTUnwrap(CGImageSourceCreateWithData(encodedData as CFData, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        let width = try XCTUnwrap(properties[kCGImagePropertyPixelWidth] as? Int)
        let height = try XCTUnwrap(properties[kCGImagePropertyPixelHeight] as? Int)
        XCTAssertLessThanOrEqual(width, CodexImageEncoder.maxWidth)
        XCTAssertLessThanOrEqual(height, CodexImageEncoder.maxHeight)
    }

    private func makeProvider(model: String = OpenAIModel.gpt4o.rawValue) -> CodexProvider {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CodexProviderMockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        return CodexProvider(
            model: model,
            credentialProvider: {
                return CodexOAuthCredential(
                    accessToken: "access_token",
                    refreshToken: "refresh_token",
                    accountID: "acct_123",
                    accountEmail: "user@example.com",
                    expiresAt: Date().addingTimeInterval(3600),
                    updatedAt: Date()
                )
            },
            session: session,
            maxRetries: 1,
            baseRetryDelay: 0.01
        )
    }

    private func collectDeltas(from stream: AsyncThrowingStream<LLMDelta, Error>) async throws -> [LLMDelta] {
        var deltas: [LLMDelta] = []
        for try await delta in stream {
            deltas.append(delta)
        }
        return deltas
    }

    private func tokenTexts(in deltas: [LLMDelta]) -> [String] {
        return deltas.compactMap { delta in
            if case .token(let token) = delta {
                return token
            }
            return nil
        }
    }

    private func requestBodyData(from request: URLRequest) -> Data? {
        if let httpBody = request.httpBody {
            return httpBody
        }

        guard let stream = request.httpBodyStream else {
            return nil
        }

        stream.open()
        defer { stream.close() }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)

        while stream.hasBytesAvailable {
            let bytesRead = stream.read(&buffer, maxLength: buffer.count)
            if bytesRead <= 0 {
                break
            }
            data.append(buffer, count: bytesRead)
        }

        return data.isEmpty ? nil : data
    }

    private func writePNGFixture(width: Int, height: Int) throws -> URL {
        let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        let context = try XCTUnwrap(
            CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: bitmapInfo
            )
        )
        context.setFillColor(red: 0.15, green: 0.35, blue: 0.85, alpha: 1.0)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        let image = try XCTUnwrap(context.makeImage())
        let data = NSMutableData()
        let destination = try XCTUnwrap(
            CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)
        )
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))

        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        try (data as Data).write(to: url, options: [.atomic])
        return url
    }
}

private struct CodexProviderMockResponse {
    let statusCode: Int
    let headers: [String: String]
    let bodyChunks: [Data]

    static func sse(events: [String]) -> CodexProviderMockResponse {
        let chunks = events.map { Data("data: \($0)\n\n".utf8) }
        return CodexProviderMockResponse(
            statusCode: 200,
            headers: ["Content-Type": "text/event-stream"],
            bodyChunks: chunks
        )
    }
}

private final class CodexProviderMockURLProtocol: URLProtocol {
    nonisolated(unsafe) private static var lock = NSLock()
    nonisolated(unsafe) private static var handler: ((URLRequest, Int) throws -> CodexProviderMockResponse)?
    nonisolated(unsafe) private static var _requestCount = 0

    static var requestCount: Int {
        return self.lock.withLock { self._requestCount }
    }

    static func setHandler(_ handler: @escaping (URLRequest, Int) throws -> CodexProviderMockResponse) {
        self.lock.withLock {
            self.handler = handler
            self._requestCount = 0
        }
    }

    static func reset() {
        self.lock.withLock {
            self.handler = nil
            self._requestCount = 0
        }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        return true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        return request
    }

    override func startLoading() {
        let index = Self.lock.withLock { () -> Int in
            let current = Self._requestCount
            Self._requestCount += 1
            return current
        }

        let handler = Self.lock.withLock { Self.handler }
        guard let handler else {
            self.client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        do {
            let response = try handler(self.request, index)
            let httpResponse = HTTPURLResponse(
                url: self.request.url ?? URL(string: "https://chatgpt.com/backend-api/codex/responses")!,
                statusCode: response.statusCode,
                httpVersion: nil,
                headerFields: response.headers
            )!
            self.client?.urlProtocol(self, didReceive: httpResponse, cacheStoragePolicy: .notAllowed)
            for chunk in response.bodyChunks {
                self.client?.urlProtocol(self, didLoad: chunk)
            }
            self.client?.urlProtocolDidFinishLoading(self)
        } catch {
            self.client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
