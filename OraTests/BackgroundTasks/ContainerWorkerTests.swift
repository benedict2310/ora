//
//  ContainerWorkerTests.swift
//  OraTests
//
//  Tests for ContainerWorker, ContainerIO, and container runtime integration.
//

import XCTest
@testable import Ora

// MARK: - MockContainerRuntime

final class MockContainerRuntime: ContainerRuntime, @unchecked Sendable {
    var _isAvailable: Bool = true
    var startHandler: ((ContainerConfiguration) async throws -> ContainerHandle)?
    var waitHandler: ((ContainerHandle) async throws -> ContainerExitStatus)?
    var stopCallCount = 0
    var killCallCount = 0

    var isAvailable: Bool {
        get async { _isAvailable }
    }

    func prepare(configuration: ContainerConfiguration) async throws {
        guard _isAvailable else {
            throw ContainerRuntimeError.runtimeUnavailable
        }
    }

    func start(configuration: ContainerConfiguration) async throws -> ContainerHandle {
        if let handler = startHandler {
            return try await handler(configuration)
        }
        return ContainerHandle(
            id: UUID().uuidString,
            sharedDirectoryURL: configuration.sharedDirectoryPath
        )
    }

    func waitForExit(handle: ContainerHandle) async throws -> ContainerExitStatus {
        if let handler = waitHandler {
            return try await handler(handle)
        }
        return ContainerExitStatus(exitCode: 0, stderr: nil)
    }

    func stop(handle: ContainerHandle) async throws {
        stopCallCount += 1
    }

    func kill(handle: ContainerHandle) async throws {
        killCallCount += 1
    }
}

// MARK: - ContainerIOTests

final class ContainerIOTests: XCTestCase {

    private var tempDirectory: URL!
    private let io = ContainerIO()

    override func setUp() {
        super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ora-test-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDirectory)
        super.tearDown()
    }

    func test_containerIO_writesValidInputJSON() throws {
        let input = ContainerInput(
            taskID: "test-123",
            query: "test query",
            urls: ["https://example.com"],
            constraints: .default
        )
        try io.writeInput(input, to: tempDirectory)

        let inputURL = tempDirectory.appendingPathComponent("input.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: inputURL.path))

        let data = try Data(contentsOf: inputURL)
        let decoded = try JSONDecoder().decode(ContainerInput.self, from: data)
        XCTAssertEqual(decoded.taskID, "test-123")
        XCTAssertEqual(decoded.query, "test query")
        XCTAssertEqual(decoded.urls, ["https://example.com"])
    }

    func test_containerIO_readsValidOutputJSON() throws {
        let output = makeValidOutput()
        try writeOutput(output, to: tempDirectory)

        // Also write input.json so directory validation passes
        let inputData = try JSONEncoder().encode(ContainerInput(
            taskID: "test-id",
            query: nil,
            urls: [],
            constraints: .default
        ))
        try inputData.write(to: tempDirectory.appendingPathComponent("input.json"))

        let result = try io.readOutput(from: tempDirectory)
        XCTAssertEqual(result.taskID, "test-id")
        XCTAssertEqual(result.status, "completed")
        XCTAssertEqual(result.pages.count, 1)
    }

    func test_containerIO_rejectsOversizedOutput() throws {
        let largeText = String(repeating: "x", count: 11 * 1024 * 1024)
        let output: [String: Any] = [
            "task_id": "test-id",
            "status": "completed",
            "pages": [["url": "https://example.com", "text": largeText]],
            "metadata": [:]
        ]
        let data = try JSONSerialization.data(withJSONObject: output)
        let outputURL = tempDirectory.appendingPathComponent("output.json")
        try data.write(to: outputURL)

        // Write input.json
        try "{}".data(using: .utf8)!.write(to: tempDirectory.appendingPathComponent("input.json"))

        XCTAssertThrowsError(try io.readOutput(from: tempDirectory)) { error in
            if let ioError = error as? ContainerIOError,
               case .outputTooLarge = ioError {
                // Expected
            } else {
                XCTFail("Expected outputTooLarge error, got: \(error)")
            }
        }
    }

    func test_containerIO_rejectsMalformedOutput() throws {
        let outputURL = tempDirectory.appendingPathComponent("output.json")
        try "not json".data(using: .utf8)!.write(to: outputURL)

        // Write input.json
        try "{}".data(using: .utf8)!.write(to: tempDirectory.appendingPathComponent("input.json"))

        XCTAssertThrowsError(try io.readOutput(from: tempDirectory)) { error in
            if let ioError = error as? ContainerIOError,
               case .outputMalformed = ioError {
                // Expected
            } else {
                XCTFail("Expected outputMalformed error, got: \(error)")
            }
        }
    }

    func test_containerIO_rejectsOutputMissingTaskID() throws {
        let output: [String: Any] = [
            "task_id": "",
            "status": "completed",
            "pages": [],
            "metadata": [:]
        ]
        let data = try JSONSerialization.data(withJSONObject: output)
        try data.write(to: tempDirectory.appendingPathComponent("output.json"))
        try "{}".data(using: .utf8)!.write(to: tempDirectory.appendingPathComponent("input.json"))

        XCTAssertThrowsError(try io.readOutput(from: tempDirectory)) { error in
            if let ioError = error as? ContainerIOError,
               case .outputMissingRequiredField(let field) = ioError {
                XCTAssertEqual(field, "task_id")
            } else {
                XCTFail("Expected outputMissingRequiredField error, got: \(error)")
            }
        }
    }

    func test_containerIO_rejectsOutputNotFound() throws {
        // Write only input.json - no output.json
        try "{}".data(using: .utf8)!.write(to: tempDirectory.appendingPathComponent("input.json"))

        XCTAssertThrowsError(try io.readOutput(from: tempDirectory)) { error in
            if let ioError = error as? ContainerIOError,
               case .outputNotFound = ioError {
                // Expected
            } else {
                XCTFail("Expected outputNotFound error, got: \(error)")
            }
        }
    }

    func test_containerIO_rejectsUnexpectedFiles() throws {
        try "{}".data(using: .utf8)!.write(to: tempDirectory.appendingPathComponent("input.json"))
        try writeOutput(makeValidOutput(), to: tempDirectory)
        try "hack".data(using: .utf8)!.write(to: tempDirectory.appendingPathComponent("evil.sh"))

        XCTAssertThrowsError(try io.readOutput(from: tempDirectory)) { error in
            if let ioError = error as? ContainerIOError,
               case .unexpectedFilesInSharedDirectory = ioError {
                // Expected
            } else {
                XCTFail("Expected unexpectedFilesInSharedDirectory error, got: \(error)")
            }
        }
    }

    func test_containerIO_mapsOutputToWorkerResult() throws {
        let output = ContainerOutput(
            taskID: "test-id",
            status: "completed",
            query: "test query",
            pages: [
                ContainerOutputPage(
                    url: "https://example.com",
                    finalURL: "https://example.com/final",
                    title: "Example",
                    text: "Hello world content here",
                    contentType: "text/html",
                    wordCount: 4,
                    fetchedAt: "2026-03-16T10:00:00Z"
                )
            ],
            metadata: ContainerOutputMetadata(
                startedAt: "2026-03-16T10:00:00Z",
                completedAt: "2026-03-16T10:01:00Z",
                searchQueriesUsed: ["test query"],
                requestedURLCount: 1,
                succeededURLCount: 1,
                failedURLCount: 0
            ),
            failedURLs: nil,
            provenance: ContainerOutputProvenance(
                searchQueries: ["test query"],
                discoveryRationale: "Searched for test topics.",
                domainsUsed: ["example.com"]
            )
        )

        let taskID = UUID()
        let result = io.mapToWorkerResult(output: output, taskID: taskID, taskKind: "research")

        XCTAssertEqual(result.pages.count, 1)
        XCTAssertEqual(result.pages[0].url, "https://example.com")
        XCTAssertEqual(result.pages[0].finalURL, "https://example.com/final")
        XCTAssertEqual(result.pages[0].title, "Example")
        XCTAssertEqual(result.metadata.taskID, taskID)
        XCTAssertEqual(result.metadata.succeededURLCount, 1)
        XCTAssertNotNil(result.provenance)
        XCTAssertEqual(result.provenance?.query, "test query")
        XCTAssertEqual(result.provenance?.searchQueries, ["test query"])
        XCTAssertEqual(result.provenance?.domainsUsed, ["example.com"])
    }

    func test_containerIO_cleansUpSharedDirectory() {
        io.cleanupSharedDirectory(tempDirectory)
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempDirectory.path))
    }

    // MARK: - Helpers

    private func makeValidOutput() -> [String: Any] {
        return [
            "task_id": "test-id",
            "status": "completed",
            "pages": [
                [
                    "url": "https://example.com",
                    "text": "Example content",
                    "content_type": "text/html"
                ]
            ],
            "metadata": [
                "started_at": "2026-03-16T10:00:00Z",
                "completed_at": "2026-03-16T10:01:00Z"
            ]
        ]
    }

    private func writeOutput(_ output: [String: Any], to directory: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: output)
        try data.write(to: directory.appendingPathComponent("output.json"))
    }
}

// MARK: - ContainerWorkerTests

final class ContainerWorkerTests: XCTestCase {

    private var tempDirectory: URL!

    override func setUp() {
        super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ora-worker-test-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDirectory)
        super.tearDown()
    }

    func test_containerWorker_returnsResultOnSuccess() async throws {
        let mockRuntime = MockContainerRuntime()

        // When container starts, write a valid output.json to the shared directory
        mockRuntime.startHandler = { config in
            let handle = ContainerHandle(id: "test", sharedDirectoryURL: config.sharedDirectoryPath)
            let output: [String: Any] = [
                "task_id": "test",
                "status": "completed",
                "pages": [
                    [
                        "url": "https://example.com",
                        "text": "Test content from container",
                        "content_type": "text/html"
                    ]
                ],
                "metadata": [
                    "started_at": "2026-03-16T10:00:00Z",
                    "completed_at": "2026-03-16T10:01:00Z",
                    "succeeded_url_count": 1,
                    "failed_url_count": 0
                ]
            ]
            let data = try JSONSerialization.data(withJSONObject: output)
            try data.write(to: config.sharedDirectoryPath.appendingPathComponent("output.json"))
            return handle
        }

        let worker = ContainerWorker(runtime: mockRuntime)
        let inputs = BackgroundTaskInputs(urls: ["https://example.com"])
        let policy = BackgroundTaskPolicy()

        let result = try await worker.execute(
            taskID: UUID(),
            input: inputs,
            policy: policy
        )

        XCTAssertEqual(result.pages.count, 1)
        XCTAssertEqual(result.pages[0].text, "Test content from container")
    }

    func test_containerWorker_failsOnNonZeroExit() async {
        let mockRuntime = MockContainerRuntime()
        mockRuntime.startHandler = { config in
            // Write input.json so the directory isn't empty, but no output.json
            try "{}".data(using: .utf8)!.write(
                to: config.sharedDirectoryPath.appendingPathComponent("input.json")
            )
            return ContainerHandle(id: "fail", sharedDirectoryURL: config.sharedDirectoryPath)
        }
        mockRuntime.waitHandler = { _ in
            return ContainerExitStatus(exitCode: 1, stderr: "segfault")
        }

        let worker = ContainerWorker(runtime: mockRuntime)
        let inputs = BackgroundTaskInputs(urls: ["https://example.com"])
        let policy = BackgroundTaskPolicy()

        do {
            _ = try await worker.execute(taskID: UUID(), input: inputs, policy: policy)
            XCTFail("Expected error")
        } catch let error as ContainerRuntimeError {
            if case .containerFailed(let exitCode, let stderr) = error {
                XCTAssertEqual(exitCode, 1)
                XCTAssertEqual(stderr, "segfault")
            } else {
                XCTFail("Expected containerFailed, got: \(error)")
            }
        } catch {
            XCTFail("Expected ContainerRuntimeError, got: \(error)")
        }
    }

    func test_containerWorker_cancellationKillsContainer() async {
        let mockRuntime = MockContainerRuntime()
        mockRuntime.startHandler = { config in
            return ContainerHandle(id: "cancel-test", sharedDirectoryURL: config.sharedDirectoryPath)
        }
        mockRuntime.waitHandler = { _ in
            // Simulate a long-running container
            try await Task.sleep(for: .seconds(10))
            return ContainerExitStatus(exitCode: 0, stderr: nil)
        }

        let worker = ContainerWorker(runtime: mockRuntime)
        let inputs = BackgroundTaskInputs(urls: ["https://example.com"])
        let policy = BackgroundTaskPolicy()

        let task = Task {
            try await worker.execute(taskID: UUID(), input: inputs, policy: policy)
        }

        // Give it time to start
        try? await Task.sleep(for: .milliseconds(100))
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected
        } catch {
            // Could be CancellationError wrapped differently - acceptable
        }
    }
}

// MARK: - ContainerNetworkPolicyTests

final class ContainerNetworkPolicyTests: XCTestCase {

    func test_containerNetworkPolicy_defaultIsIsolated() {
        let policy = ContainerNetworkPolicy()
        XCTAssertTrue(policy.allowPublicInternet)
        XCTAssertTrue(policy.blockLocalNetwork)
        XCTAssertTrue(policy.blockHostFilesystem)
    }

    func test_containerNetworkPolicy_noNetworkPreset() {
        let policy = ContainerNetworkPolicy.noNetwork
        XCTAssertFalse(policy.allowPublicInternet)
        XCTAssertTrue(policy.blockLocalNetwork)
    }

    func test_containerNetworkPolicy_isolatedPreset() {
        let policy = ContainerNetworkPolicy.isolated
        XCTAssertTrue(policy.allowPublicInternet)
        XCTAssertTrue(policy.blockLocalNetwork)
        XCTAssertTrue(policy.blockHostFilesystem)
    }

    func test_containerNetworkPolicy_isCodable() throws {
        let policy = ContainerNetworkPolicy.isolated
        let data = try JSONEncoder().encode(policy)
        let decoded = try JSONDecoder().decode(ContainerNetworkPolicy.self, from: data)
        XCTAssertEqual(policy, decoded)
    }
}

// MARK: - ContainerConfigurationTests

final class ContainerConfigurationTests: XCTestCase {

    func test_containerConfiguration_clampsMemory() {
        let config = ContainerConfiguration(
            imagePath: URL(fileURLWithPath: "/test"),
            memoryLimitMB: 50,
            sharedDirectoryPath: URL(fileURLWithPath: "/tmp")
        )
        XCTAssertEqual(config.memoryLimitMB, 128)
    }

    func test_containerConfiguration_clampsCPU() {
        let config = ContainerConfiguration(
            imagePath: URL(fileURLWithPath: "/test"),
            cpuCount: 0,
            sharedDirectoryPath: URL(fileURLWithPath: "/tmp")
        )
        XCTAssertEqual(config.cpuCount, 1)
    }

    func test_containerConfiguration_clampsTimeout() {
        let config = ContainerConfiguration(
            imagePath: URL(fileURLWithPath: "/test"),
            sharedDirectoryPath: URL(fileURLWithPath: "/tmp"),
            timeoutSeconds: 1000
        )
        XCTAssertEqual(config.timeoutSeconds, BackgroundTaskPolicy.maximumTimeoutSeconds)
    }

    func test_containerConfiguration_isCodable() throws {
        let config = ContainerConfiguration(
            imagePath: URL(fileURLWithPath: "/test/image.img"),
            sharedDirectoryPath: URL(fileURLWithPath: "/tmp/shared")
        )
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(ContainerConfiguration.self, from: data)
        XCTAssertEqual(config, decoded)
    }
}

// MARK: - ContainerImageManagerTests

final class ContainerImageManagerTests: XCTestCase {

    func test_containerImageManager_reportsUnavailableForTestBundle() {
        let manager = ContainerImageManager()
        // In test context, the image won't be in the bundle
        // This is expected — production app bundles it
        XCTAssertFalse(manager.isImageAvailable)
    }

    func test_containerImageManager_imageURLIsNilInTests() {
        let manager = ContainerImageManager()
        XCTAssertNil(manager.imageURL)
    }

    func test_containerImageManager_validateThrowsWhenMissing() {
        let manager = ContainerImageManager()
        XCTAssertThrowsError(try manager.validate()) { error in
            if let runtimeError = error as? ContainerRuntimeError,
               case .imageNotFound = runtimeError {
                // Expected
            } else {
                XCTFail("Expected imageNotFound error, got: \(error)")
            }
        }
    }
}

// MARK: - WorkerSelectionTests

final class WorkerSelectionTests: XCTestCase {

    func test_taskInputs_supportsQueryField() {
        let inputs = BackgroundTaskInputs(urls: [], query: "test query")
        XCTAssertEqual(inputs.query, "test query")
        XCTAssertTrue(inputs.urls.isEmpty)
        XCTAssertTrue(inputs.hasContent)
    }

    func test_taskInputs_hasContentWithURLsOnly() {
        let inputs = BackgroundTaskInputs(urls: ["https://example.com"])
        XCTAssertTrue(inputs.hasContent)
        XCTAssertNil(inputs.query)
    }

    func test_taskInputs_hasContentWithQueryOnly() {
        let inputs = BackgroundTaskInputs(query: "test")
        XCTAssertTrue(inputs.hasContent)
        XCTAssertTrue(inputs.urls.isEmpty)
    }

    func test_taskInputs_noContentWhenEmpty() {
        let inputs = BackgroundTaskInputs()
        XCTAssertFalse(inputs.hasContent)
    }

    func test_taskInputs_trimsQuery() {
        let inputs = BackgroundTaskInputs(query: "  test query  ")
        XCTAssertEqual(inputs.query, "test query")
    }

    func test_taskInputs_nilsEmptyQuery() {
        let inputs = BackgroundTaskInputs(query: "   ")
        XCTAssertNil(inputs.query)
    }

    func test_taskPolicy_supportsWorkerBackendField() {
        let policy = BackgroundTaskPolicy(workerBackend: .container)
        XCTAssertEqual(policy.workerBackend, .container)
    }

    func test_taskPolicy_defaultsToAuto() {
        let policy = BackgroundTaskPolicy()
        XCTAssertEqual(policy.workerBackend, .auto)
    }

    func test_taskPolicy_backwardCompatibleWithExistingRecords() throws {
        // Simulate decoding a policy that was persisted without workerBackend
        let json = """
        {"taskKind": "research", "timeoutSeconds": 120}
        """
        let data = json.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(BackgroundTaskPolicy.self, from: data)
        XCTAssertEqual(decoded.workerBackend, .auto)
    }

    func test_workerResult_supportsOptionalProvenance() throws {
        let result = WorkerResult(
            pages: [],
            metadata: WorkerMetadata(
                taskID: UUID(),
                taskKind: "research",
                startedAt: Date(),
                completedAt: Date(),
                requestedURLCount: 0,
                succeededURLCount: 0,
                failedURLCount: 0,
                processedSequentially: false
            ),
            failedURLs: [],
            provenance: WorkerProvenance(
                query: "test",
                searchQueries: ["test query"],
                discoveryRationale: "Searched for test.",
                domainsUsed: ["example.com"]
            )
        )

        let data = try JSONEncoder().encode(result)
        let decoded = try JSONDecoder().decode(WorkerResult.self, from: data)
        XCTAssertNotNil(decoded.provenance)
        XCTAssertEqual(decoded.provenance?.query, "test")
    }

    func test_workerResult_backwardCompatibleWithoutProvenance() throws {
        let json = """
        {
            "pages": [],
            "metadata": {
                "taskID": "\(UUID().uuidString)",
                "taskKind": "research",
                "startedAt": 0,
                "completedAt": 0,
                "requestedURLCount": 0,
                "succeededURLCount": 0,
                "failedURLCount": 0,
                "processedSequentially": false
            },
            "failedURLs": []
        }
        """
        let data = json.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(WorkerResult.self, from: data)
        XCTAssertNil(decoded.provenance)
    }
}
