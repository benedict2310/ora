import Foundation

struct OraFeatureSet: Sendable, Equatable {
    let enabledDomains: Set<ActionDomain>
    let actionCatalog: ActionCatalog

    static let v2Default = OraFeatureSet(
        enabledDomains: ActionDomain.v2Domains,
        actionCatalog: .v2Default
    )

    func isEnabled(_ domain: ActionDomain) -> Bool {
        self.enabledDomains.contains(domain)
    }
}
