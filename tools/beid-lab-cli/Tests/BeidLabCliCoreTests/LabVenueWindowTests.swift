// SPDX-License-Identifier: MIT

import XCTest

@testable import BeidLabCliCore

/// The bounds `venue_ready` prints, on the window of Barnard's signed venue
/// fixture (validFromEnin 6,000,000, relayExpiresAtEnin 6,000,004,
/// validThroughEnin 6,000,010, 300-second ENINs).
final class LabVenueWindowTests: XCTestCase {
  func testValidFromIsTheFirstSecondOfItsEnin() {
    XCTAssertEqual(LabVenueWindow.validFromUnix(validFromEnin: 6_000_000, eninSeconds: 300), 1_800_000_000)
  }

  func testAcceptedThroughIsTheSecondBeforeRelayExpiry() {
    // Phones refuse the envelope once the clock reaches relayExpiresAtEnin.
    XCTAssertEqual(LabVenueWindow.acceptedThroughUnix(relayExpiresAtEnin: 6_000_004, eninSeconds: 300), 1_800_001_199)
  }

  func testValidThroughCanEndAfterPhonesStopAccepting() {
    let accepted = LabVenueWindow.acceptedThroughUnix(relayExpiresAtEnin: 6_000_004, eninSeconds: 300)
    let validThrough = LabVenueWindow.validThroughUnix(validThroughEnin: 6_000_010, eninSeconds: 300)
    XCTAssertEqual(validThrough, 1_800_003_299)
    XCTAssertEqual(validThrough - accepted, 2_100, "an operator switching by validThroughUnix serves 35 refused minutes here")
  }
}
