// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import BeidSharedKit
import Foundation
import XCTest
@testable import Beid

@MainActor
final class UnsentWindowLedgerRuntimeTests: XCTestCase {
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
        unsentWindowLedgerRuntime: runtime
      )
      coordinator.useDemoEventMode = false
      coordinator.startSensing(eventCode: "TEST-SHARED-ORDERING")
      coordinator.handleDetection(enin: 1, rpid: "peer-original")

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
      unsentWindowLedgerRuntime: nil
    )
    coordinator.useDemoEventMode = false
    coordinator.startSensing(eventCode: "TEST-LEDGER-UNAVAILABLE")

    for index in 0..<BeidConfig.eventConfirmThreshold {
      coordinator.handleDetection(enin: 1, rpid: "peer-\(index)")
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
      fixture.coordinator.handleDetection(enin: 1, rpid: "peer-\(index)")
    }
    let originalWindowId = try XCTUnwrap(fixture.coordinator.currentWindowIdForTesting)
    try Data("corrupt-ledger".utf8).write(to: fixture.ledgerFileURL, options: .atomic)

    fixture.coordinator.handleDetection(enin: 2, rpid: "peer-at-boundary")

    XCTAssertEqual(fixture.reportStore.reports.count, 1)
    XCTAssertEqual(fixture.reportStore.reports.first?.enin, 1)
    XCTAssertEqual(fixture.reportStore.reports.first?.peerCount, peersBeforeBoundary)
    XCTAssertNotEqual(fixture.coordinator.currentWindowIdForTesting, originalWindowId)
    guard case .recording(_, let peersAtBoundary) = fixture.coordinator.phase else {
      XCTFail("the boundary observation must still reach recording, got \(fixture.coordinator.phase)")
      return
    }
    XCTAssertEqual(peersAtBoundary, peersBeforeBoundary + 1)

    fixture.coordinator.handleDetection(enin: 2, rpid: "peer-after-boundary")
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
    fixture.coordinator.handleDetection(enin: 1, rpid: "peer-0")
    let originalWindowId = try XCTUnwrap(fixture.coordinator.currentWindowIdForTesting)
    try Data("corrupt-ledger".utf8).write(to: fixture.ledgerFileURL, options: .atomic)

    fixture.coordinator.checkpointOpenWindowForBackgrounding()

    XCTAssertEqual(fixture.reportStore.reports.count, 1)
    XCTAssertNil(fixture.coordinator.currentWindowIdForTesting)
    for index in 1..<BeidConfig.eventConfirmThreshold {
      fixture.coordinator.handleDetection(enin: 1, rpid: "peer-\(index)")
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
      fixture.coordinator.handleDetection(enin: 1, rpid: "peer-1")
      try Data("corrupt-ledger".utf8).write(to: fixture.ledgerFileURL, options: .atomic)

      apply(action, to: fixture.coordinator)

      XCTAssertEqual(fixture.coordinator.phase, .idle, action.rawValue)
      XCTAssertNil(fixture.coordinator.currentWindowIdForTesting, action.rawValue)
      XCTAssertEqual(fixture.reportStore.reports.count, 1, action.rawValue)
      apply(action, to: fixture.coordinator)
      XCTAssertEqual(fixture.reportStore.reports.count, 1, action.rawValue)
    }
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
      unsentWindowLedgerRuntime: relaunchedRuntime
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
      unsentWindowLedgerRuntime: try UnsentWindowLedgerRuntime(store: relaunchedLedgerStore)
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
      unsentWindowLedgerRuntime: runtime
    )
    coordinator.useDemoEventMode = false
    return RuntimeFixture(
      directory: directory,
      ledgerFileURL: ledgerFileURL,
      reportStore: reportStore,
      coordinator: coordinator
    )
  }

  private func apply(_ trigger: CloseTrigger, to coordinator: SensingCoordinator) {
    switch trigger {
    case .enin:
      coordinator.handleDetection(enin: 2, rpid: "peer-new-enin")
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
