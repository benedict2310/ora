import Foundation

struct OraFeatureSet: Sendable, Equatable {
    let enabledDomains: Set<ActionDomain>
    let actionCatalog: ActionCatalog

    static let v2Default = OraFeatureSet(
        enabledDomains: ActionDomain.v2Domains,
        actionCatalog: .v2Default
    )

    var deprecatedDomains: Set<ActionDomain> {
        self.enabledDomains.intersection(ActionDomain.deprecatedDomains)
    }

    func isEnabled(_ domain: ActionDomain) -> Bool {
        self.enabledDomains.contains(domain)
    }
}
