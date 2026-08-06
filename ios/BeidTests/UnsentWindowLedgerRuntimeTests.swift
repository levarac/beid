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
    // ENIN boundary, explicit stop, and background may race. The native
    // caller forwards all three inputs; shared owns duplicate-close handling.
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

  func testProductionLifecycleRoutesEninStopAndBackgroundCloseInputsThroughShared() throws {
    for trigger in CloseTrigger.allCases {
      let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(
          "beid-ledger-lifecycle-\(trigger.rawValue)-\(UUID().uuidString)",
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
      coordinator.startSensing(eventCode: "TEST-SHARED-\(trigger.rawValue)")
      coordinator.handleDetection(enin: 1, rpid: "peer-1")
      let openWindowId = try XCTUnwrap(coordinator.currentWindowIdForTesting, trigger.rawValue)
      try reportStore.add(try makeReport(id: openWindowId))

      switch trigger {
      case .enin:
        coordinator.handleDetection(enin: 2, rpid: "peer-2")
      case .stop:
        coordinator.stopSensing()
      case .background:
        coordinator.checkpointOpenWindowForBackgrounding()
      }

      let report = try XCTUnwrap(reportStore.reports.first, trigger.rawValue)
      let durable = try XCTUnwrap(try ledgerStore.load(), trigger.rawValue)
      let prepared = BeidSharedKit.report.prepareNextUnsentWindowSubmission(
        ledger: try XCTUnwrap(durable.ledger, trigger.rawValue),
        maximumWindowCount: 10,
        nowEpochMilliseconds: 0
      )
      XCTAssertTrue(prepared.changed, trigger.rawValue)
      try ledgerStore.persist(prepared)
      let inFlight = try XCTUnwrap(try ledgerStore.load(), trigger.rawValue)
      let submission = try XCTUnwrap(
        BeidSharedKit.report.resumeUnsentWindowSubmissionAfterRestore(
          ledger: try XCTUnwrap(inFlight.ledger, trigger.rawValue)
        ).submission,
        trigger.rawValue
      )

      let expectedReference = report.id.uuidString.lowercased()
      XCTAssertEqual(submission.windowCount, 1, trigger.rawValue)
      XCTAssertEqual(submission.windowIdAt(index: 0), expectedReference, trigger.rawValue)
      XCTAssertEqual(
        submission.observationReferenceAt(index: 0),
        expectedReference,
        trigger.rawValue
      )
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

  private enum CloseTrigger: String, CaseIterable {
    case enin
    case stop
    case background
  }
}
