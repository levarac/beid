// CI ownership contract: this explicit module import is intentionally
// load-bearing. The stale-Swift compile fixture mutates this line to prove
// that CI rejects an obsolete Swift Export module. Do not remove this
// caller-free probe until real shared API callers exist on both Android and iOS.
import BeidSharedKit

struct SharedIdentitySnapshot {
    let value: String
    let authorityType: Any.Type
}

enum SharedRuntimeProbe {
    static func identity() -> SharedIdentitySnapshot {
        let identity = BeidSharedKit.SharedModuleIdentity()
        return SharedIdentitySnapshot(
            value: identity.value,
            authorityType: type(of: identity)
        )
    }

    static func isSharedAuthority(_ type: Any.Type) -> Bool {
        ObjectIdentifier(type) == ObjectIdentifier(BeidSharedKit.SharedModuleIdentity.self)
    }
}
