import XCTest
@testable import Ora

final class OraFeatureSetTests: XCTestCase {
    func test_v2Default_enablesOnlyCoreDomains() {
        let featureSet = OraFeatureSet.v2Default

        XCTAssertEqual(featureSet.enabledDomains, [.calendar, .reminders, .contacts, .system])
        XCTAssertTrue(featureSet.deprecatedDomains.isEmpty)
        XCTAssertTrue(featureSet.actionCatalog.actions.allSatisfy { featureSet.enabledDomains.contains($0.domain) })
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
