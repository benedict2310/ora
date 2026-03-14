import XCTest
@testable import Ora

@MainActor
final class TextInputViewTests: XCTestCase {

    func test_enterSubmit_nonEmptyText_submitsAndClearsField() {
        var text = "Plan my day"

        let submitted = TextInputCommandHandler.consumeSubmission(from: &text)

        XCTAssertEqual(submitted, "Plan my day")
        XCTAssertEqual(text, "")
    }

    func test_enterSubmit_emptyText_doesNotSubmit() {
        var text = "   "

        let submitted = TextInputCommandHandler.consumeSubmission(from: &text)

        XCTAssertNil(submitted)
        XCTAssertEqual(text, "   ")
    }

    func test_escapePressed_callsCancelHandler() {
        var didCancel = false

        TextInputCommandHandler.handleEscape {
            didCancel = true
        }

        XCTAssertTrue(didCancel)
    }
}
