// Use of this source code is governed by a BSD-style license.

import XCTest

@testable import BeidLabCliCore

/// dispatch#66 asks when emission STOPPED, and a stop is an absence: nothing
/// arrives to log. So the ledger's `lost` output is the measurement, and
/// these tests are about that edge rather than about counting sightings.
final class ObserverLedgerTests: XCTestCase {
  private func ledger() -> ObserverLedger {
    ObserverLedger(lostAfter: 10, repeatEvery: 5)
  }

  func testFirstSightingIsFirstSeen() {
    var ledger = self.ledger()
    XCTAssertEqual(
      ledger.observe(peripheral: "A", at: 0, rssi: -50),
      [.firstSeen(id: "A", at: 0, rssi: -50)]
    )
  }

  func testRepeatSightingsAreRateLimited() {
    var ledger = self.ledger()
    _ = ledger.observe(peripheral: "A", at: 0, rssi: -50)
    XCTAssertEqual(ledger.observe(peripheral: "A", at: 4.9, rssi: -51), [])
    XCTAssertEqual(
      ledger.observe(peripheral: "A", at: 5, rssi: -52),
      [.seen(id: "A", at: 5, rssi: -52)]
    )
    XCTAssertEqual(ledger.observe(peripheral: "A", at: 9.5, rssi: -53), [])
  }

  /// The rate limit must not move the loss deadline. A peripheral seen every
  /// second is alive even though only every fifth sighting is printed.
  func testSuppressedSightingsStillKeepAPeripheralAlive() {
    var ledger = self.ledger()
    _ = ledger.observe(peripheral: "A", at: 0, rssi: -50)
    for t in stride(from: 1.0, through: 14.0, by: 1.0) {
      _ = ledger.observe(peripheral: "A", at: t, rssi: -50)
    }
    XCTAssertEqual(ledger.sweep(at: 20), [])
    XCTAssertEqual(ledger.sweep(at: 24.1), [.lost(id: "A", lastSeenAt: 14, at: 24.1)])
  }

  func testLossIsReportedOnceAfterTheQuietWindow() {
    var ledger = self.ledger()
    _ = ledger.observe(peripheral: "A", at: 0, rssi: -50)
    XCTAssertEqual(ledger.sweep(at: 10), [])
    XCTAssertEqual(ledger.sweep(at: 10.1), [.lost(id: "A", lastSeenAt: 0, at: 10.1)])
    XCTAssertEqual(ledger.sweep(at: 30), [])
  }

  /// Emission that stops and restarts is the case dispatch#66 is actually
  /// about, so a peripheral that comes back opens a new interval rather than
  /// resuming the closed one.
  func testAPeripheralThatComesBackOpensANewInterval() {
    var ledger = self.ledger()
    _ = ledger.observe(peripheral: "A", at: 0, rssi: -50)
    XCTAssertEqual(ledger.sweep(at: 11), [.lost(id: "A", lastSeenAt: 0, at: 11)])
    XCTAssertEqual(
      ledger.observe(peripheral: "A", at: 12, rssi: -60),
      [.firstSeen(id: "A", at: 12, rssi: -60)]
    )
  }

  /// Without this, a phone still advertising when the window ends has a
  /// `first_seen` and no end, and the log cannot be read as intervals at all.
  func testCloseOutEndsEveryOpenIntervalInPeripheralOrder() {
    var ledger = self.ledger()
    _ = ledger.observe(peripheral: "B", at: 1, rssi: -50)
    _ = ledger.observe(peripheral: "A", at: 2, rssi: -50)
    XCTAssertEqual(
      ledger.closeOut(at: 30),
      [.lost(id: "A", lastSeenAt: 2, at: 30), .lost(id: "B", lastSeenAt: 1, at: 30)]
    )
    XCTAssertEqual(ledger.closeOut(at: 31), [])
  }

  func testSweepReportsEveryExpiredPeripheralInOneCall() {
    var ledger = self.ledger()
    _ = ledger.observe(peripheral: "B", at: 0, rssi: -50)
    _ = ledger.observe(peripheral: "A", at: 0, rssi: -50)
    XCTAssertEqual(
      ledger.sweep(at: 11),
      [.lost(id: "A", lastSeenAt: 0, at: 11), .lost(id: "B", lastSeenAt: 0, at: 11)]
    )
  }

  func testDistinctPeripheralCountIgnoresRepeats() {
    var ledger = self.ledger()
    _ = ledger.observe(peripheral: "A", at: 0, rssi: -50)
    _ = ledger.observe(peripheral: "A", at: 6, rssi: -50)
    _ = ledger.observe(peripheral: "B", at: 7, rssi: -50)
    XCTAssertEqual(ledger.distinctPeripheralCount, 2)
  }
}
