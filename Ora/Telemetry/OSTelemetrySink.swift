import Foundation
import OSLog

struct RenderedTelemetryField: Equatable, Sendable {
    let key: String
    let renderedValue: String
    let visibility: TelemetryFieldVisibility
    let isVisible: Bool
}

struct RenderedTelemetryEvent: Equatable, Sendable {
    let name: String
    let message: String
    let fields: [RenderedTelemetryField]
}

struct OSTelemetrySink: TelemetrySink {
    private let logger: Logger

    init(
        subsystem: String = "com.ora.app",
        category: String = "telemetry"
    ) {
        self.logger = Logger(subsystem: subsystem, category: category)
    }

    func record(_ event: TelemetryEvent) async {
        let rendered = Self.render(event)

        switch event.level {
        case .debug:
            self.logger.debug("\(rendered.message, privacy: .public)")
        case .info:
            self.logger.info("\(rendered.message, privacy: .public)")
        case .notice:
            self.logger.notice("\(rendered.message, privacy: .public)")
        case .error:
            self.logger.error("\(rendered.message, privacy: .public)")
        }
    }

    static func render(_ event: TelemetryEvent) -> RenderedTelemetryEvent {
        let renderedFields = event.fields.map { field in
            switch field.visibility {
            case .publicDebug:
                return RenderedTelemetryField(
                    key: field.key,
                    renderedValue: field.value.renderedDescription,
                    visibility: .publicDebug,
                    isVisible: true
                )
            case .privateSensitive:
                return RenderedTelemetryField(
                    key: field.key,
                    renderedValue: "<private>",
                    visibility: .privateSensitive,
                    isVisible: false
                )
            case .omitted:
                return RenderedTelemetryField(
                    key: field.key,
                    renderedValue: "<omitted>",
                    visibility: .omitted,
                    isVisible: false
                )
            }
        }

        let fieldSegments = renderedFields
            .filter { $0.visibility != .omitted }
            .map { "\($0.key)=\($0.renderedValue)" }
        let turnIDSegment = event.turnID.map { " turnID=\($0.rawValue)" } ?? ""
        let message = ([event.name.rawValue + turnIDSegment, "seq=\(event.sequenceNumber)"] + fieldSegments)
            .joined(separator: " ")

        return RenderedTelemetryEvent(
            name: event.name.rawValue,
            message: message,
            fields: renderedFields
        )
    }
}

private extension TelemetryFieldValue {
    var renderedDescription: String {
        switch self {
        case .string(let value):
            return value
        case .integer(let value):
            return String(value)
        case .bool(let value):
            return String(value)
        case .double(let value):
            return String(value)
        }
    }
}
