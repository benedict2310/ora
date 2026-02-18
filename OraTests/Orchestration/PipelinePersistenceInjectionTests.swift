import XCTest
@testable import Ora

@MainActor
final class PipelinePersistenceInjectionTests: XCTestCase {
    func test_makeTestInstance_readsConversationModeFromInjectedPersistence() {
        let persistence = MockPersistenceService(conversationModeEnabled: false)
        let controller = SimplePipelineController.makeTestInstance(persistenceService: persistence)

        XCTAssertFalse(controller.isConversationModeEnabled)
    }
}
