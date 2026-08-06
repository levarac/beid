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
