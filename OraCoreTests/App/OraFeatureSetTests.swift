import XCTest
@testable import OraCore

final class OraFeatureSetTests: XCTestCase {
    func test_v2Default_enablesOnlyCoreDomains() {
        let featureSet = OraFeatureSet.v2Default

        XCTAssertEqual(featureSet.enabledDomains, [.calendar, .reminders, .contacts, .system])
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

    func test_actionDomain_omitsDeprecatedRawValues() {
        XCTAssertNil(ActionDomain(rawValue: "memory"))
        XCTAssertNil(ActionDomain(rawValue: "skills"))
        XCTAssertNil(ActionDomain(rawValue: "research"))
        XCTAssertNil(ActionDomain(rawValue: "backgroundTasks"))
        XCTAssertNil(ActionDomain(rawValue: "mail"))
        XCTAssertNil(ActionDomain(rawValue: "messages"))
        XCTAssertNil(ActionDomain(rawValue: "notes"))
        XCTAssertNil(ActionDomain(rawValue: "cloud"))
        XCTAssertNil(ActionDomain(rawValue: "vision"))
        XCTAssertNil(ActionDomain(rawValue: "automation"))
    }
}

