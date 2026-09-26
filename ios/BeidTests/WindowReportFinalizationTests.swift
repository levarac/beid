#if DEBUG
// Copyright (c) 2024-2026 Levarac Foundation
// SPDX-License-Identifier: MIT

import XCTest
@testable import Beid

/// `SensingCoordinator`'s explicit-stop window-close fix
/// (`docs/specs/session-end-finalization.md` §3.3/§3.5, sub-slice 1, §8.1).
/// Drives the real (non-demo) detection path via
/// `handleDetection(enin:rpid:detectedDisplayId:)` — a test seam, since `BarnardDetectionEvent`
/// has no public initializer outside the Barnard module — rather than
/// `runDemoSequence`, since demo mode deliberately never produces
/// `WindowReport`s (`SensingCoordinator.advanceDemoWindow()`'s own doc
/// comment).
@MainActor
final class WindowReportFinalizationTests: XCTestCase {
  private func makeCoordinator(
    sensingCryptography: any SensingCryptography = DeterministicSensingCryptography()
  ) -> (SensingCoordinator, WindowReportStore) {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("window-finalization-test-\(UUID().uuidString)", isDirectory: true)
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
      sessionAggregateSnapshotStore: SessionAggregateSnapshotStore(
        fileURL: directory.appendingPathComponent("session-aggregate-snapshots.json")
      ),
      unsentWindowLedgerFileURL: directory.appendingPathComponent("ledger.snapshot"),
      sensingCryptography: sensingCryptography
    )
    // Real (non-demo) path: avoids racing runDemoSequence's own phase
    // transitions against this test's manual handleDetection calls.
    coordinator.useDemoEventMode = false
    return (coordinator, store)
  }

  func testFinalWindowUsesInjectedSignatureWithoutChangingItsBytesOrRecoveryID() {
    let signature = SensingRecoverableSignature(
      r: Data([0x00] + [UInt8](repeating: 0xa1, count: 31)),
      s: Data([0x00, 0x00] + [UInt8](repeating: 0xb2, count: 30)),
      v: 3
    )
    let cryptography = DeterministicSensingCryptography(windowReportSignature: signature)
    let (coordinator, store) = makeCoordinator(sensingCryptography: cryptography)
    coordinator.startSensing(eventCode: "TEST-WINDOW-FACADE")

    // beid#114: a window only signs once the session reaches .recording, so
    // this must cross the confirm threshold — a single peer, as before this
    // fix, would leave the session at .eventFound and produce no report at
    // all, defeating the point of this test.
    let threshold = BeidConfig.eventConfirmThreshold
    for index in 0..<threshold {
      coordinator.handleDetection(
        enin: 7,
        rpid: "peer-\(index)",
        detectedDisplayId: DetectionFixture.displayId(device: index)
      )
    }

    coordinator.reset()

    let report = store.reports.first
    XCTAssertEqual(
      report?.signatureRHex,
      signature.r.map { String(format: "%02x", $0) }.joined()
    )
    XCTAssertEqual(
      report?.signatureSHex,
      signature.s.map { String(format: "%02x", $0) }.joined()
    )
    XCTAssertEqual(report?.signatureV, signature.v)
    XCTAssertEqual(
      cryptography.calls.filter {
        if case .signWindowReport = $0 { return true }
        return false
      }.count,
      1,
      "the final window must be signed exactly once through the injected facade"
    )
  }

  func testSessionThatReachesRecordingWithoutCrossingAWindowBoundaryReportsExactlyOneWindowOnReset() {
    let (coordinator, store) = makeCoordinator()
    coordinator.startSensing(eventCode: "TEST-WINDOW-RECORDING")

    let threshold = BeidConfig.eventConfirmThreshold
    for index in 0..<threshold {
      coordinator.handleDetection(
        enin: 1,
        rpid: "peer-\(index)",
        detectedDisplayId: DetectionFixture.displayId(device: index)
      )
    }

    guard case .recording = coordinator.phase else {
      XCTFail("expected .recording phase, got \(coordinator.phase)")
      return
    }

    coordinator.reset()

    XCTAssertEqual(
      store.reports.count, 1,
      "a session that never crossed a window boundary must still report the one window it did observe"
    )
    XCTAssertEqual(store.reports.first?.enin, 1)
    XCTAssertEqual(store.reports.first?.peerCount, threshold)
  }

  /// beid#114 (`docs/specs/eventfound-window-signing.md` §4): a session that
  /// only ever reaches `.eventFound` — first detection, unconditional,
  /// carries no confirmation — must never sign or persist a window. Before
  /// this fix, `closeFinalWindowIfNeeded()`'s `currentSessionEventCode`
  /// scoping (broader than `currentBindingEvent`, §3.2) let exactly this
  /// scenario slip a real signed artifact out for a session
  /// `shouldConfirmEvent`/`applyScanDetection` never blessed — this test
  /// used to assert that (incorrect) behavior; it now asserts the fix.
  func testSessionThatOnlyReachesEventFoundReportsNothingOnReset() {
    let (coordinator, store) = makeCoordinator()
    coordinator.startSensing(eventCode: "TEST-WINDOW-EVENTFOUND")

    // Strictly below the confirm threshold — stays in .eventFound, never
    // reaches .recording.
    coordinator.handleDetection(
      enin: 1,
      rpid: "peer-0",
      detectedDisplayId: DetectionFixture.displayId(device: 0)
    )

    guard case .eventFound = coordinator.phase else {
      XCTFail("expected .eventFound phase, got \(coordinator.phase)")
      return
    }

    coordinator.reset()

    XCTAssertTrue(
      store.reports.isEmpty,
      "a session that observed a peer but never reached .recording must produce no report at all"
    )
  }

  func testStopSensingThenResetDoesNotDoubleCountTheFinalWindow() {
    let (coordinator, store) = makeCoordinator()
    coordinator.startSensing(eventCode: "TEST-WINDOW-DOUBLE-FINALIZE")

    let threshold = BeidConfig.eventConfirmThreshold
    for index in 0..<threshold {
      coordinator.handleDetection(
        enin: 1,
        rpid: "peer-\(index)",
        detectedDisplayId: DetectionFixture.displayId(device: index)
      )
    }

    coordinator.stopSensing()
    XCTAssertEqual(store.reports.count, 1)

    coordinator.reset()
    XCTAssertEqual(
      store.reports.count, 1,
      "reset() after stopSensing() must not re-close the already-closed window"
    )
  }

  /// beid#134 Decision 1 (`docs/specs/ledger-async-io.md` §4, §7 AC4):
  /// `stopSensing()`/`reset()`/`checkpointOpenWindowForBackgrounding()`
  /// called during the loading window, before any detection has been
  /// queued, must remain safe no-ops — the same nil-state guards
  /// (`currentWindowEnin == nil`, `activeProofId == nil`, ...) these
  /// functions already have for "nothing observed yet" hold unchanged,
  /// since no detection has been processed to populate that state.
  func testExplicitStopAndBackgroundingCheckpointRemainNoOpsDuringLoadingWindow() async {
    for trigger in ["stopSensing", "reset", "checkpointOpenWindowForBackgrounding"] {
      let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("window-finalization-loading-test-\(UUID().uuidString)", isDirectory: true)
      try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      addTeardownBlock { try? FileManager.default.removeItem(at: directory) }

      let coordinator = SensingCoordinator(
        loadingFromDirectory: directory,
        sensingCryptography: DeterministicSensingCryptography()
      )
      coordinator.useDemoEventMode = false

      // No `await` yet: the background load task is guaranteed not to have
      // run, and no detection has been queued or processed.
      XCTAssertTrue(coordinator.isLedgerLoading, "\(trigger): loading must still be in progress immediately after construction")

      switch trigger {
      case "stopSensing":
        coordinator.stopSensing()
      case "reset":
        coordinator.reset()
      case "checkpointOpenWindowForBackgrounding":
        coordinator.checkpointOpenWindowForBackgrounding()
      default:
        XCTFail("unknown trigger \(trigger)")
      }

      XCTAssertEqual(coordinator.phase, .idle, "\(trigger) during the loading window must not crash or leave a non-idle phase")

      await coordinator.waitForLedgerLoadToFinish()

      XCTAssertFalse(coordinator.isLedgerLoading, "\(trigger): loading must still complete normally afterward")
      XCTAssertEqual(coordinator.phase, .idle, "\(trigger): phase must remain idle once loading finishes")
    }
  }

  func testSessionThatNeverObservesAnyPeerReportsNothing() {
    let (coordinator, store) = makeCoordinator()
    coordinator.startSensing(eventCode: "TEST-WINDOW-NO-PEERS")

    coordinator.reset()

    XCTAssertTrue(store.reports.isEmpty, "no window was ever open — nothing to report (§3.7)")
  }

  // MARK: - beid#114 vectors (`docs/specs/eventfound-window-signing.md` §5)

  /// Crossing the confirm threshold *exactly at* an ENIN window boundary —
  /// as opposed to mid-window, already covered by
  /// `testSessionThatReachesRecordingWithoutCrossingAWindowBoundaryReportsExactlyOneWindowOnReset`
  /// above. The confirming detection is also the one that opens a brand new
  /// window; that new window, not the pre-confirmation one before it, must
  /// be the one that ends up signed.
  func testSessionThatCrossesTheThresholdExactlyAtAWindowBoundaryReportsOnlyTheCrossingWindow() {
    let (coordinator, store) = makeCoordinator()
    coordinator.startSensing(eventCode: "TEST-WINDOW-BOUNDARY-CONFIRM")

    let threshold = BeidConfig.eventConfirmThreshold
    // threshold - 1 devices in window 1 — never enough to confirm on their own.
    for index in 0..<(threshold - 1) {
      coordinator.handleDetection(
        enin: 1,
        rpid: "peer-\(index)",
        detectedDisplayId: DetectionFixture.displayId(device: index)
      )
    }
    guard case .eventFound = coordinator.phase else {
      XCTFail("expected .eventFound before the boundary, got \(coordinator.phase)")
      return
    }

    // The threshold-th device arrives in a NEW window (enin 2) — this single
    // detection both crosses the ENIN boundary and confirms the event via
    // the distinct-device arm.
    coordinator.handleDetection(
      enin: 2,
      rpid: "peer-at-boundary",
      detectedDisplayId: DetectionFixture.displayId(device: threshold - 1)
    )
    guard case .recording = coordinator.phase else {
      XCTFail("expected .recording at the boundary-crossing detection, got \(coordinator.phase)")
      return
    }

    coordinator.reset()

    XCTAssertEqual(
      store.reports.count, 1,
      "window 1 (pre-confirmation) must report nothing; only window 2, the crossing window, is ever signed"
    )
    XCTAssertEqual(store.reports.first?.enin, 2)
    XCTAssertEqual(
      store.reports.first?.peerCount, 1,
      "window 2 only ever saw the one boundary-crossing peer"
    )
  }

  /// A `.signalLost` → `resumeSensing()` cycle occurring *after* the
  /// threshold is first crossed must not retroactively sign windows
  /// observed *before* the crossing — only windows from the crossing point
  /// onward, threaded through the signal-lost/resume cycle, ever produce a
  /// report.
  func testSignalLostAndResumeAfterConfirmationNeverRetroactivelySignsPreConfirmationWindows() {
    let (coordinator, store) = makeCoordinator()
    coordinator.startSensing(eventCode: "TEST-WINDOW-SIGNAL-LOST-RESUME")

    // Two pre-confirmation windows, one distinct device each — never crosses
    // the threshold via either arm.
    coordinator.handleDetection(
      enin: 1,
      rpid: "peer-pre-0",
      detectedDisplayId: DetectionFixture.displayId(device: 0)
    )
    coordinator.handleDetection(
      enin: 2,
      rpid: "peer-pre-1",
      detectedDisplayId: DetectionFixture.displayId(device: 1)
    )
    guard case .eventFound = coordinator.phase else {
      XCTFail("expected .eventFound before confirmation, got \(coordinator.phase)")
      return
    }

    // The threshold-th distinct device, in a third window, confirms the
    // event (default threshold 3).
    coordinator.handleDetection(
      enin: 3,
      rpid: "peer-confirming",
      detectedDisplayId: DetectionFixture.displayId(device: 2)
    )
    guard case .recording = coordinator.phase else {
      XCTFail("expected .recording after the third distinct device, got \(coordinator.phase)")
      return
    }

    coordinator.simulateSignalLost()
    coordinator.resumeSensing()

    // Cross one more boundary post-resume so the confirming window (3)
    // closes and reports, and a fresh post-resume window (4) opens.
    coordinator.handleDetection(
      enin: 4,
      rpid: "peer-post-resume",
      detectedDisplayId: DetectionFixture.displayId(device: 3)
    )

    coordinator.reset()

    XCTAssertEqual(
      store.reports.count, 2,
      "only the confirming window (3) and the post-resume window (4) report — the two pre-confirmation windows (1, 2) never do"
    )
    XCTAssertEqual(
      Set(store.reports.map(\.enin)), [3, 4],
      "the signal-lost/resume cycle must not retroactively sign windows 1 or 2"
    )
  }

  /// The pre-existing threshold-of-1 edge case (reachable in production only
  /// via DEBUG `-beid-threshold-override 1`; here via
  /// `BeidConfig.eventConfirmThresholdOverrideForTesting`, since a single
  /// `XCTestCase` cannot relaunch the process with a different launch
  /// argument): `SENSING` can move straight through `EVENT_FOUND` to
  /// `RECORDING` on the very first detection
  /// (`BeidSharedKit.sensing.ScanDetectionResult`'s own doc comment).
  /// Confirms the *same* detection that causes the double phase-move is the
  /// one whose window is allowed to open and eventually sign — not a window
  /// from before it (there is none) and not deferred to a later detection.
  func testThresholdOfOneConfirmsOnTheFirstDetectionAndSignsThatSameWindow() {
    BeidConfig.eventConfirmThresholdOverrideForTesting = 1
    addTeardownBlock { BeidConfig.eventConfirmThresholdOverrideForTesting = nil }

    let (coordinator, store) = makeCoordinator()
    coordinator.startSensing(eventCode: "TEST-WINDOW-THRESHOLD-OF-ONE")

    coordinator.handleDetection(
      enin: 5,
      rpid: "peer-0",
      detectedDisplayId: DetectionFixture.displayId(device: 0)
    )

    guard case .recording = coordinator.phase else {
      XCTFail("expected .recording on the very first detection at threshold 1, got \(coordinator.phase)")
      return
    }

    coordinator.reset()

    XCTAssertEqual(
      store.reports.count, 1,
      "the same detection that confirms the event must be the one whose window signs"
    )
    XCTAssertEqual(store.reports.first?.enin, 5)
    XCTAssertEqual(store.reports.first?.peerCount, 1)
  }
}
#endif
