// Copyright (c) 2024-2026 Levarac Foundation
// SPDX-License-Identifier: MIT

import XCTest
@testable import Beid

/// beid#652 — sensing-time signal strength, for display only.
///
/// Three families of claim live here, and they are different kinds of thing.
///
/// **Arithmetic and gating** (the usability bound, EMA seeding and
/// convergence, redraw coalescing) is ordinary behaviour, tested ordinarily.
///
/// **The phase gate** keeps "sensing-time" literally true and keeps the radar
/// from moving underneath a frozen `.signalLost` count. Note its direction:
/// the phase decides whether the display updates. Signal strength still
/// decides nothing, which is why this gate is not the thing DESIGN.md §2
/// forbids.
///
/// **The separation from the recording path** is the actual point of the
/// issue: signal strength must never enter the record, signing, or submission
/// paths. That guarantee is structural — `handleSignalStrength` is a sibling
/// of `handleDetection`, so no RSSI value is ever in lexical scope inside the
/// recording call tree — and these tests only *witness* it. A test cannot
/// prove the absence of a parameter;
/// `testRecordingPathAloneProducesNoSignalStrength` and
/// `testSignalStrengthAloneChangesNoRecordingState` pin the two observable
/// halves of that separation, and the shape of the code is what actually
/// holds it up.
///
/// Those two pin the **in-memory** half only, at the coordinator's own seam.
/// The **artifact** half — the serialized bytes of the persisted stores, the
/// signature input, and the submission payload — is pinned separately by
/// `ios/BeidTests/SignalStrengthNeverRecordedTests.swift`. Neither file alone
/// covers the guarantee, so anyone deleting or weakening one of them needs to
/// know the other exists rather than concluding it is single-sourced.
///
/// Every test here drives the real path through `handleSignalStrength` /
/// `handleDetection` with plain arguments, the same seam `DeviceCountTests`
/// uses — Barnard's event structs have no public initializer.
///
/// **Tuning constants are read live, never pinned to a literal.**
/// `BeidConfig.nodeSignalSmoothingFactor` and
/// `nodeSignalRedrawMinimumInterval` are documented as unverified on hardware
/// and expected to be retuned; a literal here would turn an honest retune into
/// a red suite. What these tests pin instead is the *formula* and the *gating
/// rule*, which a retune must not change. Where reading a constant live could
/// make a test vacuous (an interval of `0`, an alpha of `0` or `1`), the test
/// asserts the constant is in a range that keeps it meaningful, so a retune
/// that guts the test fails loudly instead of passing silently.
/// `nodeSignalUsableUpperBoundDbm` is the exception: it is not tuning, it is a
/// guard against a proven SDK sentinel, so the tests below name `0`, `127` and
/// a positive value explicitly.
@MainActor
final class NodeSignalStrengthTests: XCTestCase {

  // MARK: - Fixtures

  /// Fixed event-time base. Nothing here reads a wall clock — every timestamp
  /// is derived from this constant and passed in, which is also how the
  /// coalescing tests prove the gate is not reading `Date()`.
  private let baseTimestamp = Date(timeIntervalSince1970: 1_700_000_000)

  private func makeCoordinator() -> SensingCoordinator {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("node-signal-strength-test-\(UUID().uuidString)", isDirectory: true)
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    } catch {
      preconditionFailure("Unable to create test directory: \(error)")
    }
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    let coordinator = SensingCoordinator(
      windowReportStore: WindowReportStore(
        fileURL: directory.appendingPathComponent("window-reports.json")
      ),
      selfProofStore: SelfProofStore(
        fileURL: directory.appendingPathComponent("self-proofs.json")
      ),
      selfProofCheckpointStore: SelfProofCheckpointStore(
        fileURL: directory.appendingPathComponent("self-proof-checkpoint.json")
      ),
      bindingRecordStore: BindingRecordStore(
        fileURL: directory.appendingPathComponent("binding-records.json")
      ),
      sessionAggregateSnapshotStore: SessionAggregateSnapshotStore(
        fileURL: directory.appendingPathComponent("session-aggregate-snapshots.json")
      ),
      unsentWindowLedgerFileURL: directory.appendingPathComponent("ledger.snapshot"),
      sensingCryptography: DeterministicSensingCryptography()
    )
    coordinator.useDemoEventMode = false
    return coordinator
  }

  /// A coordinator already in `.sensing`, which is the precondition for every
  /// arithmetic test in this class now that `handleSignalStrength` is gated to
  /// the sensing phases.
  ///
  /// The phase assertion is not decoration. If `startSensing` ever stopped
  /// landing in a sensing phase, every test built on this helper would gate
  /// its samples out and pass while asserting nothing — the exact failure this
  /// class exists to prevent, arriving through the back door.
  private func makeSensingCoordinator(
    eventCode: String,
    file: StaticString = #filePath,
    line: UInt = #line
  ) -> SensingCoordinator {
    let coordinator = makeCoordinator()
    coordinator.startSensing(eventCode: eventCode)
    guard case .sensing = coordinator.phase else {
      XCTFail(
        "these tests are vacuous unless sensing actually started; got \(coordinator.phase)",
        file: file, line: line
      )
      return coordinator
    }
    return coordinator
  }

  /// Drives real detections until the coordinator reaches `.recording`, using
  /// the live confirm threshold so a retune of that constant does not break
  /// this. One window, distinct devices — the co-presence arm.
  private func driveToRecording(
    _ coordinator: SensingCoordinator,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    for device in 0..<BeidConfig.eventConfirmThreshold {
      coordinator.handleDetection(
        enin: 1,
        rpid: DetectionFixture.rotatingRpid(device: device, enin: 1),
        detectedDisplayId: DetectionFixture.displayId(device: device)
      )
    }
    guard case .recording = coordinator.phase else {
      XCTFail("expected .recording after the confirm threshold, got \(coordinator.phase)", file: file, line: line)
      return
    }
  }

  /// The published dBm for `nodeId`, or `nil` when nothing `.measured` has
  /// been published for it. Deliberately reads the published dictionary
  /// rather than `signalStrength(forNodeId:)`, so a test can distinguish "the
  /// accessor says unmeasured" from "nothing was published" — the two halves
  /// the sentinel test has to separate.
  private func publishedDbm(
    _ coordinator: SensingCoordinator,
    _ nodeId: String
  ) -> Double? {
    guard case .measured(let dBm) = coordinator.nodeSignalStrengths[nodeId] else { return nil }
    return dBm
  }

  /// Asserts that `nodeId` is unmeasured in **both** senses: the accessor
  /// answers `.unmeasured`, and no `.measured` value was ever published for
  /// it. Checking only the accessor would stay green if an unusable sample
  /// were smoothed in and then reported as unmeasured by some other accident.
  private func assertUnmeasured(
    _ coordinator: SensingCoordinator,
    _ nodeId: String,
    _ message: String,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    XCTAssertEqual(
      coordinator.signalStrength(forNodeId: nodeId), .unmeasured,
      "\(message) — signalStrength(forNodeId:) must answer .unmeasured",
      file: file, line: line
    )
    XCTAssertNil(
      publishedDbm(coordinator, nodeId),
      "\(message) — no .measured value may be published for it",
      file: file, line: line
    )
  }

  // MARK: - Usability: what is not a measurement

  /// ★ The sentinel. Barnard's detection path reads
  /// `let rssi = discoveredRssi[id] ?? 0` while `discoveredRssi` is cleared
  /// wholesale with a GATT exchange still in flight, so `rssi: 0` reaches this
  /// app meaning *"never measured"*. 0 dBm is not a plausible BLE received
  /// power. Barnard's own `isUsableRssi` does not guard that fallback, so this
  /// app must.
  ///
  /// **What this pins:** treating `0` as a measurement would place a node that
  /// was never measured at the radar's centre — the strongest possible
  /// proximity claim made from no measurement at all. This test goes RED the
  /// moment someone decides `0` is a number like any other. Its name is what
  /// should stop them deleting it.
  func testZeroRssiIsNotAMeasurement() {
    let coordinator = makeSensingCoordinator(eventCode: "TEST-NODE-SIGNAL-ZERO")
    let node = DetectionFixture.displayId(device: 0)

    coordinator.handleSignalStrength(rssi: 0, detectedDisplayId: node, at: baseTimestamp)

    assertUnmeasured(coordinator, node, "rssi 0 is Barnard's never-measured sentinel")
    XCTAssertTrue(
      coordinator.nodeSignalStrengths.isEmpty,
      "a rejected sample must create no entry at all, under any key"
    )
  }

  /// The other half of the sentinel claim, and the one a naive fix misses:
  /// rejecting `0` for *reporting* while still feeding it to the smoother.
  ///
  /// **What this pins:** if the `0` had seeded the average, the next real
  /// sample would be smoothed against it — `0 + alpha * (-60 - 0)`, i.e.
  /// roughly `-15` at the current alpha — and the node would appear far
  /// closer to the centre than it is, then crawl outward. Asserting the first
  /// real sample seeds *exactly* proves the smoother never saw the sentinel.
  func testZeroRssiDoesNotContaminateTheSmoother() {
    let coordinator = makeSensingCoordinator(eventCode: "TEST-NODE-SIGNAL-ZERO-CONTAMINATION")
    let node = DetectionFixture.displayId(device: 0)

    coordinator.handleSignalStrength(rssi: 0, detectedDisplayId: node, at: baseTimestamp)
    coordinator.handleSignalStrength(
      rssi: -60,
      detectedDisplayId: node,
      at: baseTimestamp.addingTimeInterval(BeidConfig.nodeSignalRedrawMinimumInterval)
    )

    XCTAssertEqual(
      publishedDbm(coordinator, node), -60,
      "the first usable sample must seed exactly; a value between 0 and -60 means the sentinel was smoothed in"
    )
  }

  /// `127` is CoreBluetooth's "RSSI unavailable" marker. Barnard filters it on
  /// the `.rssiUpdate` path via `isUsableRssi`, but this app does not get to
  /// rely on an upstream guard it does not own.
  ///
  /// **What this pins:** a bound written as `rssi != 0` — the cheapest fix
  /// that satisfies the sentinel test alone — admits `127` and would draw an
  /// unavailable reading as an extremely strong signal.
  func testRssi127IsNotAMeasurement() {
    let coordinator = makeSensingCoordinator(eventCode: "TEST-NODE-SIGNAL-127")
    let node = DetectionFixture.displayId(device: 0)

    coordinator.handleSignalStrength(rssi: 127, detectedDisplayId: node, at: baseTimestamp)

    assertUnmeasured(coordinator, node, "127 is CoreBluetooth's unavailable marker, not +127 dBm")
    XCTAssertTrue(coordinator.nodeSignalStrengths.isEmpty)
  }

  /// **What this pins:** a two-value blocklist (`rssi != 0 && rssi != 127`)
  /// passes both tests above and still admits `+20`. The rule is not a list of
  /// known-bad sentinels, it is a bound: received power is negative, and
  /// anything else is not a measurement. Any positive value must be rejected
  /// by the same rule that rejects the two named ones.
  func testPositiveRssiIsNotAMeasurement() {
    let coordinator = makeSensingCoordinator(eventCode: "TEST-NODE-SIGNAL-POSITIVE")
    let node = DetectionFixture.displayId(device: 0)

    coordinator.handleSignalStrength(rssi: 20, detectedDisplayId: node, at: baseTimestamp)

    assertUnmeasured(coordinator, node, "positive received power is not physically plausible over BLE")
    XCTAssertTrue(coordinator.nodeSignalStrengths.isEmpty)
  }

  // MARK: - Identity and the always-answers accessor

  /// **What this pins:** `signalStrength(forNodeId:)` must answer for an id it
  /// has never seen. The cheapest wrong implementations are a force-unwrapped
  /// lookup (which traps, taking the app down over a display value) and a
  /// default of `.measured(dBm: 0)` (which puts an unknown node at the
  /// centre). The second half — asking about an unknown id *while a different
  /// node is measured* — also rules out an accessor that answers with whatever
  /// happens to be in the dictionary.
  func testUnknownNodeIdIsUnmeasured() {
    let coordinator = makeSensingCoordinator(eventCode: "TEST-NODE-SIGNAL-UNKNOWN-ID")

    assertUnmeasured(coordinator, "never-seen-node", "an id with no entry is unmeasured, not an error")

    let known = DetectionFixture.displayId(device: 0)
    coordinator.handleSignalStrength(rssi: -55, detectedDisplayId: known, at: baseTimestamp)

    XCTAssertEqual(
      publishedDbm(coordinator, known), -55,
      "guard against a vacuous test: the known node really is measured"
    )
    assertUnmeasured(
      coordinator, DetectionFixture.displayId(device: 1),
      "an unknown node stays unmeasured even when another node has a value"
    )
  }

  /// A detection with no `detectedDisplayId` is Barnard B003 being
  /// unavailable. It cannot be attributed to a device, so there is no node to
  /// draw and nothing to key on.
  ///
  /// **What this pins:** keying an unattributable sample under a fabricated
  /// placeholder — `""`, `"unknown"`, the rpid — would put a phantom node on
  /// the radar that corresponds to no device. Asserting the whole dictionary
  /// is empty, rather than that one particular key is absent, is what catches
  /// a placeholder nobody predicted.
  func testNilDisplayIdCreatesNoNodeEntry() {
    let coordinator = makeSensingCoordinator(eventCode: "TEST-NODE-SIGNAL-NIL-DISPLAY-ID")

    coordinator.handleSignalStrength(rssi: -55, detectedDisplayId: nil, at: baseTimestamp)

    XCTAssertTrue(
      coordinator.nodeSignalStrengths.isEmpty,
      "an observation with no display id must create no node entry under any key, placeholder or otherwise"
    )
  }

  // MARK: - Smoothing

  /// **What this pins:** the first sample must seed the average directly. The
  /// wrong implementation is the textbook one — initialise the average to zero
  /// and apply the EMA step to the first sample too, giving
  /// `0 + alpha * (-70 - 0)` ≈ `-17.5`. On this radar that starts every node
  /// at the centre and walks it outward over the following seconds: a device
  /// that was never close appears close, then recedes. The ramp is exactly the
  /// `?? 0` failure mode in motion.
  func testFirstUsableSampleSeedsExactlyWithNoRampFromZero() {
    let coordinator = makeSensingCoordinator(eventCode: "TEST-NODE-SIGNAL-SEED")
    let node = DetectionFixture.displayId(device: 0)

    coordinator.handleSignalStrength(rssi: -70, detectedDisplayId: node, at: baseTimestamp)

    XCTAssertEqual(
      publishedDbm(coordinator, node), -70,
      "the first usable sample is the value; anything between 0 and -70 is a ramp from zero"
    )
  }

  /// Feeds a steady input after a seed at a different level and checks the
  /// whole trajectory, not just where it ends up.
  ///
  /// **What this pins, in three separate ways:**
  /// - the *exact* value after one step (`previous + alpha * (sample - previous)`)
  ///   rules out no smoothing at all (which would jump straight to the sample),
  ///   a plain mean of the two, and an alpha applied to the wrong term;
  /// - monotone approach rules out a sign error, which would send the value
  ///   away from the input instead of toward it;
  /// - staying inside the seed/input bracket rules out overshoot, which an
  ///   alpha above 1 or a doubled step would produce and which would make a
  ///   node visibly bounce past its true radius.
  ///
  /// Alpha is read live, so a retune does not break this — but a retune to `0`
  /// (never moves) or `1` (no smoothing) would make every claim here vacuous,
  /// so the range is asserted first.
  func testSmoothingConvergesTowardSteadyInputWithoutOvershooting() {
    let alpha = BeidConfig.nodeSignalSmoothingFactor
    XCTAssertGreaterThan(alpha, 0, "an alpha of 0 would freeze the value and make this test vacuous")
    XCTAssertLessThan(alpha, 1, "an alpha of 1 is no smoothing at all and would make this test vacuous")

    let coordinator = makeSensingCoordinator(eventCode: "TEST-NODE-SIGNAL-CONVERGENCE")
    let node = DetectionFixture.displayId(device: 0)
    let seed = -40.0
    let steady = -80.0
    let interval = BeidConfig.nodeSignalRedrawMinimumInterval

    // Each sample is spaced past the coalescing interval so every step is
    // published and the trajectory is observable. Coalescing is tested
    // separately; here it must not hide a step.
    coordinator.handleSignalStrength(rssi: Int(seed), detectedDisplayId: node, at: baseTimestamp)
    XCTAssertEqual(publishedDbm(coordinator, node), seed)

    coordinator.handleSignalStrength(
      rssi: Int(steady),
      detectedDisplayId: node,
      at: baseTimestamp.addingTimeInterval(interval)
    )
    XCTAssertEqual(
      publishedDbm(coordinator, node) ?? .nan,
      seed + alpha * (steady - seed),
      accuracy: 1e-9,
      "one EMA step must be previous + alpha * (sample - previous)"
    )

    var previous = publishedDbm(coordinator, node) ?? .nan
    for step in 2...40 {
      coordinator.handleSignalStrength(
        rssi: Int(steady),
        detectedDisplayId: node,
        at: baseTimestamp.addingTimeInterval(interval * Double(step))
      )
      let current = publishedDbm(coordinator, node) ?? .nan
      XCTAssertLessThan(current, previous, "step \(step): the value must keep moving toward the input")
      XCTAssertGreaterThanOrEqual(current, steady, "step \(step): must never overshoot past the input")
      previous = current
    }

    XCTAssertEqual(
      previous, steady, accuracy: 0.5,
      "40 steady samples must bring the average essentially onto the input"
    )
  }

  // MARK: - Redraw coalescing

  /// **What this pins:** no coalescing at all — republishing on every sample,
  /// which is what a "simplification" of the gate would restore. The value
  /// withheld here is a real change (a second EMA step), so a test-passing
  /// implementation genuinely has to hold it back rather than happen to
  /// publish the same number.
  func testSampleInsideRedrawIntervalDoesNotRepublish() {
    let interval = BeidConfig.nodeSignalRedrawMinimumInterval
    XCTAssertGreaterThan(interval, 0, "a zero interval would make this test vacuous")

    let coordinator = makeSensingCoordinator(eventCode: "TEST-NODE-SIGNAL-COALESCE-INSIDE")
    let node = DetectionFixture.displayId(device: 0)

    coordinator.handleSignalStrength(rssi: -40, detectedDisplayId: node, at: baseTimestamp)
    XCTAssertEqual(publishedDbm(coordinator, node), -40, "first measurement publishes immediately")

    coordinator.handleSignalStrength(
      rssi: -90,
      detectedDisplayId: node,
      at: baseTimestamp.addingTimeInterval(interval / 2)
    )

    XCTAssertEqual(
      publishedDbm(coordinator, node), -40,
      "a sample inside the coalescing interval must not republish"
    )
  }

  /// **What this pins:** a gate that never reopens — "publish once, then
  /// never again", which passes the inside-interval test above and freezes
  /// every node's radius for the rest of the session.
  ///
  /// It is also, at no extra cost, the proof that the gate reads the
  /// **caller's timestamp and not a wall clock**: these calls are synchronous,
  /// so essentially no real time passes between them. An implementation gated
  /// on `Date()` or a `Timer` would still be inside its interval here and
  /// would fail this test.
  func testSampleAfterRedrawIntervalRepublishes() {
    let interval = BeidConfig.nodeSignalRedrawMinimumInterval
    let coordinator = makeSensingCoordinator(eventCode: "TEST-NODE-SIGNAL-COALESCE-AFTER")
    let node = DetectionFixture.displayId(device: 0)

    coordinator.handleSignalStrength(rssi: -40, detectedDisplayId: node, at: baseTimestamp)
    coordinator.handleSignalStrength(
      rssi: -90,
      detectedDisplayId: node,
      at: baseTimestamp.addingTimeInterval(interval)
    )

    XCTAssertNotEqual(
      publishedDbm(coordinator, node), -40,
      "a sample at or past the interval must republish"
    )
    XCTAssertEqual(
      publishedDbm(coordinator, node) ?? .nan,
      -40.0 + BeidConfig.nodeSignalSmoothingFactor * (-90.0 - (-40.0)),
      accuracy: 1e-9,
      "and it must publish the smoothed value, not the raw sample"
    )
  }

  /// **What this pins, and it is the subtle one:** gating the *smoother*
  /// instead of only the *republish*. Dropping a withheld sample entirely is
  /// the obvious way to implement coalescing and it is wrong — it silently
  /// throws away most of the signal whenever advertisements arrive faster than
  /// the redraw floor, which is the normal case. Only the redraw is coalesced;
  /// every usable sample must still move the average.
  ///
  /// Two samples are withheld here, so the expected value after the gate
  /// reopens is three EMA steps deep. An implementation that discarded them
  /// would publish the one-step value instead.
  func testSampleWithheldByCoalescingStillUpdatesTheSmoothedValue() {
    let alpha = BeidConfig.nodeSignalSmoothingFactor
    let interval = BeidConfig.nodeSignalRedrawMinimumInterval
    XCTAssertGreaterThan(interval, 0, "a zero interval would make this test vacuous")

    let coordinator = makeSensingCoordinator(eventCode: "TEST-NODE-SIGNAL-COALESCE-ACCUMULATES")
    let node = DetectionFixture.displayId(device: 0)

    coordinator.handleSignalStrength(rssi: -40, detectedDisplayId: node, at: baseTimestamp)
    for fraction in [0.25, 0.5] {
      coordinator.handleSignalStrength(
        rssi: -90,
        detectedDisplayId: node,
        at: baseTimestamp.addingTimeInterval(interval * fraction)
      )
    }
    XCTAssertEqual(
      publishedDbm(coordinator, node), -40,
      "both interior samples are withheld from publication"
    )

    coordinator.handleSignalStrength(
      rssi: -90,
      detectedDisplayId: node,
      at: baseTimestamp.addingTimeInterval(interval)
    )

    var expected = -40.0
    for _ in 0..<3 {
      expected += alpha * (-90.0 - expected)
    }
    XCTAssertEqual(
      publishedDbm(coordinator, node) ?? .nan, expected, accuracy: 1e-9,
      "the republished value must reflect all three samples; only the redraw was coalesced, not the measurement"
    )
  }

  /// **What this pins:** applying the coalescing gate unconditionally, so a
  /// node appearing during another node's interval waits up to a full interval
  /// for its first radius. That is not jitter suppression, it is a device the
  /// user can see counted in `devicesVerified` with nothing drawn for it.
  ///
  /// The first node's publish is what arms the gate; the second node's very
  /// first measurement lands well inside it and must still publish.
  func testFirstMeasurementForANodePublishesImmediatelyInsideTheInterval() {
    let interval = BeidConfig.nodeSignalRedrawMinimumInterval
    XCTAssertGreaterThan(interval, 0, "a zero interval would make this test vacuous")

    let coordinator = makeSensingCoordinator(eventCode: "TEST-NODE-SIGNAL-FIRST-PUBLISHES")
    let first = DetectionFixture.displayId(device: 0)
    let second = DetectionFixture.displayId(device: 1)

    coordinator.handleSignalStrength(rssi: -40, detectedDisplayId: first, at: baseTimestamp)
    coordinator.handleSignalStrength(
      rssi: -65,
      detectedDisplayId: second,
      at: baseTimestamp.addingTimeInterval(interval / 10)
    )

    XCTAssertEqual(
      publishedDbm(coordinator, second), -65,
      "a node's first transition out of .unmeasured publishes immediately — a node appearing is not jitter"
    )
    XCTAssertEqual(
      publishedDbm(coordinator, first), -40,
      "and that publish must carry the other node's value along unchanged"
    )
  }

  // MARK: - The phase gate

  /// **What this pins:** no phase gate at all. In `.idle` nothing is drawn, so
  /// folding samples in is at best wasted work and at worst state a later
  /// session inherits if a reset is ever missed. It is also what makes the
  /// acceptance criterion's "sensing-time" literally true.
  ///
  /// Note the direction of this gate, which is the opposite of the one
  /// DESIGN.md §2 forbids: the *phase* decides whether the *display* updates.
  /// Signal strength still decides nothing. Anyone reading this gate as a
  /// rule-13 violation and deleting it will turn this test red, which is the
  /// intended conversation.
  func testIdlePhaseIgnoresSignalStrength() {
    let coordinator = makeCoordinator()
    guard case .idle = coordinator.phase else {
      XCTFail("a fresh coordinator must be .idle for this test to mean anything, got \(coordinator.phase)")
      return
    }
    let node = DetectionFixture.displayId(device: 0)

    coordinator.handleSignalStrength(rssi: -55, detectedDisplayId: node, at: baseTimestamp)

    XCTAssertTrue(
      coordinator.nodeSignalStrengths.isEmpty,
      "a sample arriving while idle must not be folded in"
    )
    assertUnmeasured(coordinator, node, "nothing is sensing, so nothing is measured")
  }

  /// ★ The reason the gate exists at all. `.signalLost` is a **frozen** count
  /// that only an explicit `resumeSensing()` unfreezes, and
  /// `simulateSignalLost()` deliberately does not call `resetSessionState()`.
  ///
  /// **What this pins:** a radar that keeps moving underneath a frozen count —
  /// one screen telling the user two different things about whether anything
  /// is still happening. An ungated implementation folds the `.signalLost`
  /// sample in and the node's radius changes while the number beside it does
  /// not.
  ///
  /// It pins two further wrong implementations that a narrower test would
  /// miss: *clearing* the strengths on signal loss (frozen means the last
  /// values stay on screen, not that they vanish), and making the gate
  /// permanent (after `resumeSensing()` samples must be folded in again).
  func testSignalLostPhaseFreezesSignalStrengthUntilResume() {
    let interval = BeidConfig.nodeSignalRedrawMinimumInterval
    let coordinator = makeSensingCoordinator(eventCode: "TEST-NODE-SIGNAL-FROZEN")
    driveToRecording(coordinator)
    let node = DetectionFixture.displayId(device: 0)

    coordinator.handleSignalStrength(rssi: -40, detectedDisplayId: node, at: baseTimestamp)
    XCTAssertEqual(publishedDbm(coordinator, node), -40, "guard against a vacuous test: recording accepts samples")

    coordinator.simulateSignalLost()
    guard case .signalLost = coordinator.phase else {
      XCTFail("expected .signalLost, got \(coordinator.phase)")
      return
    }

    coordinator.handleSignalStrength(
      rssi: -95,
      detectedDisplayId: node,
      at: baseTimestamp.addingTimeInterval(interval)
    )

    XCTAssertEqual(
      publishedDbm(coordinator, node), -40,
      "the count is frozen in .signalLost, so the radius must be frozen with it — not moving, and not cleared"
    )

    coordinator.resumeSensing()
    coordinator.handleSignalStrength(
      rssi: -95,
      detectedDisplayId: node,
      at: baseTimestamp.addingTimeInterval(interval * 2)
    )

    XCTAssertEqual(
      publishedDbm(coordinator, node) ?? .nan,
      -40.0 + BeidConfig.nodeSignalSmoothingFactor * (-95.0 - (-40.0)),
      accuracy: 1e-9,
      "resuming must unfreeze the display, and must resume from the frozen value rather than reseeding"
    )
  }

  // MARK: - Lifecycle

  /// **What this pins:** clearing only the published dictionary and leaving
  /// the smoother's state behind. That passes a naive "is it empty after
  /// reset" check and still lets last session's value smooth into this
  /// session's first sample, so the first node of a new event appears at a
  /// radius inherited from a different room. Starting a fresh session and
  /// requiring its first sample to seed *exactly* is what detects the
  /// leftover.
  func testSessionResetClearsNodeSignalStrengths() {
    let coordinator = makeSensingCoordinator(eventCode: "TEST-NODE-SIGNAL-RESET")
    let node = DetectionFixture.displayId(device: 0)

    coordinator.handleSignalStrength(rssi: -40, detectedDisplayId: node, at: baseTimestamp)
    XCTAssertEqual(
      publishedDbm(coordinator, node), -40,
      "guard against a vacuous test: there is something to clear"
    )

    coordinator.reset()

    XCTAssertTrue(
      coordinator.nodeSignalStrengths.isEmpty,
      "a finished session's strengths must not be on screen for the next one"
    )
    assertUnmeasured(coordinator, node, "after reset the node is unknown again")

    coordinator.startSensing(eventCode: "TEST-NODE-SIGNAL-RESET-SECOND-SESSION")
    coordinator.handleSignalStrength(
      rssi: -90,
      detectedDisplayId: node,
      at: baseTimestamp.addingTimeInterval(BeidConfig.nodeSignalRedrawMinimumInterval)
    )

    XCTAssertEqual(
      publishedDbm(coordinator, node), -90,
      "the first sample of a new session must seed exactly; a value between -40 and -90 means the smoother kept the old session's state"
    )
  }

  // MARK: - Separation from the recording path (the point of beid#652)

  /// **What this pins:** the recording path acquiring a signal-strength side
  /// effect. `handleDetection` is the whole record/sign/submit call tree's
  /// entrance; driving it must leave the display state untouched, because
  /// `handleSignalStrength` is its sibling and not one of its steps. If anyone
  /// folds the two together — the convenient refactor this design exists to
  /// prevent — this goes RED.
  ///
  /// The `devicesVerified` assertion is a vacuity guard: without it this test
  /// would also pass if `handleDetection` silently did nothing at all.
  ///
  /// Honest limit: this witnesses the observable half. It cannot detect an
  /// `rssi` parameter added to `handleDetection` and left at a defaulted
  /// value. Nothing but the shape of the code prevents that, which is why the
  /// shape is the guarantee and this is a witness.
  func testRecordingPathAloneProducesNoSignalStrength() {
    let coordinator = makeSensingCoordinator(eventCode: "TEST-NODE-SIGNAL-RECORDING-PATH")
    let node = DetectionFixture.displayId(device: 0)

    coordinator.handleDetection(
      enin: 1,
      rpid: DetectionFixture.rotatingRpid(device: 0, enin: 1),
      detectedDisplayId: node
    )

    XCTAssertEqual(
      coordinator.devicesVerified, 1,
      "guard against a vacuous test: the detection really was processed"
    )
    XCTAssertTrue(
      coordinator.nodeSignalStrengths.isEmpty,
      "the recording path must produce no signal strength of its own"
    )
    assertUnmeasured(coordinator, node, "a device can be recorded and counted with no measurement at all")
  }

  /// The converse, and the direction that actually matters: signal strength
  /// must never become evidence.
  ///
  /// **What this pins:** routing `handleSignalStrength` into
  /// `recordDeviceIdentity`, `observe`, or the window ledger — "while we have
  /// the display id here anyway". That would make an RSSI update contribute to
  /// the device count, the session aggregate, and through them to a signed,
  /// submitted record, which is exactly what beid#652 forbids. Many usable
  /// samples for two distinct nodes must move none of it.
  func testSignalStrengthAloneChangesNoRecordingState() {
    let coordinator = makeSensingCoordinator(eventCode: "TEST-NODE-SIGNAL-NO-RECORDING-STATE")
    let phaseBefore = coordinator.phase

    for step in 0..<8 {
      for device in 0..<2 {
        coordinator.handleSignalStrength(
          rssi: -50 - device,
          detectedDisplayId: DetectionFixture.displayId(device: device),
          at: baseTimestamp.addingTimeInterval(
            BeidConfig.nodeSignalRedrawMinimumInterval * Double(step)
          )
        )
      }
    }

    XCTAssertEqual(
      coordinator.nodeSignalStrengths.count, 2,
      "guard against a vacuous test: the samples really were accepted"
    )
    XCTAssertEqual(coordinator.devicesVerified, 0, "signal strength must never count a device")
    XCTAssertNil(coordinator.sessionAggregate, "signal strength must never reach the shared session aggregate")
    XCTAssertEqual(coordinator.unidentifiedRpidCount, 0, "signal strength must never touch identity accounting")
    XCTAssertEqual(coordinator.phase, phaseBefore, "signal strength must never move the scan phase")
  }
}
