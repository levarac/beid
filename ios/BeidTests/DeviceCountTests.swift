// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import XCTest
@testable import Beid

/// beid#154 — the cross-session peer count must count devices, not
/// (device × ENIN window) pairs.
///
/// The proximity identifier rotates every ENIN window by design
/// (`BarnardCoreCrypto.generateRpi(rpik:enin:)` takes `enin`), so accumulating
/// distinct rpids across a session counts windows. `detectedDisplayId` derives
/// from the per-event key (`displayId4(from: tek:)`, no `enin`) and is stable
/// across windows, so it is what a device count must be keyed on.
///
/// Drives the real (non-demo) detection path through
/// `handleDetection(enin:rpid:detectedDisplayId:)`, the same test seam
/// `WindowReportFinalizationTests` uses — demo mode calls `beginRecording`
/// directly and never goes through the counting logic under test here.
@MainActor
final class DeviceCountTests: XCTestCase {
  private func makeCoordinator() -> (SensingCoordinator, WindowReportStore) {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("device-count-test-\(UUID().uuidString)", isDirectory: true)
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    } catch {
      preconditionFailure("Unable to create test directory: \(error)")
    }
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    let store = WindowReportStore(
      fileURL: directory.appendingPathComponent("window-reports.json")
    )
    let coordinator = SensingCoordinator(
      windowReportStore: store,
      selfProofStore: SelfProofStore(
        fileURL: directory.appendingPathComponent("self-proofs.json")
      ),
      unsentWindowLedgerFileURL: directory.appendingPathComponent("ledger.snapshot"),
      sensingCryptography: DeterministicSensingCryptography()
    )
    coordinator.useDemoEventMode = false
    return (coordinator, store)
  }

  /// Observes one device across `windowCount` consecutive ENIN windows, with a
  /// freshly rotated rpid each time — what a single phone parked next to you
  /// actually produces.
  private func observeOneDeviceAcrossWindows(
    _ coordinator: SensingCoordinator,
    device: Int,
    windowCount: Int
  ) {
    for enin in 1...windowCount {
      coordinator.handleDetection(
        enin: enin,
        rpid: DetectionFixture.rotatingRpid(device: device, enin: enin),
        detectedDisplayId: DetectionFixture.displayId(device: device)
      )
    }
  }

  // MARK: - The count itself

  /// The issue's headline case: one device, twelve windows (two people for an
  /// hour at the 300-second default), counted as one device.
  func testSameDeviceAcrossManyWindowsCountsAsOneDevice() {
    let (coordinator, _) = makeCoordinator()
    coordinator.startSensing(eventCode: "TEST-DEVICE-COUNT-ONE-DEVICE")

    observeOneDeviceAcrossWindows(coordinator, device: 0, windowCount: 12)

    XCTAssertEqual(
      coordinator.devicesVerified, 1,
      "one device observed across 12 ENIN windows is one device, not 12 — the rpid rotates every window by design"
    )
  }

  /// Two devices, each seen in every window, must count as two — proving the
  /// fix collapses windows without also collapsing distinct devices.
  func testTwoDevicesEachAcrossManyWindowsCountAsTwoDevices() {
    let (coordinator, _) = makeCoordinator()
    coordinator.startSensing(eventCode: "TEST-DEVICE-COUNT-TWO-DEVICES")

    for enin in 1...6 {
      for device in 0..<2 {
        coordinator.handleDetection(
          enin: enin,
          rpid: DetectionFixture.rotatingRpid(device: device, enin: enin),
          detectedDisplayId: DetectionFixture.displayId(device: device)
        )
      }
    }

    XCTAssertEqual(coordinator.devicesVerified, 2)
  }

  // MARK: - The threshold (beid#154 impact 4)

  /// The exploit the issue calls out: a single device lingering across windows
  /// must never satisfy the "this event is real" threshold on its own. Before
  /// the fix this reached `.recording` on the third window with no second
  /// device ever present.
  func testOneLingeringDeviceNeverSatisfiesTheConfirmThresholdOnItsOwn() {
    let (coordinator, _) = makeCoordinator()
    coordinator.startSensing(eventCode: "TEST-DEVICE-COUNT-THRESHOLD")

    // Comfortably past the threshold in window count, with exactly one device.
    observeOneDeviceAcrossWindows(
      coordinator,
      device: 0,
      windowCount: BeidConfig.eventConfirmThreshold + 3
    )

    guard case .eventFound = coordinator.phase else {
      XCTFail(
        "one device lingering across windows must not confirm the event, got \(coordinator.phase)"
      )
      return
    }
  }

  /// The threshold still fires for genuinely distinct devices, in a single
  /// window — the fix must not make auto-confirm unreachable.
  func testDistinctDevicesInOneWindowStillReachRecording() {
    let (coordinator, _) = makeCoordinator()
    coordinator.startSensing(eventCode: "TEST-DEVICE-COUNT-THRESHOLD-REACHED")

    let threshold = BeidConfig.eventConfirmThreshold
    for device in 0..<threshold {
      coordinator.handleDetection(
        enin: 1,
        rpid: DetectionFixture.rotatingRpid(device: device, enin: 1),
        detectedDisplayId: DetectionFixture.displayId(device: device)
      )
    }

    guard case .recording(_, let peersVerified) = coordinator.phase else {
      XCTFail("expected .recording phase, got \(coordinator.phase)")
      return
    }
    XCTAssertEqual(peersVerified, threshold)
  }

  /// A device first seen in a later window still counts, and the count the
  /// `Proof` carries tracks the device count rather than the window tally.
  func testProofCarriesTheDeviceCountNotTheWindowTally() {
    let (coordinator, _) = makeCoordinator()
    coordinator.startSensing(eventCode: "TEST-DEVICE-COUNT-PROOF")

    var collectedProof: Proof?
    var updates: [Int] = []
    coordinator.onProofCollected = { collectedProof = $0 }
    coordinator.onPeersVerifiedChanged = { _, count in updates.append(count) }

    let threshold = BeidConfig.eventConfirmThreshold
    // Every device present in every window, across four windows.
    for enin in 1...4 {
      for device in 0..<(threshold + 1) {
        coordinator.handleDetection(
          enin: enin,
          rpid: DetectionFixture.rotatingRpid(device: device, enin: enin),
          detectedDisplayId: DetectionFixture.displayId(device: device)
        )
      }
    }

    XCTAssertEqual(collectedProof?.peersVerified, threshold, "the Proof is created at the threshold count")
    XCTAssertEqual(
      updates, [threshold + 1],
      "exactly one in-place update — the fourth device, seen once. Re-observing the same devices in later windows must not update anything"
    )
    XCTAssertEqual(coordinator.devicesVerified, threshold + 1)
  }

  // MARK: - Observations with no display id (beid#154 condition 1)

  /// `detectedDisplayId` comes from a GATT characteristic read that can fail
  /// (Barnard's v2 policy still emits the detection with a null display id).
  /// Such an observation cannot be attributed to a device, so it must not
  /// enter the device count — including when it is the only thing observed.
  func testObservationsWithoutADisplayIdNeverEnterTheDeviceCount() {
    let (coordinator, _) = makeCoordinator()
    coordinator.startSensing(eventCode: "TEST-DEVICE-COUNT-NO-DISPLAY-ID")

    for enin in 1...5 {
      coordinator.handleDetection(
        enin: enin,
        rpid: DetectionFixture.rotatingRpid(device: 0, enin: enin),
        detectedDisplayId: nil
      )
    }

    XCTAssertEqual(
      coordinator.devicesVerified, 0,
      "nothing observed could be attributed to a device"
    )
    guard case .eventFound = coordinator.phase else {
      XCTFail(
        "observations with no display id must not confirm the event, got \(coordinator.phase)"
      )
      return
    }
  }

  /// Dropping them silently would understate coverage as badly as counting
  /// them would overstate it, so they are surfaced as their own count.
  func testObservationsWithoutADisplayIdAreSurfacedSeparately() {
    let (coordinator, _) = makeCoordinator()
    coordinator.startSensing(eventCode: "TEST-DEVICE-COUNT-UNIDENTIFIED-SURFACED")

    for enin in 1...5 {
      coordinator.handleDetection(
        enin: enin,
        rpid: DetectionFixture.rotatingRpid(device: 0, enin: enin),
        detectedDisplayId: nil
      )
    }

    XCTAssertEqual(
      coordinator.unidentifiedObservationCount, 5,
      "five distinct rpids arrived with no display id — itself window-inflated, which is why it is not a device count"
    )
  }

  /// A device whose display id is read on a later attempt was covered after
  /// all: it counts as a device, and stops counting as a coverage gap.
  func testAnRpidLaterSeenWithADisplayIdLeavesTheUnidentifiedCount() {
    let (coordinator, _) = makeCoordinator()
    coordinator.startSensing(eventCode: "TEST-DEVICE-COUNT-LATE-DISPLAY-ID")

    let rpid = DetectionFixture.rotatingRpid(device: 0, enin: 1)
    coordinator.handleDetection(enin: 1, rpid: rpid, detectedDisplayId: nil)
    XCTAssertEqual(coordinator.unidentifiedObservationCount, 1)

    coordinator.handleDetection(
      enin: 1,
      rpid: rpid,
      detectedDisplayId: DetectionFixture.displayId(device: 0)
    )

    XCTAssertEqual(coordinator.devicesVerified, 1)
    XCTAssertEqual(
      coordinator.unidentifiedObservationCount, 0,
      "the same rpid did resolve to a device — it is no longer a coverage gap"
    )
  }

  /// Mixed traffic: identified devices count, unidentified ones do not, and
  /// neither silently absorbs the other.
  func testIdentifiedAndUnidentifiedObservationsAreCountedSeparately() {
    let (coordinator, _) = makeCoordinator()
    coordinator.startSensing(eventCode: "TEST-DEVICE-COUNT-MIXED")

    observeOneDeviceAcrossWindows(coordinator, device: 0, windowCount: 3)
    for enin in 1...3 {
      coordinator.handleDetection(
        enin: enin,
        rpid: DetectionFixture.rotatingRpid(device: 7, enin: enin),
        detectedDisplayId: nil
      )
    }

    XCTAssertEqual(coordinator.devicesVerified, 1)
    XCTAssertEqual(coordinator.unidentifiedObservationCount, 3)
  }

  // MARK: - Display id normalization

  /// Barnard emits lowercase hex today. Case must not split one device into
  /// two if that ever changes upstream.
  func testDisplayIdMatchingIsCaseInsensitive() {
    let (coordinator, _) = makeCoordinator()
    coordinator.startSensing(eventCode: "TEST-DEVICE-COUNT-CASE")

    let displayId = DetectionFixture.displayId(device: 0)
    coordinator.handleDetection(
      enin: 1,
      rpid: DetectionFixture.rotatingRpid(device: 0, enin: 1),
      detectedDisplayId: displayId.lowercased()
    )
    coordinator.handleDetection(
      enin: 2,
      rpid: DetectionFixture.rotatingRpid(device: 0, enin: 2),
      detectedDisplayId: displayId.uppercased()
    )

    XCTAssertEqual(coordinator.devicesVerified, 1)
  }

  // MARK: - Untouched neighbours

  /// `WindowReport.peerCount` counts within one window, where the rpid does
  /// not rotate, so it was already sound. The fix must leave it alone.
  func testWindowReportPeerCountStillCountsRpidsWithinTheWindow() {
    let (coordinator, store) = makeCoordinator()
    coordinator.startSensing(eventCode: "TEST-DEVICE-COUNT-WINDOW-REPORT")

    // Three devices in window 1, the same three in window 2.
    for enin in 1...2 {
      for device in 0..<3 {
        coordinator.handleDetection(
          enin: enin,
          rpid: DetectionFixture.rotatingRpid(device: device, enin: enin),
          detectedDisplayId: DetectionFixture.displayId(device: device)
        )
      }
    }
    coordinator.reset()

    XCTAssertEqual(store.reports.count, 2)
    XCTAssertEqual(
      store.reports.map(\.peerCount), [3, 3],
      "each window saw three peers; per-window counting is rpid-based and unchanged"
    )
  }

  /// Per-session state must not leak into the next session, the same
  /// guarantee `resetSessionState()` already gives the rpid sets.
  func testSessionStateResetsBetweenSessions() {
    let (coordinator, _) = makeCoordinator()
    coordinator.startSensing(eventCode: "TEST-DEVICE-COUNT-RESET-1")

    observeOneDeviceAcrossWindows(coordinator, device: 0, windowCount: 2)
    coordinator.handleDetection(
      enin: 3,
      rpid: DetectionFixture.rotatingRpid(device: 5, enin: 3),
      detectedDisplayId: nil
    )
    XCTAssertEqual(coordinator.devicesVerified, 1)
    XCTAssertEqual(coordinator.unidentifiedObservationCount, 1)

    coordinator.reset()

    XCTAssertEqual(coordinator.devicesVerified, 0)
    XCTAssertEqual(coordinator.unidentifiedObservationCount, 0)
  }
}
