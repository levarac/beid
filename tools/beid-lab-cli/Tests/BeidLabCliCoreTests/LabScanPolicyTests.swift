// SPDX-License-Identifier: MIT

import XCTest

@testable import BeidLabCliCore

/// chk-beid-590 mutated `withServices: [B001]` to `withServices: nil` and the
/// whole suite stayed green. These pin the values; the Python guard pins that
/// `ObserveRunner` actually uses them, because a Swift test cannot see a
/// CoreBluetooth call argument.
final class LabScanPolicyTests: XCTestCase {
  func testTheDiscoveryServiceIsBarnardsB001() {
    XCTAssertEqual(
      LabScanPolicy.discoveryServiceUUIDString, "0000B001-0000-1000-8000-00805F9B34FB")
  }

  /// A 128-bit Bluetooth base UUID with `B001` in the 16-bit slot. Asserted
  /// by shape as well as by value so a transposed digit in the constant is
  /// caught by something other than the reader's eye.
  func testTheServiceUuidHasTheBluetoothBaseShape() {
    let uuid = LabScanPolicy.discoveryServiceUUIDString
    XCTAssertEqual(uuid.count, 36)
    XCTAssertTrue(uuid.hasPrefix("0000"))
    XCTAssertTrue(uuid.hasSuffix("-0000-1000-8000-00805F9B34FB"))
    XCTAssertEqual(uuid.uppercased(), uuid, "CBUUID comparisons are simpler with one case")
  }

  /// Duplicates must not be coalesced: `peer_lost` is the measurement, and a
  /// coalescing radio would make it report the scan's window instead of the
  /// air.
  func testDuplicatesAreNotCoalesced() {
    XCTAssertTrue(LabScanPolicy.allowDuplicates)
  }

  func testTheRationaleNamesTheCaseItProtects() {
    XCTAssertTrue(LabScanPolicy.namedFilterRationale.contains("nil"))
    XCTAssertTrue(LabScanPolicy.namedFilterRationale.contains("overflow"))
  }
}
