// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import BeidSharedKit
import XCTest
@testable import Beid

/// Presentation of a record's Sigil (beid#653, docs/decisions/
/// issue-653-design.md §4, §6, §7).
///
/// `scripts/mutation_check.py` mutates Kotlin only, so the Swift literals here
/// (sizes, grounds, the page) are pinned by literal expectations instead.
@MainActor
final class RecordSigilPresentationTests: XCTestCase {

  // MARK: - Placements (OD-6, measured from the Figma exports)

  func testEveryPlacementHasItsMeasuredSizeAndGrounds() {
    struct Expected {
      let size: CGFloat
      let page: RecordSigilSlot.Ground
      let sigilGround: BeidSharedKit.sigil.SigilGround
    }
    let expected: [RecordSigilPlacement: Expected] = [
      .homeActiveCard: Expected(size: 84, page: .ink, sigilGround: .NONE),
      .homePastRow: Expected(size: 60, page: .canvas, sigilGround: .NONE),
      .sensingSealed: Expected(size: 300, page: .ink, sigilGround: .NONE),
      .proofCollected: Expected(size: 290, page: .canvas, sigilGround: .DISC),
      .eventDetailRow: Expected(size: 48, page: .canvas, sigilGround: .NONE),
      .proofDetail: Expected(size: 200, page: .canvas, sigilGround: .DISC),
      .reportDetailRow: Expected(size: 40, page: .canvas, sigilGround: .NONE),
    ]
    XCTAssertEqual(RecordSigilPlacement.allCases.count, 7)
    for placement in RecordSigilPlacement.allCases {
      guard let want = expected[placement] else {
        XCTFail("\(placement) has no measured expectation")
        continue
      }
      XCTAssertEqual(placement.size, want.size, "\(placement) size")
      XCTAssertEqual(placement.page, want.page, "\(placement) page")
      XCTAssertTrue(placement.sigilGround == want.sigilGround, "\(placement) ground")
    }
  }

  func testTheRowPlacementsAreMinisAndTheRestAreFull() {
    let input = BeidSharedKit.sigil.createSigilInput(windowCount: 1)
    for placement in RecordSigilPlacement.allCases {
      let layout = BeidSharedKit.sigil.layoutSigil(
        input: input, size: Double(placement.size), ground: placement.sigilGround
      )
      XCTAssertTrue(layout.isSuccess, "\(placement)")
      let expectMini = placement == .homePastRow || placement == .eventDetailRow
        || placement == .reportDetailRow
      XCTAssertEqual(layout.isMini, expectMini, "\(placement)")
    }
  }

  // MARK: - No data keeps the ring

  func testNoInputDrawsTheNeutralRingAndAnInputDrawsTheSigil() {
    guard case .neutralRing = RecordSigilSlot.artwork(for: nil) else {
      return XCTFail("a record without data must keep the neutral ring")
    }
    let input = BeidSharedKit.sigil.createSigilInput(windowCount: 1)
    guard case .sigil = RecordSigilSlot.artwork(for: input) else {
      return XCTFail("a record with data must draw its Sigil")
    }
  }

  // MARK: - Color on an ink page

  func testMarksOnAnInkPageAreBgAndTheGroundStaysInk() {
    let marks: [BeidSharedKit.sigil.SigilPrimitiveKind] = [
      .RING, .DETECTED_LINE, .MUTUAL_LINE, .DETECTED_DOT, .MUTUAL_DOT, .CENTER_DOT,
    ]
    for kind in marks {
      XCTAssertEqual(SigilDrawing.inkRole(for: kind, ground: .NONE, page: .ink), .onInk)
      XCTAssertEqual(SigilDrawing.inkRole(for: kind, ground: .NONE, page: .canvas), .ink)
      XCTAssertEqual(SigilDrawing.inkRole(for: kind, ground: .DISC, page: .canvas), .onInk)
      XCTAssertEqual(SigilDrawing.inkRole(for: kind, ground: .NONE), .ink, "default page is canvas")
    }
    XCTAssertEqual(SigilDrawing.inkRole(for: .GROUND_DISC, ground: .DISC, page: .ink), .ink)
    XCTAssertEqual(SigilDrawing.inkRole(for: .GROUND_OUTLINE, ground: .OUTLINE, page: .ink), .ink)
    XCTAssertEqual(RecordSigilSlot.Ground.ink.sigilPage, .ink)
    XCTAssertEqual(RecordSigilSlot.Ground.canvas.sigilPage, .canvas)
  }

  func testEveryMarkOnTheInkPagePlacementsIsDrawnInBg() {
    let input = BeidSharedKit.sigil.createSigilInput(windowCount: 3)
    for (peer, window) in [("a", 0), ("a", 1), ("b", 2)] {
      XCTAssertTrue(BeidSharedKit.sigil.addSigilPresence(
        input: input, peerKey: peer, windowIndex: Int32(window), presence: 1
      ))
    }
    for placement in RecordSigilPlacement.allCases where placement.page == .ink {
      let layout = BeidSharedKit.sigil.layoutSigil(
        input: input, size: Double(placement.size), ground: placement.sigilGround
      )
      let commands = SigilDrawing.commands(
        for: layout, ground: placement.sigilGround, page: placement.page.sigilPage
      )
      XCTAssertFalse(commands.isEmpty, "\(placement)")
      for command in commands {
        switch command {
        case let .fill(_, _, role), let .strokeCircle(_, _, _, role), let .strokeLine(_, _, _, role):
          XCTAssertEqual(role, .onInk, "\(placement): an ink mark on an ink page is invisible")
        }
      }
    }
  }

  // MARK: - Coordinator: stored data, counts, and a failing source

  private func makeCoordinator(
    tokenSource: (any SigilPresenceTokenSource)? = nil
  ) throws -> (SensingCoordinator, SigilPresenceStore) {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("beid653-presentation-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    let store = SigilPresenceStore(fileURL: directory.appendingPathComponent("sigil-presence.json"))
    let coordinator = SensingCoordinator(
      windowReportStore: WindowReportStore(fileURL: directory.appendingPathComponent("window-reports.json")),
      selfProofStore: SelfProofStore(fileURL: directory.appendingPathComponent("self-proofs.json")),
      selfProofCheckpointStore: SelfProofCheckpointStore(
        fileURL: directory.appendingPathComponent("self-proof-checkpoint.json")
      ),
      bindingRecordStore: BindingRecordStore(fileURL: directory.appendingPathComponent("binding-records.json")),
      sessionAggregateSnapshotStore: SessionAggregateSnapshotStore(
        fileURL: directory.appendingPathComponent("session-aggregate-snapshots.json")
      ),
      sigilPresenceStore: store,
      sigilPresenceTokenSource: tokenSource,
      unsentWindowLedgerFileURL: directory.appendingPathComponent("ledger.snapshot"),
      sensingCryptography: DeterministicSensingCryptography()
    )
    coordinator.useDemoEventMode = false
    return (coordinator, store)
  }

  /// Drives three windows; one detection per window has no display id.
  private func record(on coordinator: SensingCoordinator, expectLiveSigil: Bool = true) throws -> UUID {
    let devices = max(BeidConfig.eventConfirmThreshold, 3)
    coordinator.startSensing(eventCode: "BEID653-PRESENTATION")
    for enin in [40, 41, 43] {
      for device in 0..<devices where !(enin == 43 && device == 0) {
        coordinator.handleDetection(
          enin: enin,
          rpid: DetectionFixture.rotatingRpid(device: device, enin: enin),
          detectedDisplayId: DetectionFixture.displayId(device: device),
          reporterRpid: "c0ffee00c0ffee00c0ffee00"
        )
      }
      coordinator.handleDetection(
        enin: enin,
        rpid: "rpid-unidentified-\(enin)",
        detectedDisplayId: nil,
        reporterRpid: "c0ffee00c0ffee00c0ffee00"
      )
    }
    let proofId = try XCTUnwrap(coordinator.currentProofID)
    if expectLiveSigil {
      XCTAssertNotNil(coordinator.liveSigilInput, "the active card draws live during recording")
    } else {
      XCTAssertNil(
        coordinator.liveSigilInput,
        "no token means no live Sigil: an untokened peer is never drawn, and never with a zero token"
      )
    }
    coordinator.reset()
    XCTAssertNil(coordinator.liveSigilInput, "the live Sigil ends with the session")
    return proofId
  }

  func testAStoredRecordDrawsItsMeasuredCountsAndNothingMutual() throws {
    let (coordinator, _) = try makeCoordinator()
    let proofId = try record(on: coordinator)
    let aggregate = try XCTUnwrap(coordinator.sessionAggregateSnapshot(forProofId: proofId))
    let input = try XCTUnwrap(coordinator.sigilInput(forProofId: proofId))

    let full = BeidSharedKit.sigil.layoutSigil(input: input, size: 290, ground: .DISC)
    XCTAssertEqual(full.mutualPeerCount, 0)
    XCTAssertEqual(full.detectedPeerCount, aggregate.deviceCount)
    XCTAssertEqual(full.windowCount, aggregate.windowCount)
    XCTAssertEqual(
      SigilDrawing.accessibilitySummary(for: full),
      "0 mutual, \(aggregate.deviceCount) detected, window \(aggregate.windowCount)"
    )
    XCTAssertFalse(SigilDrawing.isAccessibilityHidden(for: full))

    // With no presence 2 the mini is the centre dot alone (OD-3).
    let mini = BeidSharedKit.sigil.layoutSigil(input: input, size: 60, ground: .NONE)
    XCTAssertTrue(mini.isMini)
    XCTAssertEqual(mini.primitiveCount, 1)
    XCTAssertTrue(mini.primitiveAt(index: 0)?.kind == BeidSharedKit.sigil.SigilPrimitiveKind.CENTER_DOT)
  }

  func testARecordWithoutPresenceKeepsTheRing() throws {
    let (coordinator, _) = try makeCoordinator()
    let input = coordinator.sigilInput(forProofId: UUID())
    XCTAssertNil(input)
    guard case .neutralRing = RecordSigilSlot.artwork(for: input) else {
      return XCTFail("no row must mean the neutral ring")
    }
  }

  func testAFailingTokenSourceWritesNoRowAndLeavesTheCountsAlone() throws {
    let (coordinator, store) = try makeCoordinator(tokenSource: FailingSigilPresenceTokenSource())
    let proofId = try record(on: coordinator, expectLiveSigil: false)
    XCTAssertTrue(store.records.isEmpty, "never a zero token, never a partial row")
    XCTAssertNil(coordinator.sigilInput(forProofId: proofId))
    XCTAssertNotNil(coordinator.sessionAggregateSnapshot(forProofId: proofId),
                    "the counts are independent of the Sigil")
  }

  func testTheSystemTokenSourceDrawsThirtyTwoLowercaseHexCharacters() throws {
    let source = SystemSigilPresenceTokenSource()
    var seen: Set<String> = []
    for _ in 0..<64 {
      let token = try XCTUnwrap(source.nextToken())
      XCTAssertEqual(token.count, 32)
      XCTAssertTrue(token.allSatisfy { $0.isHexDigit && !$0.isUppercase }, token)
      seen.insert(token)
    }
    XCTAssertEqual(seen.count, 64, "a CSPRNG repeated itself")
  }
}

private struct FailingSigilPresenceTokenSource: SigilPresenceTokenSource {
  func nextToken() -> String? { nil }
}
