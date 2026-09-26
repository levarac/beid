#if DEBUG
// Copyright (c) 2024-2026 Levarac Foundation
// SPDX-License-Identifier: MIT

import BeidSharedKit
import Foundation
import XCTest
@testable import Beid

@MainActor
private final class ColdLaunchSubmissionRuntimeSpy: WindowReportSubmissionRuntimeProtocol {
  private(set) var submitPendingCallCount = 0

  func captureAndQueueWindow(
    id _: UUID,
    eventCode _: String,
    eventIdHex _: String?,
    enin _: Int,
    peerRpids _: Set<String>,
    reporterRpid _: String?,
    participantCommitment _: Data?
  ) {}

  func submitPending() {
    submitPendingCallCount += 1
  }

  func submissionState(forEventCode _: String) -> ReportSubmissionState? { nil }
  func excludedWindowCount(forEventCode _: String) -> Int { 0 }
}

@MainActor
final class UnsentWindowLedgerRuntimeTests: XCTestCase {
  func testReportRedeliveryBufferDropsNewestArtifactAtCapacity() throws {
    let first = try makeReport(
      id: XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
    )
    let second = try makeReport(
      id: XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000002"))
    )
    let third = try makeReport(
      id: XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000003"))
    )
    var buffer = WindowReportRedeliveryBuffer(capacity: 2)

    XCTAssertNil(buffer.enqueue(first))
    XCTAssertNil(buffer.enqueue(second))
    XCTAssertEqual(buffer.enqueue(third), third)
    XCTAssertEqual(buffer.reports, [first, second])
  }

  func testSharedReducerOwnsDuplicateCloseForRepeatedNativeInputs() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("beid-ledger-runtime-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let store = try UnsentWindowLedgerStore(
      fileURL: directory.appendingPathComponent("ledger.snapshot")
    )
    let runtime = try UnsentWindowLedgerRuntime(
      store: store,
      ledgerInstanceIdHex: "000102030405060708090a0b0c0d0e0f"
    )

    try runtime.openWindow(windowId: "stable-window-1")
    try runtime.closeWindow(
      windowId: "stable-window-1",
      persistedObservationReference: "observation-1"
    )
    // Native lifecycle coverage below owns the real trigger orderings. This
    // direct shared test is the degenerate companion: once one close changed
    // the ledger, identical close inputs remain idempotent.
    try runtime.closeWindow(
      windowId: "stable-window-1",
      persistedObservationReference: "observation-1"
    )
    try runtime.closeWindow(
      windowId: "stable-window-1",
      persistedObservationReference: "observation-1"
    )

    let durable = try XCTUnwrap(try store.load())
    XCTAssertEqual(durable.persistenceRevision, 2)
    let prepared = BeidSharedKit.report.prepareNextUnsentWindowSubmission(
      ledger: try XCTUnwrap(durable.ledger),
      maximumWindowCount: 10,
      nowEpochMilliseconds: 0
    )
    try store.persist(prepared)
    let restored = try XCTUnwrap(try store.load())
    let submission = try XCTUnwrap(
      BeidSharedKit.report.resumeUnsentWindowSubmissionAfterRestore(
        ledger: try XCTUnwrap(restored.ledger)
      ).submission
    )

    XCTAssertEqual(submission.windowCount, 1)
    XCTAssertEqual(submission.windowIdAt(index: 0), "stable-window-1")
    XCTAssertEqual(submission.observationReferenceAt(index: 0), "observation-1")
  }

  func testEveryNativeEninStopAndBackgroundOrderingClosesEachWindowExactlyOnce() throws {
    let orderings: [[CloseTrigger]] = [
      [.enin, .stop, .background],
      [.enin, .background, .stop],
      [.stop, .enin, .background],
      [.stop, .background, .enin],
      [.background, .enin, .stop],
      [.background, .stop, .enin],
    ]

    // These six sequential orders are exhaustive only while
    // SensingCoordinator and all three entry points are @MainActor-isolated,
    // so close operations cannot overlap. Revisit this test with true
    // concurrency coverage if coordinator isolation or window-closing work
    // moves off MainActor.
    for ordering in orderings {
      let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(
          "beid-ledger-lifecycle-\(ordering.map(\.rawValue).joined(separator: "-"))-\(UUID().uuidString)",
          isDirectory: true
        )
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: directory) }

      let reportStore = WindowReportStore(
        fileURL: directory.appendingPathComponent("window-reports.json")
      )
      let ledgerStore = try UnsentWindowLedgerStore(
        fileURL: directory.appendingPathComponent("ledger.snapshot")
      )
      let runtime = try UnsentWindowLedgerRuntime(
        store: ledgerStore,
        ledgerInstanceIdHex: "000102030405060708090a0b0c0d0e0f"
      )
      let selfProofStore = SelfProofStore(
        fileURL: directory.appendingPathComponent("self-proofs.json")
      )
      let selfProofCheckpointStore = SelfProofCheckpointStore(
        fileURL: directory.appendingPathComponent("self-proof-checkpoint.json")
      )
      let bindingRecordStore = BindingRecordStore(
        fileURL: directory.appendingPathComponent("binding-records.json")
      )
      let sessionAggregateSnapshotStore = SessionAggregateSnapshotStore(
        fileURL: directory.appendingPathComponent("session-aggregate-snapshots.json")
      )
      let coordinator = SensingCoordinator(
        windowReportStore: reportStore,
        selfProofStore: selfProofStore,
        selfProofCheckpointStore: selfProofCheckpointStore,
        bindingRecordStore: bindingRecordStore,
        sessionAggregateSnapshotStore: sessionAggregateSnapshotStore,
        unsentWindowLedgerRuntime: runtime,
        sensingCryptography: DeterministicSensingCryptography()
      )
      coordinator.useDemoEventMode = false
      coordinator.startSensing(eventCode: "TEST-SHARED-ORDERING")
      // beid#114: window 1 must be confirmed (reach `.recording`) before any
      // of the three closing triggers below run, or its close would be
      // silently skipped as unconfirmed rather than exercising the
      // exactly-once-close race this test is actually about.
      let threshold = BeidConfig.eventConfirmThreshold
      for index in 0..<threshold {
        coordinator.handleDetection(
          enin: 1,
          rpid: "peer-original-\(index)",
          detectedDisplayId: DetectionFixture.displayId(device: index)
        )
      }
      guard case .recording = coordinator.phase else {
        XCTFail("expected .recording before the close-trigger ordering (\(ordering.description)), got \(coordinator.phase)")
        continue
      }

      for trigger in ordering {
        apply(trigger, to: coordinator)
      }

      let eninIndex = try XCTUnwrap(ordering.firstIndex(of: .enin))
      let stopIndex = try XCTUnwrap(ordering.firstIndex(of: .stop))
      let eninPrecedesStop = eninIndex < stopIndex
      let expectedReportCount = eninPrecedesStop ? 2 : 1
      XCTAssertEqual(
        reportStore.reports.filter { $0.enin == 1 }.count,
        1,
        ordering.description
      )
      XCTAssertEqual(
        reportStore.reports.filter { $0.enin == 2 }.count,
        eninPrecedesStop ? 1 : 0,
        ordering.description
      )
      XCTAssertEqual(reportStore.reports.count, expectedReportCount, ordering.description)
      XCTAssertEqual(Set(reportStore.reports.map(\.id)).count, expectedReportCount, ordering.description)
      XCTAssertEqual(coordinator.phase, .idle, ordering.description)

      let durable = try XCTUnwrap(try ledgerStore.load(), ordering.description)
      let prepared = BeidSharedKit.report.prepareNextUnsentWindowSubmission(
        ledger: try XCTUnwrap(durable.ledger, ordering.description),
        maximumWindowCount: 10,
        nowEpochMilliseconds: 0
      )
      XCTAssertTrue(prepared.changed, ordering.description)
      try ledgerStore.persist(prepared)
      let inFlight = try XCTUnwrap(try ledgerStore.load(), ordering.description)
      let submission = try XCTUnwrap(
        BeidSharedKit.report.resumeUnsentWindowSubmissionAfterRestore(
          ledger: try XCTUnwrap(inFlight.ledger, ordering.description)
        ).submission,
        ordering.description
      )

      let reportReferences = Set(reportStore.reports.map { $0.id.uuidString.lowercased() })
      let ledgerReferences = Set((0..<submission.windowCount).compactMap { index in
        let windowId = submission.windowIdAt(index: Int32(index))
        XCTAssertEqual(
          windowId,
          submission.observationReferenceAt(index: Int32(index)),
          ordering.description
        )
        return windowId
      })
      XCTAssertEqual(Int(submission.windowCount), expectedReportCount, ordering.description)
      XCTAssertEqual(ledgerReferences, reportReferences, ordering.description)
    }
  }

  func testUnavailableLedgerDoesNotBlockPeerCountingOrRecordingTransition() {
    let directory = temporaryDirectory(named: "unavailable-ledger")
    defer { try? FileManager.default.removeItem(at: directory) }
    let reportStore = WindowReportStore(
      fileURL: directory.appendingPathComponent("window-reports.json")
    )
    let coordinator = SensingCoordinator(
      windowReportStore: reportStore,
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
      unsentWindowLedgerRuntime: nil,
      sensingCryptography: DeterministicSensingCryptography()
    )
    coordinator.useDemoEventMode = false
    coordinator.startSensing(eventCode: "TEST-LEDGER-UNAVAILABLE")

    for index in 0..<BeidConfig.eventConfirmThreshold {
      coordinator.handleDetection(
        enin: 1,
        rpid: "peer-\(index)",
        detectedDisplayId: DetectionFixture.displayId(device: index)
      )
    }

    guard case .recording(_, let peersVerified) = coordinator.phase else {
      XCTFail("ledger availability must not gate sensing, got \(coordinator.phase)")
      return
    }
    XCTAssertEqual(peersVerified, BeidConfig.eventConfirmThreshold)
  }

  // beid#131: `unsentWindowLedgerRuntime` is a `let` — once construction
  // fails it stays `nil` for the rest of the process with nothing queryable
  // recording when or why. This asserts `ledgerHealth` is degraded from the
  // instant a construction failure is threaded in, before any operation
  // runs.
  func testLedgerHealthReflectsConstructionFailureFromTheStart() {
    let directory = temporaryDirectory(named: "ledger-health-construction-failure")
    defer { try? FileManager.default.removeItem(at: directory) }
    let reportStore = WindowReportStore(
      fileURL: directory.appendingPathComponent("window-reports.json")
    )
    let constructionFailure = UnsentWindowLedgerRuntimeError.rejectedTransition(
      "simulated_construction_failure"
    )

    let coordinator = SensingCoordinator(
      windowReportStore: reportStore,
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
      unsentWindowLedgerRuntime: nil,
      sensingCryptography: DeterministicSensingCryptography(),
      initialLedgerFailure: constructionFailure
    )

    XCTAssertTrue(coordinator.ledgerHealth.isDegraded)
    XCTAssertNotNil(coordinator.ledgerHealth.degradationReason)
    XCTAssertNotNil(coordinator.ledgerHealth.degradedSince)
  }

  // beid#131: an operational persist failure on an otherwise-live runtime
  // (as opposed to a construction failure) must also surface as degraded,
  // and a device that degrades once must not have that fact overwritten by
  // a later, unrelated failure — `since` has to stay pinned to the first
  // occurrence so "how long has this been broken" survives.
  func testLedgerHealthReflectsOperationalPersistFailureAndLatchesSinceTheFirstOccurrence() throws {
    let fixture = try makeRuntimeFixture(named: "ledger-health-operational-failure")
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    XCTAssertFalse(fixture.coordinator.ledgerHealth.isDegraded)

    fixture.coordinator.startSensing(eventCode: "TEST-LEDGER-HEALTH-OPEN-FAILURE")

    // beid#114: the ledger lifecycle only starts once `.recording` begins,
    // so reach that first — while the ledger is still healthy — before
    // corrupting it. Otherwise window 1's `openWindow` is simply skipped as
    // unconfirmed rather than attempted and failing.
    //
    // Corrupting the ledger snapshot file's bytes directly (rather than
    // `RecoverableReportFailureFixture.blockLedgerWrites()`, which replaces
    // the ledger's *parent directory* with a plain file) is required here:
    // by the time confirmation succeeds, `ensureLedgerWindowOpen()` has
    // already created that parent as a real directory containing a real
    // snapshot, so `blockLedgerWrites()` would fail outright trying to
    // overwrite a directory with a file, rather than simulating a write
    // failure.
    let threshold = BeidConfig.eventConfirmThreshold
    for index in 0..<threshold {
      fixture.coordinator.handleDetection(
        enin: 1,
        rpid: "peer-confirming-\(index)",
        detectedDisplayId: DetectionFixture.displayId(device: index)
      )
    }
    guard case .recording = fixture.coordinator.phase else {
      XCTFail("expected .recording before corrupting the ledger, got \(fixture.coordinator.phase)")
      return
    }
    XCTAssertFalse(
      fixture.coordinator.ledgerHealth.isDegraded,
      "the ledger must still be healthy before it's corrupted"
    )

    try Data("corrupt-ledger".utf8).write(to: fixture.ledgerFileURL, options: .atomic)

    // Crossing an ENIN boundary now closes the already-confirmed window 1 —
    // the ledger-runtime close (and window 2's own open, right after) both
    // fail against the corrupt file, which is this test's "operational
    // persist failure on an otherwise-live runtime".
    fixture.coordinator.handleDetection(
      enin: 2,
      rpid: "peer-triggering-close-failure",
      detectedDisplayId: DetectionFixture.displayId(device: threshold)
    )

    XCTAssertTrue(fixture.coordinator.ledgerHealth.isDegraded)
    XCTAssertNotNil(fixture.coordinator.ledgerHealth.degradationReason)
    let firstFailureSince = try XCTUnwrap(fixture.coordinator.ledgerHealth.degradedSince)

    Thread.sleep(forTimeInterval: 0.05)
    fixture.coordinator.handleDetection(
      enin: 3,
      rpid: "peer-triggering-a-second-later-failure",
      detectedDisplayId: DetectionFixture.displayId(device: threshold + 1)
    )

    XCTAssertTrue(fixture.coordinator.ledgerHealth.isDegraded)
    XCTAssertEqual(
      fixture.coordinator.ledgerHealth.degradedSince,
      firstFailureSince,
      "since must latch to the first failure, not move on a later one"
    )
  }

  func testFailedLedgerCloseAtEninBoundaryStillAcceptsTheTriggeringObservation() throws {
    let fixture = try makeRuntimeFixture(named: "failed-enin-close")
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    fixture.coordinator.startSensing(eventCode: "TEST-FAILED-ENIN-CLOSE")

    // beid#114: window 1 must be confirmed (reach `.recording`) before it
    // crosses the ENIN boundary below, or its close would be silently
    // skipped as unconfirmed rather than genuinely attempted and failing
    // against the corrupt ledger — which is the scenario this test is about.
    let peersBeforeBoundary = BeidConfig.eventConfirmThreshold
    for index in 0..<peersBeforeBoundary {
      fixture.coordinator.handleDetection(
        enin: 1,
        rpid: "peer-\(index)",
        detectedDisplayId: DetectionFixture.displayId(device: index)
      )
    }
    guard case .recording = fixture.coordinator.phase else {
      XCTFail("expected .recording before corrupting the ledger, got \(fixture.coordinator.phase)")
      return
    }
    let originalWindowId = try XCTUnwrap(fixture.coordinator.currentWindowIdForTesting)
    try Data("corrupt-ledger".utf8).write(to: fixture.ledgerFileURL, options: .atomic)

    fixture.coordinator.handleDetection(
      enin: 2,
      rpid: "peer-at-boundary",
      detectedDisplayId: DetectionFixture.displayId(device: 90)
    )

    XCTAssertEqual(fixture.reportStore.reports.count, 1)
    XCTAssertEqual(fixture.reportStore.reports.first?.enin, 1)
    XCTAssertEqual(fixture.reportStore.reports.first?.peerCount, peersBeforeBoundary)
    XCTAssertNotEqual(fixture.coordinator.currentWindowIdForTesting, originalWindowId)
    // Acceptance is asserted on the device count directly rather than through
    // a `.recording` transition. This test is about a ledger failure not
    // dropping an observation, and it used the phase as a proxy for that.
    // beid#154 made the confirm gate a policy decision with two arms and an
    // open product default, so the phase now depends on something this test
    // does not care about. The device count is the direct measure of "the
    // observation was accepted", carries the same numbers the phase payload
    // did, and stays correct whichever way that policy lands.
    XCTAssertEqual(fixture.coordinator.devicesVerified, peersBeforeBoundary + 1)

    fixture.coordinator.handleDetection(
      enin: 2,
      rpid: "peer-after-boundary",
      detectedDisplayId: DetectionFixture.displayId(device: 91)
    )
    XCTAssertEqual(
      fixture.coordinator.devicesVerified, peersBeforeBoundary + 2,
      "same-ENIN intake must continue after ledger failure"
    )
  }

  func testFailedCheckpointCloseDoesNotDropLaterSameEninObservations() throws {
    let fixture = try makeRuntimeFixture(named: "failed-checkpoint-close")
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    fixture.coordinator.startSensing(eventCode: "TEST-FAILED-CHECKPOINT-CLOSE")

    // beid#114: confirm first, so the checkpoint's close is genuinely
    // attempted (and fails) against the corrupt ledger, rather than being
    // silently skipped as unconfirmed.
    let threshold = BeidConfig.eventConfirmThreshold
    for index in 0..<threshold {
      fixture.coordinator.handleDetection(
        enin: 1,
        rpid: "peer-\(index)",
        detectedDisplayId: DetectionFixture.displayId(device: index)
      )
    }
    guard case .recording = fixture.coordinator.phase else {
      XCTFail("expected .recording before corrupting the ledger, got \(fixture.coordinator.phase)")
      return
    }
    let originalWindowId = try XCTUnwrap(fixture.coordinator.currentWindowIdForTesting)
    try Data("corrupt-ledger".utf8).write(to: fixture.ledgerFileURL, options: .atomic)

    fixture.coordinator.checkpointOpenWindowForBackgrounding()

    XCTAssertEqual(fixture.reportStore.reports.count, 1)
    XCTAssertNil(fixture.coordinator.currentWindowIdForTesting)
    for offset in 0..<threshold {
      fixture.coordinator.handleDetection(
        enin: 1,
        rpid: "peer-post-checkpoint-\(offset)",
        detectedDisplayId: DetectionFixture.displayId(device: threshold + offset)
      )
    }

    XCTAssertNotNil(fixture.coordinator.currentWindowIdForTesting)
    XCTAssertNotEqual(fixture.coordinator.currentWindowIdForTesting, originalWindowId)
    // Same substitution as the ENIN-boundary test above, and this one has a
    // second reason of its own: the checkpoint clears the current window's
    // identifier set along with the rest of the window state, so the
    // co-presence arm legitimately restarts from empty here. The subject of
    // this test is that post-checkpoint observations are still taken in after
    // a ledger failure, which the device count states directly.
    XCTAssertEqual(
      fixture.coordinator.devicesVerified, threshold * 2,
      "post-checkpoint observations must continue after ledger failure"
    )
  }

  func testSessionEndAlwaysTearsDownAfterLedgerCloseFailure() throws {
    for action in SessionEndAction.allCases {
      let fixture = try makeRuntimeFixture(named: "failed-\(action.rawValue)")
      defer { try? FileManager.default.removeItem(at: fixture.directory) }
      fixture.coordinator.startSensing(eventCode: "TEST-FAILED-\(action.rawValue)")

      // beid#114: confirm first, so the session-end close is genuinely
      // attempted (and fails) against the corrupt ledger, rather than being
      // silently skipped as unconfirmed.
      let threshold = BeidConfig.eventConfirmThreshold
      for index in 0..<threshold {
        fixture.coordinator.handleDetection(
          enin: 1,
          rpid: "peer-\(index)",
          detectedDisplayId: DetectionFixture.displayId(device: index)
        )
      }
      guard case .recording = fixture.coordinator.phase else {
        XCTFail("expected .recording before corrupting the ledger (\(action.rawValue))")
        continue
      }
      try Data("corrupt-ledger".utf8).write(to: fixture.ledgerFileURL, options: .atomic)

      apply(action, to: fixture.coordinator)

      XCTAssertEqual(fixture.coordinator.phase, .idle, action.rawValue)
      XCTAssertNil(fixture.coordinator.currentWindowIdForTesting, action.rawValue)
      XCTAssertEqual(fixture.reportStore.reports.count, 1, action.rawValue)
      apply(action, to: fixture.coordinator)
      XCTAssertEqual(fixture.reportStore.reports.count, 1, action.rawValue)
    }
  }

  func testReportWriteFailureAtRolloverRedeliversFrozenWindowWithoutNextEninPeers() throws {
    let fixture = try makeRecoverableReportFailureFixture(named: "report-failure-rollover")
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    fixture.coordinator.startSensing(eventCode: "TEST-REPORT-FAILURE-ROLLOVER")

    // beid#114: confirm within window 1 before blocking report writes, or
    // its close would be silently skipped as unconfirmed rather than
    // genuinely attempted and failing to write.
    let threshold = BeidConfig.eventConfirmThreshold
    for index in 0..<threshold {
      fixture.coordinator.handleDetection(
        enin: 1,
        rpid: "peer-enin-1-\(index)",
        detectedDisplayId: DetectionFixture.displayId(device: index)
      )
    }
    guard case .recording = fixture.coordinator.phase else {
      XCTFail("expected .recording before blocking report writes, got \(fixture.coordinator.phase)")
      return
    }
    let firstWindowId = try XCTUnwrap(fixture.coordinator.currentWindowIdForTesting)
    try fixture.blockReportWrites()

    fixture.coordinator.handleDetection(
      enin: 2,
      rpid: "peer-enin-2",
      detectedDisplayId: DetectionFixture.displayId(device: threshold)
    )

    let secondWindowId = try XCTUnwrap(fixture.coordinator.currentWindowIdForTesting)
    XCTAssertNotEqual(secondWindowId, firstWindowId)
    XCTAssertTrue(fixture.reportStore.reports.isEmpty)

    try fixture.restoreReportWrites()
    fixture.coordinator.checkpointOpenWindowForBackgrounding()

    let firstReport = try XCTUnwrap(
      fixture.reportStore.reports.first { $0.id == firstWindowId }
    )
    let secondReport = try XCTUnwrap(
      fixture.reportStore.reports.first { $0.id == secondWindowId }
    )
    XCTAssertEqual(firstReport.enin, 1)
    XCTAssertEqual(
      firstReport.peerCount,
      threshold,
      "the frozen ENIN-1 report must exclude the RPID first seen in ENIN 2"
    )
    XCTAssertEqual(secondReport.enin, 2)
    XCTAssertEqual(secondReport.peerCount, 1)

    let durable = try XCTUnwrap(try fixture.ledgerStore.load())
    for report in fixture.reportStore.reports {
      let duplicateClose = BeidSharedKit.report.closeUnsentWindow(
        ledger: try XCTUnwrap(durable.ledger),
        windowId: report.id.uuidString.lowercased(),
        persistedObservationReference: report.id.uuidString.lowercased()
      )
      XCTAssertTrue(duplicateClose.isSuccess)
      XCTAssertFalse(duplicateClose.changed, "redelivery must already have ledger-closed each report")
    }
  }

  func testUnknownWindowAtRedeliveryHeadIsDiscardedBeforeLaterArtifact() throws {
    let fixture = try makeRecoverableReportFailureFixture(named: "unknown-window-redelivery-head")
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    fixture.coordinator.startSensing(eventCode: "TEST-UNKNOWN-WINDOW-REDELIVERY")
    try fixture.blockLedgerWrites()

    // beid#114: confirm within window 1, with the ledger already blocked, so
    // the confirming detection's own ledger-open attempt genuinely fails
    // (reproducing "orphaned" — a window the ledger never learned was ever
    // open) rather than being silently skipped as unconfirmed.
    let threshold = BeidConfig.eventConfirmThreshold
    for index in 0..<threshold {
      fixture.coordinator.handleDetection(
        enin: 1,
        rpid: "peer-orphaned-\(index)",
        detectedDisplayId: DetectionFixture.displayId(device: index)
      )
    }
    guard case .recording = fixture.coordinator.phase else {
      XCTFail("expected .recording before restoring ledger writes, got \(fixture.coordinator.phase)")
      return
    }
    let orphanedWindowId = try XCTUnwrap(fixture.coordinator.currentWindowIdForTesting)

    try fixture.restoreLedgerWrites()
    try fixture.blockReportWrites()
    fixture.coordinator.handleDetection(
      enin: 2,
      rpid: "peer-recoverable",
      detectedDisplayId: DetectionFixture.displayId(device: threshold)
    )
    let recoverableWindowId = try XCTUnwrap(fixture.coordinator.currentWindowIdForTesting)
    fixture.coordinator.handleDetection(
      enin: 3,
      rpid: "peer-after-queue",
      detectedDisplayId: DetectionFixture.displayId(device: threshold + 1)
    )
    XCTAssertTrue(fixture.reportStore.reports.isEmpty)

    try fixture.restoreReportWrites()
    fixture.coordinator.handleDetection(
      enin: 4,
      rpid: "peer-drain-trigger",
      detectedDisplayId: DetectionFixture.displayId(device: threshold + 2)
    )

    let orphanedReport = try XCTUnwrap(
      fixture.reportStore.reports.first { $0.id == orphanedWindowId }
    )
    let recoverableReport = try XCTUnwrap(
      fixture.reportStore.reports.first { $0.id == recoverableWindowId }
    )
    let durable = try XCTUnwrap(try fixture.ledgerStore.load())
    let orphanedClose = BeidSharedKit.report.closeUnsentWindow(
      ledger: try XCTUnwrap(durable.ledger),
      windowId: orphanedWindowId.uuidString.lowercased(),
      persistedObservationReference: orphanedReport.id.uuidString.lowercased()
    )
    XCTAssertFalse(orphanedClose.isSuccess)
    XCTAssertEqual(orphanedClose.errorCode, "unknown_window_id")

    let recoverableClose = BeidSharedKit.report.closeUnsentWindow(
      ledger: try XCTUnwrap(durable.ledger),
      windowId: recoverableWindowId.uuidString.lowercased(),
      persistedObservationReference: recoverableReport.id.uuidString.lowercased()
    )
    XCTAssertTrue(recoverableClose.isSuccess)
    XCTAssertFalse(
      recoverableClose.changed,
      "an unknown head must not block the later recoverable artifact from ledger close"
    )
  }

  func testTransientLedgerCloseRejectionRetainsRedeliveryHeadForLaterRetry() throws {
    let directory = temporaryDirectory(named: "transient-ledger-close-redelivery")
    defer { try? FileManager.default.removeItem(at: directory) }
    let reportStore = WindowReportStore(
      fileURL: directory.appendingPathComponent("window-reports.json")
    )
    let runtime = TransientCloseRejectionLedgerRuntime()
    let coordinator = SensingCoordinator(
      windowReportStore: reportStore,
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
      unsentWindowLedgerRuntime: runtime,
      sensingCryptography: DeterministicSensingCryptography()
    )
    let queuedReport = try makeReport(
      id: XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000004"))
    )
    let queuedWindowId = queuedReport.id.uuidString.lowercased()
    coordinator.enqueueWindowReportForRedeliveryForTesting(queuedReport)

    runtime.rejectNextClose(windowId: queuedWindowId)
    coordinator.redeliverPendingWindowReportsForTesting()

    XCTAssertEqual(runtime.closeAttempts[queuedWindowId], 1)
    XCTAssertFalse(runtime.closedWindowIds.contains(queuedWindowId))
    XCTAssertNotNil(reportStore.reports.first { report in
      report.id.uuidString.lowercased() == queuedWindowId
    })

    coordinator.redeliverPendingWindowReportsForTesting()

    XCTAssertEqual(
      runtime.closeAttempts[queuedWindowId],
      2,
      "a non-terminal ledger rejection must retain the head for a later retry"
    )
    XCTAssertTrue(runtime.closedWindowIds.contains(queuedWindowId))
  }

  func testReportWriteFailureAtStopStillTearsDownAndRedeliversOnLaterDetection() throws {
    let fixture = try makeRecoverableReportFailureFixture(named: "report-failure-stop")
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    fixture.coordinator.startSensing(eventCode: "TEST-REPORT-FAILURE-STOP")

    // beid#114: confirm first, so stopSensing()'s close is genuinely
    // attempted (and fails to write) rather than being silently skipped as
    // unconfirmed.
    let threshold = BeidConfig.eventConfirmThreshold
    for index in 0..<threshold {
      fixture.coordinator.handleDetection(
        enin: 1,
        rpid: "peer-before-stop-\(index)",
        detectedDisplayId: DetectionFixture.displayId(device: index)
      )
    }
    guard case .recording = fixture.coordinator.phase else {
      XCTFail("expected .recording before blocking report writes, got \(fixture.coordinator.phase)")
      return
    }
    let stoppedWindowId = try XCTUnwrap(fixture.coordinator.currentWindowIdForTesting)
    try fixture.blockReportWrites()

    fixture.coordinator.stopSensing()

    XCTAssertEqual(fixture.coordinator.phase, .idle)
    XCTAssertNil(fixture.coordinator.currentWindowIdForTesting)
    XCTAssertTrue(fixture.reportStore.reports.isEmpty)

    try fixture.restoreReportWrites()
    fixture.coordinator.startSensing(eventCode: "TEST-REPORT-FAILURE-STOP-LATER")
    fixture.coordinator.handleDetection(
      enin: 2,
      rpid: "peer-later",
      detectedDisplayId: DetectionFixture.displayId(device: threshold)
    )

    let report = try XCTUnwrap(
      fixture.reportStore.reports.first { $0.id == stoppedWindowId }
    )
    let durable = try XCTUnwrap(try fixture.ledgerStore.load())
    let duplicateClose = BeidSharedKit.report.closeUnsentWindow(
      ledger: try XCTUnwrap(durable.ledger),
      windowId: stoppedWindowId.uuidString.lowercased(),
      persistedObservationReference: report.id.uuidString.lowercased()
    )
    XCTAssertTrue(duplicateClose.isSuccess)
    XCTAssertFalse(duplicateClose.changed, "the later detection must redeliver the parked report")
  }

  func testReportWriteFailureUntilProcessDeathDiscardsOpenWindowWithoutOrphanSubmission() throws {
    let fixture = try makeRecoverableReportFailureFixture(named: "report-failure-process-death")
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    fixture.coordinator.startSensing(eventCode: "TEST-REPORT-FAILURE-PROCESS-DEATH")

    // beid#114: confirm first, so this genuinely exercises a report-write
    // failure surviving to process death, rather than an unconfirmed window
    // that was never known to the ledger for an unrelated reason.
    let threshold = BeidConfig.eventConfirmThreshold
    for index in 0..<threshold {
      fixture.coordinator.handleDetection(
        enin: 1,
        rpid: "peer-before-death-\(index)",
        detectedDisplayId: DetectionFixture.displayId(device: index)
      )
    }
    guard case .recording = fixture.coordinator.phase else {
      XCTFail("expected .recording before blocking report writes, got \(fixture.coordinator.phase)")
      return
    }
    let lostWindowId = try XCTUnwrap(fixture.coordinator.currentWindowIdForTesting)
    try fixture.blockReportWrites()
    fixture.coordinator.stopSensing()
    XCTAssertTrue(fixture.reportStore.reports.isEmpty)

    try fixture.restoreReportWrites()
    let relaunchedReports = WindowReportStore(fileURL: fixture.reportFileURL)
    let relaunchedLedgerStore = try UnsentWindowLedgerStore(fileURL: fixture.ledgerFileURL)
    _ = SensingCoordinator(
      windowReportStore: relaunchedReports,
      selfProofStore: SelfProofStore(
        fileURL: fixture.directory.appendingPathComponent("relaunched-self-proofs.json")
      ),
      selfProofCheckpointStore: SelfProofCheckpointStore(
        fileURL: fixture.directory.appendingPathComponent("relaunched-self-proof-checkpoint.json")
      ),
      bindingRecordStore: BindingRecordStore(
        fileURL: fixture.directory.appendingPathComponent("relaunched-binding-records.json")
      ),
      sessionAggregateSnapshotStore: SessionAggregateSnapshotStore(
        fileURL: fixture.directory.appendingPathComponent("relaunched-session-aggregate-snapshots.json")
      ),
      unsentWindowLedgerRuntime: try UnsentWindowLedgerRuntime(store: relaunchedLedgerStore),
      sensingCryptography: DeterministicSensingCryptography()
    )

    let reconciled = try XCTUnwrap(try relaunchedLedgerStore.load())
    let impossibleClose = BeidSharedKit.report.closeUnsentWindow(
      ledger: try XCTUnwrap(reconciled.ledger),
      windowId: lostWindowId.uuidString.lowercased(),
      persistedObservationReference: "missing-after-process-death"
    )
    XCTAssertFalse(impossibleClose.isSuccess)
    XCTAssertEqual(impossibleClose.errorCode, "unknown_window_id")

    let prepared = BeidSharedKit.report.prepareNextUnsentWindowSubmission(
      ledger: try XCTUnwrap(reconciled.ledger),
      maximumWindowCount: 10,
      nowEpochMilliseconds: 0
    )
    XCTAssertFalse(prepared.changed)
    XCTAssertNil(prepared.submission)
  }

  func testRelaunchRecoversAReportWrittenBeforeLedgerCloseAndDiscardsAnEmptyOpenWindow() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("beid-ledger-crash-gap-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let reportFileURL = directory.appendingPathComponent("window-reports.json")
    let ledgerFileURL = directory.appendingPathComponent("ledger.snapshot")
    let reportWindowId = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
    let lostWindowId = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000002"))

    let beforeCrashStore = try UnsentWindowLedgerStore(fileURL: ledgerFileURL)
    let beforeCrashRuntime = try UnsentWindowLedgerRuntime(
      store: beforeCrashStore,
      ledgerInstanceIdHex: "000102030405060708090a0b0c0d0e0f"
    )
    try beforeCrashRuntime.openWindow(windowId: reportWindowId.uuidString.lowercased())
    try beforeCrashRuntime.openWindow(windowId: lostWindowId.uuidString.lowercased())

    let beforeCrashReports = WindowReportStore(fileURL: reportFileURL)
    try beforeCrashReports.add(try makeReport(id: reportWindowId))
    // Simulated process death here: the report artifact is durable, but the
    // shared close transition was never called. The second open window has
    // no artifact at all and cannot be reconstructed.

    let relaunchedReports = WindowReportStore(fileURL: reportFileURL)
    let relaunchedLedgerStore = try UnsentWindowLedgerStore(fileURL: ledgerFileURL)
    let relaunchedRuntime = try UnsentWindowLedgerRuntime(store: relaunchedLedgerStore)
    _ = SensingCoordinator(
      windowReportStore: relaunchedReports,
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
      unsentWindowLedgerRuntime: relaunchedRuntime,
      sensingCryptography: DeterministicSensingCryptography()
    )

    let recovered = try XCTUnwrap(try relaunchedLedgerStore.load())
    let lostClose = BeidSharedKit.report.closeUnsentWindow(
      ledger: try XCTUnwrap(recovered.ledger),
      windowId: lostWindowId.uuidString.lowercased(),
      persistedObservationReference: "impossible-observation"
    )
    XCTAssertFalse(lostClose.isSuccess)
    XCTAssertEqual(lostClose.errorCode, "unknown_window_id")

    let prepared = BeidSharedKit.report.prepareNextUnsentWindowSubmission(
      ledger: try XCTUnwrap(recovered.ledger),
      maximumWindowCount: 10,
      nowEpochMilliseconds: 0
    )
    try relaunchedLedgerStore.persist(prepared)
    let inFlight = try XCTUnwrap(try relaunchedLedgerStore.load())
    let submission = try XCTUnwrap(
      BeidSharedKit.report.resumeUnsentWindowSubmissionAfterRestore(
        ledger: try XCTUnwrap(inFlight.ledger)
      ).submission
    )
    let expectedReference = reportWindowId.uuidString.lowercased()
    XCTAssertEqual(submission.windowCount, 1)
    XCTAssertEqual(submission.windowIdAt(index: 0), expectedReference)
    XCTAssertEqual(submission.observationReferenceAt(index: 0), expectedReference)
  }

  func testRelaunchAdoptsAnArtifactWhoseLedgerOpenHadFailed() throws {
    // Combines two existing patterns: blockLedgerWrites() from
    // testUnknownWindowAtRedeliveryHeadIsDiscardedBeforeLaterArtifact to
    // reproduce gh#132's exact mechanism (a failed openWindow leaves
    // currentWindowId set, so the later close durably writes the report but
    // the ledger close is rejected "unknown_window_id"), then the fresh
    // SensingCoordinator/UnsentWindowLedgerRuntime relaunch pattern from
    // testRelaunchRecoversAReportWrittenBeforeLedgerCloseAndDiscardsAnEmptyOpenWindow
    // to prove the orphaned artifact is adopted rather than staying lost.
    let fixture = try makeRecoverableReportFailureFixture(
      named: "open-failure-relaunch-adoption"
    )
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    fixture.coordinator.startSensing(eventCode: "TEST-OPEN-FAILURE-RELAUNCH-ADOPTION")

    // blockLedgerWrites() writes a plain file at the ledger parent path, so
    // it only works before anything has ever created that path as a real
    // directory — it must run first, before any window has successfully
    // opened or closed.
    //
    // beid#114: confirm within window 1, with the ledger already blocked, so
    // the confirming detection's own ledger-open attempt genuinely fails
    // (gh#132's exact mechanism) instead of never being attempted at all.
    try fixture.blockLedgerWrites()
    let threshold = BeidConfig.eventConfirmThreshold
    for index in 0..<threshold {
      fixture.coordinator.handleDetection(
        enin: 1,
        rpid: "peer-open-failed-\(index)",
        detectedDisplayId: DetectionFixture.displayId(device: index)
      )
    }
    guard case .recording = fixture.coordinator.phase else {
      XCTFail("expected .recording before restoring ledger writes, got \(fixture.coordinator.phase)")
      return
    }
    let orphanedWindowId = try XCTUnwrap(fixture.coordinator.currentWindowIdForTesting)

    try fixture.restoreLedgerWrites()
    fixture.coordinator.checkpointOpenWindowForBackgrounding()
    XCTAssertNil(fixture.coordinator.currentWindowIdForTesting)

    // A second, ordinary window opens and closes normally after ledger
    // writes are restored — already `.recording`, so one more distinct
    // device is enough to open and sign it. This is what actually creates
    // the ledger file for the first time, so the "before relaunch" check
    // below has a real durable snapshot to load and query. (A session
    // containing only the failed window would never have written anything
    // to disk at all.)
    fixture.coordinator.handleDetection(
      enin: 2,
      rpid: "peer-establishing-ledger",
      detectedDisplayId: DetectionFixture.displayId(device: threshold)
    )
    let establishedWindowId = try XCTUnwrap(fixture.coordinator.currentWindowIdForTesting)
    XCTAssertNotEqual(establishedWindowId, orphanedWindowId)
    fixture.coordinator.checkpointOpenWindowForBackgrounding()

    let orphanedReport = try XCTUnwrap(
      fixture.reportStore.reports.first { $0.id == orphanedWindowId }
    )
    let durableBeforeRelaunch = try XCTUnwrap(try fixture.ledgerStore.load())
    let orphanedCloseBeforeRelaunch = BeidSharedKit.report.closeUnsentWindow(
      ledger: try XCTUnwrap(durableBeforeRelaunch.ledger),
      windowId: orphanedWindowId.uuidString.lowercased(),
      persistedObservationReference: orphanedReport.id.uuidString.lowercased()
    )
    XCTAssertFalse(
      orphanedCloseBeforeRelaunch.isSuccess,
      "pre-relaunch, this ledger has never gone through reconcileAfterRelaunch"
    )
    XCTAssertEqual(orphanedCloseBeforeRelaunch.errorCode, "unknown_window_id")

    // Simulate relaunch: a fresh SensingCoordinator/UnsentWindowLedgerRuntime
    // pair against the same durable files reconciles the ledger on construction.
    let relaunchedReports = WindowReportStore(fileURL: fixture.reportFileURL)
    let relaunchedLedgerStore = try UnsentWindowLedgerStore(fileURL: fixture.ledgerFileURL)
    _ = SensingCoordinator(
      windowReportStore: relaunchedReports,
      selfProofStore: SelfProofStore(
        fileURL: fixture.directory.appendingPathComponent("relaunched-self-proofs.json")
      ),
      selfProofCheckpointStore: SelfProofCheckpointStore(
        fileURL: fixture.directory.appendingPathComponent("relaunched-self-proof-checkpoint.json")
      ),
      bindingRecordStore: BindingRecordStore(
        fileURL: fixture.directory.appendingPathComponent("relaunched-binding-records.json")
      ),
      sessionAggregateSnapshotStore: SessionAggregateSnapshotStore(
        fileURL: fixture.directory.appendingPathComponent("relaunched-session-aggregate-snapshots.json")
      ),
      unsentWindowLedgerRuntime: try UnsentWindowLedgerRuntime(store: relaunchedLedgerStore),
      sensingCryptography: DeterministicSensingCryptography()
    )

    let reconciled = try XCTUnwrap(try relaunchedLedgerStore.load())
    let orphanedCloseAfterRelaunch = BeidSharedKit.report.closeUnsentWindow(
      ledger: try XCTUnwrap(reconciled.ledger),
      windowId: orphanedWindowId.uuidString.lowercased(),
      persistedObservationReference: orphanedReport.id.uuidString.lowercased()
    )
    XCTAssertTrue(
      orphanedCloseAfterRelaunch.isSuccess,
      "a previously-orphaned artifact must become closeable once a relaunch reconciles it"
    )
    XCTAssertFalse(
      orphanedCloseAfterRelaunch.changed,
      "reconciliation already adopted the window as closed with this exact reference"
    )

    let prepared = BeidSharedKit.report.prepareNextUnsentWindowSubmission(
      ledger: try XCTUnwrap(reconciled.ledger),
      maximumWindowCount: 10,
      nowEpochMilliseconds: 0
    )
    try relaunchedLedgerStore.persist(prepared)
    let inFlight = try XCTUnwrap(try relaunchedLedgerStore.load())
    let submission = try XCTUnwrap(
      BeidSharedKit.report.resumeUnsentWindowSubmissionAfterRestore(
        ledger: try XCTUnwrap(inFlight.ledger)
      ).submission
    )
    // Both the normally-closed window and the newly-adopted orphan must be
    // in the eventual send set; sorted by closedRevision, so the earlier,
    // normally-closed window sorts first.
    let establishedReference = establishedWindowId.uuidString.lowercased()
    let orphanedReference = orphanedWindowId.uuidString.lowercased()
    XCTAssertEqual(submission.windowCount, 2)
    XCTAssertEqual(submission.windowIdAt(index: 0), establishedReference)
    XCTAssertEqual(submission.observationReferenceAt(index: 0), establishedReference)
    XCTAssertEqual(submission.windowIdAt(index: 1), orphanedReference)
    XCTAssertEqual(submission.observationReferenceAt(index: 1), orphanedReference)
  }

  func testCorruptObservationStoreCannotMasqueradeAsAnEmptyRecoverySet() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("beid-ledger-corrupt-artifacts-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let ledgerFileURL = directory.appendingPathComponent("ledger.snapshot")
    let reportFileURL = directory.appendingPathComponent("window-reports.json")
    let windowId = "00000000-0000-0000-0000-000000000001"
    let beforeCrashRuntime = try UnsentWindowLedgerRuntime(
      store: try UnsentWindowLedgerStore(fileURL: ledgerFileURL),
      ledgerInstanceIdHex: "000102030405060708090a0b0c0d0e0f"
    )
    try beforeCrashRuntime.openWindow(windowId: windowId)
    try Data("not-json".utf8).write(to: reportFileURL, options: .atomic)

    let corruptReports = WindowReportStore(fileURL: reportFileURL)
    let relaunchedLedgerStore = try UnsentWindowLedgerStore(fileURL: ledgerFileURL)
    _ = SensingCoordinator(
      windowReportStore: corruptReports,
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
      unsentWindowLedgerRuntime: try UnsentWindowLedgerRuntime(store: relaunchedLedgerStore),
      sensingCryptography: DeterministicSensingCryptography()
    )

    let stillOpen = try XCTUnwrap(try relaunchedLedgerStore.load())
    let close = BeidSharedKit.report.closeUnsentWindow(
      ledger: try XCTUnwrap(stillOpen.ledger),
      windowId: windowId,
      persistedObservationReference: "later-recovered-observation"
    )
    XCTAssertTrue(close.isSuccess)
    XCTAssertTrue(close.changed)
  }

  func testForegroundEndBackgroundAndColdLaunchSequencePreparesWindowAtMostOnce() async throws {
    let fixture = try makeRuntimeFixture(named: "fg-end-bg-launch-sequence")
    defer { try? FileManager.default.removeItem(at: fixture.directory) }

    fixture.coordinator.startSensing(eventCode: "TEST-FG-BG-LAUNCH-IDEMPOTENCY")

    let threshold = BeidConfig.eventConfirmThreshold
    for index in 0..<threshold {
      fixture.coordinator.handleDetection(
        enin: 1,
        rpid: "peer-\(index)",
        detectedDisplayId: DetectionFixture.displayId(device: index)
      )
    }
    guard case .recording = fixture.coordinator.phase else {
      XCTFail("expected .recording phase, got \(fixture.coordinator.phase)")
      return
    }

    // 1. Foreground-end (stopSensing closes the open window and persists WindowReport)
    _ = fixture.coordinator.stopSensing()
    XCTAssertEqual(fixture.reportStore.reports.count, 1)
    let originalReport = try XCTUnwrap(fixture.reportStore.reports.first)
    let windowIdHex = originalReport.id.uuidString.lowercased()

    // 2. Background transition (checkpointOpenWindowForBackgrounding)
    // The window was already closed; checkpoint must safely no-op. This unit
    // test calls the coordinator seam directly; the SwiftUI scenePhase hook
    // at ScanFlowView.swift:92-94 is not exercised here.
    fixture.coordinator.checkpointOpenWindowForBackgrounding()
    XCTAssertEqual(fixture.reportStore.reports.count, 1)

    // 3. Cold launch: drive the same async beginLedgerLoad path used by the
    // production convenience initializer.
    let relaunchedLedgerStore = try UnsentWindowLedgerStore(fileURL: fixture.ledgerFileURL)
    let launchRuntime = ColdLaunchSubmissionRuntimeSpy()
    let relaunchedCoordinator = SensingCoordinator(
      loadingFromDirectory: fixture.directory,
      sensingCryptography: DeterministicSensingCryptography(),
      reportSubmissionRuntime: launchRuntime
    )
    XCTAssertTrue(relaunchedCoordinator.isLedgerLoading)
    await relaunchedCoordinator.waitForLedgerLoadToFinish()
    XCTAssertFalse(relaunchedCoordinator.isLedgerLoading)
    XCTAssertEqual(
      launchRuntime.submitPendingCallCount,
      1,
      "cold launch must retry pending submissions once without restarting sensing"
    )

    // 4. Prepare one submission descriptor: exactly one must be produced.
    let durable = try XCTUnwrap(try relaunchedLedgerStore.load())
    let prepared = BeidSharedKit.report.prepareNextUnsentWindowSubmission(
      ledger: try XCTUnwrap(durable.ledger),
      maximumWindowCount: 10,
      nowEpochMilliseconds: 0
    )
    XCTAssertTrue(prepared.changed)

    // Persist and confirm the in-flight submission. The shared reducer emits
    // the submission only after the changed snapshot is durable.
    let confirmed = BeidSharedKit.report.confirmUnsentWindowLedgerPersistence(
      ledger: prepared.ledger,
      revision: try relaunchedLedgerStore.persist(prepared)
    )
    XCTAssertTrue(confirmed.isSuccess)
    let submission = try XCTUnwrap(confirmed.submission)
    XCTAssertEqual(submission.windowCount, 1)
    XCTAssertEqual(submission.windowIdAt(index: 0), windowIdHex)
    XCTAssertEqual(submission.observationReferenceAt(index: 0), windowIdHex)

    // 5. Idempotency: the second preparation returns nil (already in flight).
    let inFlight = try XCTUnwrap(try relaunchedLedgerStore.load())
    let duplicatePrepared = BeidSharedKit.report.prepareNextUnsentWindowSubmission(
      ledger: try XCTUnwrap(inFlight.ledger),
      maximumWindowCount: 10,
      nowEpochMilliseconds: 0
    )
    XCTAssertFalse(duplicatePrepared.changed)
    XCTAssertNil(duplicatePrepared.submission)
  }

  func testBackgroundTransitionBeforeStopAndColdLaunchSequencePreparesWindowAtMostOnce() async throws {
    let fixture = try makeRuntimeFixture(named: "bg-before-stop-launch-sequence")
    defer { try? FileManager.default.removeItem(at: fixture.directory) }

    fixture.coordinator.startSensing(eventCode: "TEST-BG-BEFORE-STOP-LAUNCH")

    let threshold = BeidConfig.eventConfirmThreshold
    for index in 0..<threshold {
      fixture.coordinator.handleDetection(
        enin: 1,
        rpid: "peer-\(index)",
        detectedDisplayId: DetectionFixture.displayId(device: index)
      )
    }
    guard case .recording = fixture.coordinator.phase else {
      XCTFail("expected .recording phase, got \(fixture.coordinator.phase)")
      return
    }

    // 1. Background transition checkpoints and closes open window. This unit
    // test calls the coordinator seam directly; the SwiftUI scenePhase hook
    // at ScanFlowView.swift:92-94 is not exercised here.
    fixture.coordinator.checkpointOpenWindowForBackgrounding()
    XCTAssertEqual(fixture.reportStore.reports.count, 1)
    let originalReport = try XCTUnwrap(fixture.reportStore.reports.first)
    let windowIdHex = originalReport.id.uuidString.lowercased()

    // 2. Foreground stop afterwards: already closed window is safely skipped
    _ = fixture.coordinator.stopSensing()
    XCTAssertEqual(fixture.reportStore.reports.count, 1)

    // 3. Cold launch / process restart through the async beginLedgerLoad path
    let relaunchedLedgerStore = try UnsentWindowLedgerStore(fileURL: fixture.ledgerFileURL)
    let launchRuntime = ColdLaunchSubmissionRuntimeSpy()
    let relaunchedCoordinator = SensingCoordinator(
      loadingFromDirectory: fixture.directory,
      sensingCryptography: DeterministicSensingCryptography(),
      reportSubmissionRuntime: launchRuntime
    )
    XCTAssertTrue(relaunchedCoordinator.isLedgerLoading)
    await relaunchedCoordinator.waitForLedgerLoadToFinish()
    XCTAssertFalse(relaunchedCoordinator.isLedgerLoading)
    XCTAssertEqual(
      launchRuntime.submitPendingCallCount,
      1,
      "cold launch must retry pending submissions once without restarting sensing"
    )

    // 4. Prepare submission descriptor
    let durable = try XCTUnwrap(try relaunchedLedgerStore.load())
    let prepared = BeidSharedKit.report.prepareNextUnsentWindowSubmission(
      ledger: try XCTUnwrap(durable.ledger),
      maximumWindowCount: 10,
      nowEpochMilliseconds: 0
    )
    XCTAssertTrue(prepared.changed)
    let confirmed = BeidSharedKit.report.confirmUnsentWindowLedgerPersistence(
      ledger: prepared.ledger,
      revision: try relaunchedLedgerStore.persist(prepared)
    )
    XCTAssertTrue(confirmed.isSuccess)
    let submission = try XCTUnwrap(confirmed.submission)
    XCTAssertEqual(submission.windowCount, 1)
    XCTAssertEqual(submission.windowIdAt(index: 0), windowIdHex)
    XCTAssertEqual(submission.observationReferenceAt(index: 0), windowIdHex)

    // 5. A second preparation remains empty while the first is in flight.
    let inFlight = try XCTUnwrap(try relaunchedLedgerStore.load())
    let duplicatePrepared = BeidSharedKit.report.prepareNextUnsentWindowSubmission(
      ledger: try XCTUnwrap(inFlight.ledger),
      maximumWindowCount: 10,
      nowEpochMilliseconds: 0
    )
    XCTAssertFalse(duplicatePrepared.changed)
    XCTAssertNil(duplicatePrepared.submission)
  }

  private func makeReport(id: UUID) throws -> WindowReport {
    let data = Data(
      """
      {
        "id":"\(id.uuidString)",
        "eventCode":"event-1",
        "enin":1,
        "peerCount":1,
        "commitHex":"00",
        "signatureRHex":"01",
        "signatureSHex":"02",
        "signatureV":0,
        "signedAt":0
      }
      """.utf8
    )
    return try JSONDecoder().decode(WindowReport.self, from: data)
  }

  private func temporaryDirectory(named name: String) -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("beid-ledger-\(name)-\(UUID().uuidString)", isDirectory: true)
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    } catch {
      preconditionFailure("Unable to create test directory: \(error)")
    }
    return directory
  }

  private func makeRuntimeFixture(named name: String) throws -> RuntimeFixture {
    let directory = temporaryDirectory(named: name)
    let ledgerFileURL = directory.appendingPathComponent("ledger.snapshot")
    let reportFileURL = directory.appendingPathComponent("window-reports.json")
    let reportStore = WindowReportStore(
      fileURL: reportFileURL
    )
    let runtime = try UnsentWindowLedgerRuntime(
      store: try UnsentWindowLedgerStore(fileURL: ledgerFileURL),
      ledgerInstanceIdHex: "000102030405060708090a0b0c0d0e0f"
    )
    let coordinator = SensingCoordinator(
      windowReportStore: reportStore,
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
      unsentWindowLedgerRuntime: runtime,
      sensingCryptography: DeterministicSensingCryptography()
    )
    coordinator.useDemoEventMode = false
    return RuntimeFixture(
      directory: directory,
      ledgerFileURL: ledgerFileURL,
      reportFileURL: reportFileURL,
      reportStore: reportStore,
      coordinator: coordinator
    )
  }

  private func makeRecoverableReportFailureFixture(
    named name: String
  ) throws -> RecoverableReportFailureFixture {
    let directory = temporaryDirectory(named: name)
    let reportParentURL = directory.appendingPathComponent("report-parent", isDirectory: true)
    let reportFileURL = reportParentURL.appendingPathComponent("window-reports.json")
    let ledgerParentURL = directory.appendingPathComponent("ledger-parent", isDirectory: true)
    let ledgerFileURL = ledgerParentURL.appendingPathComponent("ledger.snapshot")
    let reportStore = WindowReportStore(fileURL: reportFileURL)
    let ledgerStore = try UnsentWindowLedgerStore(fileURL: ledgerFileURL)
    let coordinator = SensingCoordinator(
      windowReportStore: reportStore,
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
      unsentWindowLedgerRuntime: try UnsentWindowLedgerRuntime(
        store: ledgerStore,
        ledgerInstanceIdHex: "000102030405060708090a0b0c0d0e0f"
      ),
      sensingCryptography: DeterministicSensingCryptography()
    )
    coordinator.useDemoEventMode = false
    return RecoverableReportFailureFixture(
      directory: directory,
      reportParentURL: reportParentURL,
      reportFileURL: reportFileURL,
      ledgerParentURL: ledgerParentURL,
      ledgerFileURL: ledgerFileURL,
      reportStore: reportStore,
      ledgerStore: ledgerStore,
      coordinator: coordinator
    )
  }

  private func apply(_ trigger: CloseTrigger, to coordinator: SensingCoordinator) {
    switch trigger {
    case .enin:
      coordinator.handleDetection(
        enin: 2,
        rpid: "peer-new-enin",
        detectedDisplayId: DetectionFixture.displayId(device: 33)
      )
    case .stop:
      coordinator.stopSensing()
    case .background:
      coordinator.checkpointOpenWindowForBackgrounding()
    }
  }

  private func apply(_ action: SessionEndAction, to coordinator: SensingCoordinator) {
    switch action {
    case .stop:
      coordinator.stopSensing()
    case .reset:
      coordinator.reset()
    }
  }

  private struct RuntimeFixture {
    let directory: URL
    let ledgerFileURL: URL
    let reportFileURL: URL
    let reportStore: WindowReportStore
    let coordinator: SensingCoordinator
  }

  private struct RecoverableReportFailureFixture {
    let directory: URL
    let reportParentURL: URL
    let reportFileURL: URL
    let ledgerParentURL: URL
    let ledgerFileURL: URL
    let reportStore: WindowReportStore
    let ledgerStore: UnsentWindowLedgerStore
    let coordinator: SensingCoordinator

    func blockReportWrites() throws {
      try Data([0x01]).write(to: reportParentURL)
    }

    func restoreReportWrites() throws {
      try FileManager.default.removeItem(at: reportParentURL)
      try FileManager.default.createDirectory(
        at: reportParentURL,
        withIntermediateDirectories: true
      )
    }

    func blockLedgerWrites() throws {
      try Data([0x01]).write(to: ledgerParentURL)
    }

    func restoreLedgerWrites() throws {
      try FileManager.default.removeItem(at: ledgerParentURL)
      try FileManager.default.createDirectory(
        at: ledgerParentURL,
        withIntermediateDirectories: true
      )
    }
  }

  private enum CloseTrigger: String {
    case enin
    case stop
    case background
  }

  private enum SessionEndAction: String, CaseIterable {
    case stop
    case reset
  }
}

private final class TransientCloseRejectionLedgerRuntime:
  UnsentWindowLedgerRuntimeProtocol
{
  private(set) var closeAttempts: [String: Int] = [:]
  private(set) var closedWindowIds: Set<String> = []
  private var rejectedWindowId: String?

  func rejectNextClose(windowId: String) {
    rejectedWindowId = windowId
  }

  func openWindow(windowId: String) throws {}

  func closeWindow(
    windowId: String,
    persistedObservationReference: String
  ) throws {
    closeAttempts[windowId, default: 0] += 1
    if rejectedWindowId == windowId {
      rejectedWindowId = nil
      throw UnsentWindowLedgerRuntimeError.rejectedTransition(
        "transient_close_failure"
      )
    }
    closedWindowIds.insert(windowId)
  }

  func reconcileAfterRelaunch(
    persistedObservations: [(windowId: String, reference: String)]
  ) throws {}
}
#endif
