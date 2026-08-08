// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import BeidSharedKit
import Foundation
import XCTest
@testable import Beid

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
      let coordinator = SensingCoordinator(
        windowReportStore: reportStore,
        selfProofStore: selfProofStore,
        unsentWindowLedgerRuntime: runtime,
        sensingCryptography: DeterministicSensingCryptography()
      )
      coordinator.useDemoEventMode = false
      coordinator.startSensing(eventCode: "TEST-SHARED-ORDERING")
      coordinator.handleDetection(
        enin: 1,
        rpid: "peer-original",
        detectedDisplayId: DetectionFixture.displayId(device: 1)
      )

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

  func testFailedLedgerCloseAtEninBoundaryStillAcceptsTheTriggeringObservation() throws {
    let fixture = try makeRuntimeFixture(named: "failed-enin-close")
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    fixture.coordinator.startSensing(eventCode: "TEST-FAILED-ENIN-CLOSE")

    let peersBeforeBoundary = max(1, BeidConfig.eventConfirmThreshold - 1)
    for index in 0..<peersBeforeBoundary {
      fixture.coordinator.handleDetection(
        enin: 1,
        rpid: "peer-\(index)",
        detectedDisplayId: DetectionFixture.displayId(device: index)
      )
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
    guard case .recording(_, let peersAtBoundary) = fixture.coordinator.phase else {
      XCTFail("the boundary observation must still reach recording, got \(fixture.coordinator.phase)")
      return
    }
    XCTAssertEqual(peersAtBoundary, peersBeforeBoundary + 1)

    fixture.coordinator.handleDetection(

      enin: 2,

      rpid: "peer-after-boundary",

      detectedDisplayId: DetectionFixture.displayId(device: 91)

    )
    guard case .recording(_, let peersAfterBoundary) = fixture.coordinator.phase else {
      XCTFail("same-ENIN intake must continue after ledger failure")
      return
    }
    XCTAssertEqual(peersAfterBoundary, peersBeforeBoundary + 2)
  }

  func testFailedCheckpointCloseDoesNotDropLaterSameEninObservations() throws {
    let fixture = try makeRuntimeFixture(named: "failed-checkpoint-close")
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    fixture.coordinator.startSensing(eventCode: "TEST-FAILED-CHECKPOINT-CLOSE")
    fixture.coordinator.handleDetection(
      enin: 1,
      rpid: "peer-0",
      detectedDisplayId: DetectionFixture.displayId(device: 0)
    )
    let originalWindowId = try XCTUnwrap(fixture.coordinator.currentWindowIdForTesting)
    try Data("corrupt-ledger".utf8).write(to: fixture.ledgerFileURL, options: .atomic)

    fixture.coordinator.checkpointOpenWindowForBackgrounding()

    XCTAssertEqual(fixture.reportStore.reports.count, 1)
    XCTAssertNil(fixture.coordinator.currentWindowIdForTesting)
    for index in 1..<BeidConfig.eventConfirmThreshold {
      fixture.coordinator.handleDetection(
        enin: 1,
        rpid: "peer-\(index)",
        detectedDisplayId: DetectionFixture.displayId(device: index)
      )
    }

    XCTAssertNotNil(fixture.coordinator.currentWindowIdForTesting)
    XCTAssertNotEqual(fixture.coordinator.currentWindowIdForTesting, originalWindowId)
    guard case .recording(_, let peersVerified) = fixture.coordinator.phase else {
      XCTFail("post-checkpoint observations must continue after ledger failure")
      return
    }
    XCTAssertEqual(peersVerified, BeidConfig.eventConfirmThreshold)
  }

  func testSessionEndAlwaysTearsDownAfterLedgerCloseFailure() throws {
    for action in SessionEndAction.allCases {
      let fixture = try makeRuntimeFixture(named: "failed-\(action.rawValue)")
      defer { try? FileManager.default.removeItem(at: fixture.directory) }
      fixture.coordinator.startSensing(eventCode: "TEST-FAILED-\(action.rawValue)")
      fixture.coordinator.handleDetection(
        enin: 1,
        rpid: "peer-1",
        detectedDisplayId: DetectionFixture.displayId(device: 1)
      )
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
    fixture.coordinator.handleDetection(
      enin: 1,
      rpid: "peer-enin-1",
      detectedDisplayId: DetectionFixture.displayId(device: 10)
    )
    let firstWindowId = try XCTUnwrap(fixture.coordinator.currentWindowIdForTesting)
    try fixture.blockReportWrites()

    fixture.coordinator.handleDetection(

      enin: 2,

      rpid: "peer-enin-2",

      detectedDisplayId: DetectionFixture.displayId(device: 11)

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
      1,
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
    fixture.coordinator.handleDetection(
      enin: 1,
      rpid: "peer-orphaned",
      detectedDisplayId: DetectionFixture.displayId(device: 20)
    )
    let orphanedWindowId = try XCTUnwrap(fixture.coordinator.currentWindowIdForTesting)

    try fixture.restoreLedgerWrites()
    try fixture.blockReportWrites()
    fixture.coordinator.handleDetection(
      enin: 2,
      rpid: "peer-recoverable",
      detectedDisplayId: DetectionFixture.displayId(device: 21)
    )
    let recoverableWindowId = try XCTUnwrap(fixture.coordinator.currentWindowIdForTesting)
    fixture.coordinator.handleDetection(
      enin: 3,
      rpid: "peer-after-queue",
      detectedDisplayId: DetectionFixture.displayId(device: 22)
    )
    XCTAssertTrue(fixture.reportStore.reports.isEmpty)

    try fixture.restoreReportWrites()
    fixture.coordinator.handleDetection(
      enin: 4,
      rpid: "peer-drain-trigger",
      detectedDisplayId: DetectionFixture.displayId(device: 23)
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
    fixture.coordinator.handleDetection(
      enin: 1,
      rpid: "peer-before-stop",
      detectedDisplayId: DetectionFixture.displayId(device: 30)
    )
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
      detectedDisplayId: DetectionFixture.displayId(device: 31)
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
    fixture.coordinator.handleDetection(
      enin: 1,
      rpid: "peer-before-death",
      detectedDisplayId: DetectionFixture.displayId(device: 32)
    )
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
    let reportStore = WindowReportStore(
      fileURL: directory.appendingPathComponent("window-reports.json")
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
      unsentWindowLedgerRuntime: runtime,
      sensingCryptography: DeterministicSensingCryptography()
    )
    coordinator.useDemoEventMode = false
    return RuntimeFixture(
      directory: directory,
      ledgerFileURL: ledgerFileURL,
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
