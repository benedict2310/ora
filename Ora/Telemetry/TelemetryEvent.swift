import Foundation

struct TelemetryTurnID: RawRepresentable, ExpressibleByStringLiteral, Equatable, Hashable, Sendable {
    let rawValue: String

    init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    init(stringLiteral value: String) {
        self.rawValue = value
    }
}

struct TelemetryTime: RawRepresentable, Equatable, Comparable, Sendable {
    let rawValue: UInt64

    static func < (lhs: TelemetryTime, rhs: TelemetryTime) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

enum TelemetryLevel: String, Sendable {
    case debug
    case info
    case notice
    case error
}

enum TelemetryEventName: String, Sendable {
    case turnStarted = "turn.started"
    case turnCompleted = "turn.completed"
    case turnFailed = "turn.failed"
    case turnCancelled = "turn.cancelled"
    case inputTextReceived = "input.text.received"
    case actionProposalCreated = "action.proposal.created"
    case actionProposalApproved = "action.proposal.approved"
    case actionProposalRejected = "action.proposal.rejected"
    case actionExecutionStarted = "action.execution.started"
    case actionExecutionCompleted = "action.execution.completed"
    case actionExecutionFailed = "action.execution.failed"
    case actionExecutionCancelled = "action.execution.cancelled"
    case auditEntryRecorded = "audit.entry.recorded"
    case ttsSynthesisStarted = "tts.synthesis.started"
    case ttsSynthesisCompleted = "tts.synthesis.completed"
    case ttsSynthesisFailed = "tts.synthesis.failed"
    case ttsSynthesisCancelled = "tts.synthesis.cancelled"
    case ttsPlaybackStarted = "tts.playback.started"
    case ttsPlaybackCompleted = "tts.playback.completed"
    case ttsPlaybackFailed = "tts.playback.failed"
    case ttsPlaybackCancelled = "tts.playback.cancelled"
    case bargeDetected = "barge.detected"
}

enum TelemetryFieldVisibility: Equatable, Sendable {
    case publicDebug
    case privateSensitive
    case omitted
}

enum TelemetryFieldValue: Equatable, Sendable {
    case string(String)
    case integer(Int)
    case bool(Bool)
    case double(Double)
}

struct TelemetryField: Equatable, Sendable {
    let key: String
    let value: TelemetryFieldValue
    let visibility: TelemetryFieldVisibility
}

struct TelemetryEvent: Equatable, Sendable {
    let name: TelemetryEventName
    let turnID: TelemetryTurnID?
    let sequenceNumber: Int
    let time: TelemetryTime
    let level: TelemetryLevel
    let fields: [TelemetryField]
}

enum TelemetrySpanKind: Sendable, Equatable {
    case turn
    case actionExecution
    case ttsSynthesis
    case ttsPlayback

    var startedEventName: TelemetryEventName {
        switch self {
        case .turn:
            return .turnStarted
        case .actionExecution:
            return .actionExecutionStarted
        case .ttsSynthesis:
            return .ttsSynthesisStarted
        case .ttsPlayback:
            return .ttsPlaybackStarted
        }
    }

    var completedEventName: TelemetryEventName {
        switch self {
        case .turn:
            return .turnCompleted
        case .actionExecution:
            return .actionExecutionCompleted
        case .ttsSynthesis:
            return .ttsSynthesisCompleted
        case .ttsPlayback:
            return .ttsPlaybackCompleted
        }
    }

    var failedEventName: TelemetryEventName {
        switch self {
        case .turn:
            return .turnFailed
        case .actionExecution:
            return .actionExecutionFailed
        case .ttsSynthesis:
            return .ttsSynthesisFailed
        case .ttsPlayback:
            return .ttsPlaybackFailed
        }
    }

    var cancelledEventName: TelemetryEventName {
        switch self {
        case .turn:
            return .turnCancelled
        case .actionExecution:
            return .actionExecutionCancelled
        case .ttsSynthesis:
            return .ttsSynthesisCancelled
        case .ttsPlayback:
            return .ttsPlaybackCancelled
        }
    }
}

struct TelemetrySpanToken: Equatable, Sendable {
    let id: Int
    let kind: TelemetrySpanKind
    let turnID: TelemetryTurnID?
}
