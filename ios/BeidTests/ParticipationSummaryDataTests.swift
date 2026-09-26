// Copyright (c) 2024-2026 Levarac Foundation
// SPDX-License-Identifier: MIT

import BeidSharedKit
import XCTest
@testable import Beid

/// beid#143 — `ParticipationSummaryView` reads
/// `SensingCoordinator.sessionAggregateSnapshot(forProofId:)`, keyed on
/// `Proof.id` (not `eventCode` — confirmed against
/// `SessionAggregateSnapshotStore`'s own doc comment). That method forwards
/// to the coordinator's privately-owned `sessionAggregateSnapshotStore`
/// (beid#166 Phase 2, `SensingCoordinator.swift`'s
/// `persistSessionAggregateSnapshotIfNeeded()`) — deliberately the same
/// store instance the session-end hook writes, not a second, independently-
/// constructed one, so a snapshot persisted moments ago in the same app run
/// is visible immediately rather than only after the next on-disk reload
/// (an earlier draft of this file routed through a second store owned by
/// `AppCoordinator`, which would have gone stale exactly that way; #166
/// Phase 2 landed on `origin/main` mid-implementation and the accessor
/// below replaced that draft before any of it shipped).
///
/// `SessionAggregateSnapshotStoreTests` covers the store's own persistence
/// contract in depth (round trip, immutability, corruption handling), and
/// `SessionAggregateSnapshotPersistHookTests` covers the session-end write
/// path. This file covers only the read path #143's screen depends on: the
/// coordinator-level accessor, the honest-nil "no snapshot" case, the
/// always-zero mutual scope, and the sparse band series a gap in
/// attendance produces — seeded the same way those files seed the store
/// (`persist(aggregate:proofId:)` called directly), without needing a real
/// sensing session to run end to end.
@MainActor
final class ParticipationSummaryDataTests: XCTestCase {
  func testCoordinatorExposesAPersistedSnapshotKeyedOnProofId() throws {
    let (coordinator, store) = makeCoordinator()
    let proof = Proof(eventName: "ETHGlobal Tokyo", date: Date(), peersVerified: 2)
    let aggregate = makeAggregate(
      observations: [
        (windowIndex: 0, peerKey: "peer-0", displayId: "device-0"),
        (windowIndex: 1, peerKey: "peer-1", displayId: "device-1"),
      ],
      windowsPerBand: 4
    )
    try store.persist(aggregate: aggregate, proofId: proof.id)

    let read = coordinator.sessionAggregateSnapshot(forProofId: proof.id)

    XCTAssertEqual(Int(read?.deviceCount ?? -1), 2)
  }

  /// The "not yet available" case #143's screen renders — a `Proof` with no
  /// persisted snapshot, e.g. one recorded before beid#166 Phase 2 existed,
  /// or whose best-effort persist failed at session end. Must never read as
  /// a fabricated zero.
  func testCoordinatorReturnsNilForAProofWithNoPersistedSnapshot() {
    let (coordinator, _) = makeCoordinator()
    let proof = Proof(eventName: "ETHGlobal Tokyo", date: Date(), peersVerified: 0)

    XCTAssertNil(coordinator.sessionAggregateSnapshot(forProofId: proof.id))
  }

  /// Mutual scope stays an honest 0 in the persisted-and-reread snapshot,
  /// same as the live coordinator
  /// (`SessionAggregateExposureTests.testSessionAggregateMutualCountsStayZeroRegardlessOfDeviceCount`)
  /// — #143's headline metric reads this field directly, and must not
  /// diverge from the live-session behavior it is a post-session view of.
  func testPersistedSnapshotMutualCountsStayZero() throws {
    let (coordinator, store) = makeCoordinator()
    let proof = Proof(eventName: "ETHGlobal Tokyo", date: Date(), peersVerified: 4)
    let aggregate = makeAggregate(
      observations: (0..<4).map { (windowIndex: 0, peerKey: "peer-\($0)", displayId: "device-\($0)") },
      windowsPerBand: 4
    )
    try store.persist(aggregate: aggregate, proofId: proof.id)

    let read = try XCTUnwrap(coordinator.sessionAggregateSnapshot(forProofId: proof.id))

    XCTAssertEqual(Int(read.mutualDeviceCount), 0)
    XCTAssertEqual(Int(read.mutualObservationCount), 0)
  }

  /// The band series #143 lists is sparse: a band with no observations is
  /// simply absent from `bandAt(index:)`, never zero-filled (spec §4.1/§6,
  /// AC "遅刻・中断があっても記録された範囲がそのまま見える (無い時間を埋めない)"). This
  /// seeds windows landing in band 0 and band 3 only (`windowsPerBand: 2`),
  /// leaving bands 1-2 with no data, and confirms the persisted-and-reread
  /// series still reports exactly two present bands at their real absolute
  /// indices — the shape `ParticipationSummaryView`'s
  /// `ForEach(0..<aggregate.bandCount)` / `bandAt(index:)` loop depends on
  /// to surface the gap instead of hiding or filling it.
  func testPersistedSnapshotBandSeriesStaysSparseAcrossAGap() throws {
    let (coordinator, store) = makeCoordinator()
    let proof = Proof(eventName: "ETHGlobal Tokyo", date: Date(), peersVerified: 2)
    // windowsPerBand = 2: windowIndex 0 -> band 0, windowIndex 6 -> band 3.
    let aggregate = makeAggregate(
      observations: [
        (windowIndex: 0, peerKey: "peer-a", displayId: "device-a"),
        (windowIndex: 6, peerKey: "peer-b", displayId: "device-b"),
      ],
      windowsPerBand: 2
    )
    try store.persist(aggregate: aggregate, proofId: proof.id)

    let read = try XCTUnwrap(coordinator.sessionAggregateSnapshot(forProofId: proof.id))

    XCTAssertEqual(read.bandCount, 2)
    XCTAssertEqual(read.bandAt(index: 0)?.bandIndex, 0)
    XCTAssertEqual(read.bandAt(index: 1)?.bandIndex, 3)
  }

  // MARK: - Helpers

  /// Mirrors `SessionAggregateSnapshotPersistHookTests.makeCoordinator()`:
  /// an isolated `SensingCoordinator` built with its
  /// `sessionAggregateSnapshotStore` injected explicitly, so the returned
  /// store is the exact same instance `coordinator.sessionAggregateSnapshot
  /// (forProofId:)` reads through — not a same-path-different-instance
  /// stand-in.
  private func makeCoordinator() -> (SensingCoordinator, SessionAggregateSnapshotStore) {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("beid-participation-summary-\(UUID().uuidString)", isDirectory: true)
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    } catch {
      preconditionFailure("Unable to create test directory: \(error)")
    }
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    let store = SessionAggregateSnapshotStore(
      fileURL: directory.appendingPathComponent("session-aggregate-snapshots.json")
    )
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
      sessionAggregateSnapshotStore: store,
      unsentWindowLedgerFileURL: directory.appendingPathComponent("ledger.snapshot"),
      sensingCryptography: DeterministicSensingCryptography()
    )
    coordinator.useDemoEventMode = false
    return (coordinator, store)
  }

  private func makeAggregate(
    observations: [(windowIndex: Int, peerKey: String, displayId: String?)],
    windowsPerBand: Int32
  ) -> BeidSharedKit.aggregation.SessionAggregate {
    let input = BeidSharedKit.aggregation.createAggregationObservationInput()
    for observation in observations {
      _ = BeidSharedKit.aggregation.addAggregationObservation(
        input: input,
        windowIndex: Int64(observation.windowIndex),
        peerKey: observation.peerKey,
        displayId: observation.displayId,
        mutual: false
      )
    }
    return BeidSharedKit.aggregation.aggregateObservationsForSession(
      input: input,
      windowsPerBand: windowsPerBand
    )
  }
}
