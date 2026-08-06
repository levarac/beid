import BeidSharedKit
import XCTest
@testable import Beid

final class SharedRuntimeProbeTests: XCTestCase {
    private enum NativeShadow {
        final class SharedModuleIdentity {}
    }

    func testAppReadsIdentityFromBeidSharedKit() {
        let identity = SharedRuntimeProbe.identity()

        XCTAssertEqual(identity.value, "beid-shared")
        XCTAssertEqual(
            ObjectIdentifier(identity.authorityType),
            ObjectIdentifier(BeidSharedKit.SharedModuleIdentity.self)
        )
        XCTAssertTrue(SharedRuntimeProbe.isSharedAuthority(identity.authorityType))
        XCTAssertFalse(SharedRuntimeProbe.isSharedAuthority(NativeShadow.SharedModuleIdentity.self))
    }
}
