import XCTest
@testable import OraCore

func XCTAssertEventNames(
    _ events: [TelemetryEvent],
    _ expectedNames: [TelemetryEventName],
    file: StaticString = #filePath,
    line: UInt = #line
) {
    XCTAssertEqual(events.map(\.name), expectedNames, file: file, line: line)
}

func XCTAssertFieldVisibility(
    _ field: RenderedTelemetryField,
    visibility: TelemetryFieldVisibility,
    isVisible: Bool,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    XCTAssertEqual(field.visibility, visibility, file: file, line: line)
    XCTAssertEqual(field.isVisible, isVisible, file: file, line: line)
}

func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ errorHandler: (Error) -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected expression to throw", file: file, line: line)
    } catch {
        errorHandler(error)
    }
}
