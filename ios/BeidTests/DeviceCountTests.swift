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
      selfProofCheckpointStore: SelfProofCheckpointStore(
        fileURL: directory.appendingPathComponent("self-proof-checkpoint.json")
      ),
      bindingRecordStore: BindingRecordStore(
        fileURL: directory.appendingPathComponent("binding-records.json")
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
  ///
  /// This is the load-bearing test for the whole slice, and under the
  /// disjunctive gate it proves a strictly stronger claim than it used to: the
  /// lingerer must satisfy **neither** arm.
  ///
  /// Confirmation is `co-present || distinct devices`, so the phase staying at
  /// `.eventFound` after many windows is itself proof that both arms are
  /// false. The explicit `devicesVerified` assertion names the device arm's
  /// value so a future reader can see which arm each claim belongs to.
  ///
  /// Either arm could in principle be broken back into a cross-window tally —
  /// the window arm by not clearing at boundaries, the device arm by keying on
  /// the rotating identifier. This test fails in both cases.
  func testOneLingeringDeviceNeverSatisfiesTheConfirmThresholdOnItsOwn() {
    let (coordinator, _) = makeCoordinator()
    coordinator.startSensing(eventCode: "TEST-DEVICE-COUNT-THRESHOLD")

    // Comfortably past the threshold in window count, with exactly one device.
    observeOneDeviceAcrossWindows(
      coordinator,
      device: 0,
      windowCount: BeidConfig.eventConfirmThreshold + 3
    )

    XCTAssertEqual(
      coordinator.devicesVerified, 1,
      "distinct-device arm: one device is one device, however many windows it stays for"
    )
    guard case .eventFound = coordinator.phase else {
      XCTFail(
        "one device lingering across windows must satisfy neither arm, got \(coordinator.phase)"
      )
      return
    }
  }

  /// ★ beid#114 regression vector (`docs/specs/eventfound-window-signing.md`
  /// §6's SUPERSEDED correction). Guards against the specific bug shape a
  /// naive fix for #114 would reintroduce: wrapping the *entire*
  /// `advanceWindowIfNeeded` call — including `currentWindowRpids`'
  /// per-window clearing — in a `phase == .recording` gate, instead of only
  /// gating the ledger sign/persist half.
  ///
  /// If that clearing stopped running before confirmation, this solo
  /// lingering device's rotated rpid (beid#154 — the proximity identifier
  /// rotates every ENIN window by design) would accumulate into a
  /// `currentWindowRpids` nothing ever emptied, one fresh entry per
  /// pre-confirmation window — exactly beid#154's (device × window)
  /// inflation shape, reproduced inside the co-presence arm instead of the
  /// distinct-device count beid#154 fixed. At
  /// `BeidConfig.eventConfirmThreshold + 5` pre-confirmation windows, a
  /// naive implementation would have already falsely confirmed via
  /// co-presence long before this test's final assertion.
  ///
  /// Distinct from `testOneLingeringDeviceNeverSatisfiesTheConfirmThresholdOnItsOwn`
  /// above only in what it makes explicit: that test already fails under this
  /// exact regression (a false `.recording` also satisfies "must satisfy
  /// neither arm"), but does not name the co-presence arm or the ledger
  /// consequence directly. This test asserts both: the phase never moves,
  /// and — the more direct statement of the accepted trade-off in §4 — not
  /// a single `WindowReport` is ever produced, which a naive fix would have
  /// signed and persisted the moment the false confirm fired.
  func testOneLingeringDeviceAcrossManyPreConfirmationWindowsNeverInflatesCoPresenceCount() {
    let (coordinator, store) = makeCoordinator()
    coordinator.startSensing(eventCode: "TEST-DEVICE-COUNT-CO-PRESENCE-REGRESSION")

    let windowCount = BeidConfig.eventConfirmThreshold + 5
    observeOneDeviceAcrossWindows(coordinator, device: 0, windowCount: windowCount)

    guard case .eventFound = coordinator.phase else {
      XCTFail(
        "a solo lingering device across \(windowCount) pre-confirmation windows must never confirm via co-presence, got \(coordinator.phase)"
      )
      return
    }
    XCTAssertEqual(
      coordinator.devicesVerified, 1,
      "the distinct-device arm must also stay at exactly one device"
    )

    coordinator.reset()

    XCTAssertTrue(
      store.reports.isEmpty,
      "no window ever confirmed, so no WindowReport may exist for any of the \(windowCount) windows observed"
    )
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
      coordinator.unidentifiedRpidCount, 5,
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
    XCTAssertEqual(coordinator.unidentifiedRpidCount, 1)

    coordinator.handleDetection(
      enin: 1,
      rpid: rpid,
      detectedDisplayId: DetectionFixture.displayId(device: 0)
    )

    XCTAssertEqual(coordinator.devicesVerified, 1)
    XCTAssertEqual(
      coordinator.unidentifiedRpidCount, 0,
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
    XCTAssertEqual(coordinator.unidentifiedRpidCount, 3)
  }

  // MARK: - The threshold split: confirmation must survive a B003 outage

  /// The co-presence arm, isolated. If every display-id read fails,
  /// `devicesVerified` stays 0, so the distinct-device arm cannot fire and
  /// this can only pass through the window arm — which is exactly what makes
  /// it that arm's dedicated test.
  ///
  /// Three devices in one window is three devices, because the proximity
  /// identifier does not rotate inside a window. Before the split this session
  /// sat on `.eventFound` forever, sensing a crowded room and recording
  /// nothing.
  func testCoPresentDevicesConfirmTheEventEvenWhenEveryDisplayIdReadFails() {
    let (coordinator, _) = makeCoordinator()
    coordinator.startSensing(eventCode: "TEST-SPLIT-B003-OUTAGE")

    let threshold = BeidConfig.eventConfirmThreshold
    for device in 0..<threshold {
      coordinator.handleDetection(
        enin: 1,
        rpid: DetectionFixture.rotatingRpid(device: device, enin: 1),
        detectedDisplayId: nil
      )
    }

    guard case .recording = coordinator.phase else {
      XCTFail(
        "co-present devices must confirm the event without any display id, got \(coordinator.phase)"
      )
      return
    }
  }

  /// The claim shape the recorded proof must carry under that outage: N
  /// identified devices plus M unidentified observations, never one number
  /// pretending to be both.
  func testProofUnderADisplayIdOutageClaimsZeroIdentifiedDevicesNotAFabricatedCount() {
    let (coordinator, _) = makeCoordinator()
    coordinator.startSensing(eventCode: "TEST-SPLIT-CLAIM-SHAPE")

    var collectedProof: Proof?
    coordinator.onProofCollected = { collectedProof = $0 }

    let threshold = BeidConfig.eventConfirmThreshold
    for device in 0..<threshold {
      coordinator.handleDetection(
        enin: 1,
        rpid: DetectionFixture.rotatingRpid(device: device, enin: 1),
        detectedDisplayId: nil
      )
    }

    XCTAssertEqual(
      collectedProof?.peersVerified, 0,
      "no device was identified, so the signed value must say zero rather than borrow the threshold's count"
    )
    XCTAssertEqual(
      coordinator.unidentifiedRpidCount, threshold,
      "the residue is what carries the evidence that something was there"
    )
  }

  /// The split must not hand the defect back through the identifier path. One
  /// device that never yields a display id rotates its identifier every
  /// window, which is exactly the sequence that used to inflate — and it must
  /// still confirm nothing.
  ///
  /// Under the disjunctive gate this too proves **neither** arm fires: the
  /// device arm sits at 0 because nothing was ever identified, and the window
  /// arm sits at 1 because the lingerer is alone in every window. The
  /// unidentified residue climbing to one-per-window while confirming nothing
  /// is the clearest statement that this counter is a coverage signal and not
  /// an input to any decision.
  func testOneUnidentifiedDeviceLingeringAcrossWindowsStillConfirmsNothing() {
    let (coordinator, _) = makeCoordinator()
    coordinator.startSensing(eventCode: "TEST-SPLIT-LINGERING-UNIDENTIFIED")

    let windowCount = BeidConfig.eventConfirmThreshold + 5
    for enin in 1...windowCount {
      coordinator.handleDetection(
        enin: enin,
        rpid: DetectionFixture.rotatingRpid(device: 0, enin: enin),
        detectedDisplayId: nil
      )
    }

    guard case .eventFound = coordinator.phase else {
      XCTFail(
        "one device across many windows is one device, however its identifier rotates, got \(coordinator.phase)"
      )
      return
    }
    XCTAssertEqual(coordinator.devicesVerified, 0)
    XCTAssertEqual(
      coordinator.unidentifiedRpidCount, windowCount,
      "the coverage signal is window-inflated by construction — that is why it is not the device count"
    )
  }

  /// The distinct-device arm, and the reason it exists. Devices seen one at a
  /// time — an arrival trickle, a hallway, a booth — never overlap in a
  /// window, so the co-presence arm alone would decline to record a real
  /// event that the app can plainly see three distinct devices at.
  ///
  /// This confirming loosens no claim: the per-window reports still say
  /// truthfully that each device was alone in its own window. The gate decides
  /// whether to observe; the reports carry what was observed.
  func testDevicesSeenOneAtATimeInSeparateWindowsConfirmViaTheDistinctDeviceArm() {
    let (coordinator, _) = makeCoordinator()
    coordinator.startSensing(eventCode: "TEST-SPLIT-SEQUENTIAL-DEVICES")

    let threshold = BeidConfig.eventConfirmThreshold
    for device in 0..<threshold {
      let enin = device + 1
      coordinator.handleDetection(
        enin: enin,
        rpid: DetectionFixture.rotatingRpid(device: device, enin: enin),
        detectedDisplayId: DetectionFixture.displayId(device: device)
      )
    }

    XCTAssertEqual(coordinator.devicesVerified, threshold)
    guard case .recording(_, let peersVerified) = coordinator.phase else {
      XCTFail(
        "three distinct devices confirm the event even without ever overlapping, got \(coordinator.phase)"
      )
      return
    }
    XCTAssertEqual(peersVerified, threshold)
  }

  /// The window at which the sequential case confirms carries exactly one
  /// device, which is the point of the gate/proof separation: a sparse event
  /// gets recorded, and the record does not pretend the room was full.
  ///
  /// beid#114: every window before the confirming one (devices 0..<threshold-1,
  /// each alone in its own window, none of them ever crossing the threshold)
  /// is strictly pre-confirmation and now produces **no** report at all
  /// (`docs/specs/eventfound-window-signing.md` §4's accepted trade-off) —
  /// only the window open when the threshold-th device confirms the event
  /// (via the distinct-device arm) is ever signed and persisted. Before this
  /// fix, this test asserted `threshold` reports, one per pre-confirmation
  /// window; that was exactly the over-reporting bug #114 closes.
  func testTheWindowReportAtASequentialConfirmationStillShowsOneDevicePerWindow() {
    let (coordinator, store) = makeCoordinator()
    coordinator.startSensing(eventCode: "TEST-SPLIT-SEQUENTIAL-REPORTS")

    let threshold = BeidConfig.eventConfirmThreshold
    for device in 0..<threshold {
      let enin = device + 1
      coordinator.handleDetection(
        enin: enin,
        rpid: DetectionFixture.rotatingRpid(device: device, enin: enin),
        detectedDisplayId: DetectionFixture.displayId(device: device)
      )
    }
    coordinator.reset()

    XCTAssertEqual(
      store.reports.count, 1,
      "only the confirming window (the last one, where the threshold-th device pushed the distinct-device arm over) is ever signed — every earlier, pre-confirmation window produces nothing"
    )
    XCTAssertEqual(
      store.reports.map(\.peerCount), [1],
      "the one reported window saw exactly one device, and says so"
    )
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
    XCTAssertEqual(coordinator.unidentifiedRpidCount, 1)

    coordinator.reset()

    XCTAssertEqual(coordinator.devicesVerified, 0)
    XCTAssertEqual(coordinator.unidentifiedRpidCount, 0)
  }
}
