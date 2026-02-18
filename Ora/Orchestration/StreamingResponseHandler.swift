import Foundation

@MainActor
final class StreamingResponseHandler {

    private(set) var isStreaming = false
    private(set) var responseText = ""

    func appendToken(
        _ token: String,
        onStreamStarted: () -> Void,
        onResponseUpdated: (String) -> Void
    ) {
        guard !token.isEmpty else {
            return
        }

        if !self.isStreaming {
            self.isStreaming = true
            self.responseText = ""
            onStreamStarted()
        }

        self.responseText += token
        onResponseUpdated(self.responseText)
    }

    func finish() {
        self.isStreaming = false
    }

    func reset() {
        self.isStreaming = false
        self.responseText = ""
    }
}
