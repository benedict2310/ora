import XCTest
@testable import OraCore

final class ActionContractTests: XCTestCase {
    func test_readActionsDoNotRequireConfirmation() async throws {
        let host = ActionHost(catalog: .v2Default)

        let result = try await host.execute(actionNamed: "calendar.query")

        XCTAssertEqual(result, .executed(action: ActionCatalog.v2Default.action(named: "calendar.query")!, summary: "calendar.query executed."))
    }

    func test_mutationActionsRequireProposalUntilApproved() async throws {
        let host = ActionHost(catalog: .v2Default)
        let action = try XCTUnwrap(ActionCatalog.v2Default.action(named: "calendar.create"))

        let proposed = try await host.execute(actionNamed: action.name)
        let proposal = ActionProposal(action: action)
        XCTAssertEqual(proposed, .proposed(proposal))

        let executed = try await host.execute(actionNamed: action.name, approval: .approved(proposal))
        XCTAssertEqual(executed, .executed(action: action, summary: "calendar.create executed."))
    }

    func test_approvalForDifferentProposalDoesNotExecuteMutation() async throws {
        let host = ActionHost(catalog: .v2Default)
        let approvedAction = try XCTUnwrap(ActionCatalog.v2Default.action(named: "calendar.create"))
        let requestedAction = try XCTUnwrap(ActionCatalog.v2Default.action(named: "calendar.delete"))
        let approval = ActionApproval.approved(ActionProposal(action: approvedAction))

        let result = try await host.execute(actionNamed: requestedAction.name, approval: approval)

        XCTAssertEqual(result, .proposed(ActionProposal(action: requestedAction)))
    }

    func test_actionCatalogRejectsUnsupportedActionNames() async {
        let host = ActionHost(catalog: .v2Default)

        await XCTAssertThrowsErrorAsync(try await host.execute(actionNamed: "mail.search")) { error in
            XCTAssertEqual(error as? ActionHostError, .unsupportedAction("mail.search"))
        }
    }
}

private func XCTAssertThrowsErrorAsync<T>(
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
