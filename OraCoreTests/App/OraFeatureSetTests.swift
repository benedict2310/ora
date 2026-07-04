import XCTest
@testable import OraCore

final class OraFeatureSetTests: XCTestCase {
    func test_v2Default_enablesOnlyCoreDomains() {
        let featureSet = OraFeatureSet.v2Default

        XCTAssertEqual(featureSet.enabledDomains, [.calendar, .reminders, .contacts, .system])
        XCTAssertTrue(featureSet.deprecatedDomains.isEmpty)
        XCTAssertTrue(featureSet.actionCatalog.actions.allSatisfy { featureSet.enabledDomains.contains($0.domain) })
    }

    func test_v2Default_pinsExactActionCatalogContents() {
        let actionNames = OraFeatureSet.v2Default.actionCatalog.actions.map(\.name)

        XCTAssertEqual(
            actionNames,
            [
                "calendar.query",
                "calendar.find_slots",
                "calendar.create",
                "calendar.update",
                "calendar.delete",
                "reminders.list",
                "reminders.create",
                "reminders.update",
                "reminders.complete",
                "reminders.delete",
                "contacts.search",
                "system.open_app",
                "system.open_url",
                "system.open_settings"
            ]
        )
    }

    func test_v2Default_excludesDeprecatedDomains() {
        let featureSet = OraFeatureSet.v2Default

        XCTAssertFalse(featureSet.isEnabled(.memory))
        XCTAssertFalse(featureSet.isEnabled(.skills))
        XCTAssertFalse(featureSet.isEnabled(.research))
        XCTAssertFalse(featureSet.isEnabled(.backgroundTasks))
        XCTAssertFalse(featureSet.isEnabled(.mail))
        XCTAssertFalse(featureSet.isEnabled(.messages))
        XCTAssertFalse(featureSet.isEnabled(.notes))
        XCTAssertFalse(featureSet.isEnabled(.cloud))
        XCTAssertFalse(featureSet.isEnabled(.vision))
        XCTAssertFalse(featureSet.isEnabled(.automation))
    }
}
