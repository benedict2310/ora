import XCTest
@testable import OraCore

final class TelemetryPrivacyTests: XCTestCase {
    func test_rendererShowsPublicFieldsButRedactsOrOmitsSensitiveValues() {
        let event = TelemetryEvent(
            name: .inputTextReceived,
            turnID: TelemetryTurnID("turn-privacy"),
            sequenceNumber: 7,
            time: TelemetryTime(rawValue: 4_000),
            level: .info,
            fields: [
                TelemetryField(key: "characterCount", value: .integer(24), visibility: .publicDebug),
                TelemetryField(key: "transcript", value: .string("book a flight to Paris"), visibility: .privateSensitive),
                TelemetryField(key: "prompt", value: .string("system prompt"), visibility: .privateSensitive),
                TelemetryField(key: "audioBuffer", value: .string("pcm-bytes"), visibility: .omitted),
                TelemetryField(key: "userPayload", value: .string("{json:true}"), visibility: .omitted)
            ]
        )

        let rendered = OSTelemetrySink.render(event)

        XCTAssertTrue(rendered.message.contains("characterCount=24"))
        XCTAssertTrue(rendered.message.contains("transcript=<private>"))
        XCTAssertTrue(rendered.message.contains("prompt=<private>"))
        XCTAssertFalse(rendered.message.contains("book a flight to Paris"))
        XCTAssertFalse(rendered.message.contains("system prompt"))
        XCTAssertFalse(rendered.message.contains("audioBuffer"))
        XCTAssertFalse(rendered.message.contains("userPayload"))

        XCTAssertFieldVisibility(rendered.fields[0], visibility: .publicDebug, isVisible: true)
        XCTAssertFieldVisibility(rendered.fields[1], visibility: .privateSensitive, isVisible: false)
        XCTAssertFieldVisibility(rendered.fields[2], visibility: .privateSensitive, isVisible: false)
        XCTAssertFieldVisibility(rendered.fields[3], visibility: .omitted, isVisible: false)
        XCTAssertFieldVisibility(rendered.fields[4], visibility: .omitted, isVisible: false)
    }
}
