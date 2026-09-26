// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import XCTest
@testable import Beid

/// beid#701 T7. The display decision for 09, 11 and 12, over real stores in
/// an isolated directory. Link content needs a link row, the Proof in
/// `ProofStore`, and the same normalized event code; anything else is
/// today's unlinked screen.
@MainActor
final class ReportProofLinkPresentationTests: XCTestCase {
  private let eventCode = "ETHTOKYO2026"
  private var directory: URL!

  override func setUp() async throws {
    try await super.setUp()
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("report-proof-link-presentation-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }

  override func tearDown() async throws {
    try? FileManager.default.removeItem(at: directory)
    try await super.tearDown()
  }

  // MARK: - 12: session and proof

  func testLinkedReportShowsItsOwnSessionAndProof() throws {
    let stores = makeStores()
    let proofs = seedThreeSessions(in: stores.proofs)
    let record = makeRecord(id: 9, createdAt: 150)
    try stores.links.add(windowId: record.id, proofId: proofs[1].id)

    let session = ReportProofLinkPresentation.session(
      for: record, linkStore: stores.links, proofStore: stores.proofs, hasSelfProof: { _ in false }
    )

    XCTAssertEqual(session?.proof.id, proofs[1].id)
    XCTAssertEqual(session?.ordinal, 2)
    XCTAssertEqual(session?.proofState, "RECORDED ON DEVICE")
    XCTAssertEqual(session?.proofSubtitle, "RECORDED ON DEVICE · 0000…0002")
  }

  /// Old records stay unlinked even when a same-event Proof exists nearby;
  /// nothing falls back to a guess by event code or time (M8).
  func testUnlinkedReportShowsNoSessionEvenWithSameEventProofs() {
    let stores = makeStores()
    let proofs = seedThreeSessions(in: stores.proofs)
    let record = makeRecord(id: 9, createdAt: 150)

    XCTAssertNil(ReportProofLinkPresentation.session(
      for: record, linkStore: stores.links, proofStore: stores.proofs, hasSelfProof: { _ in true }
    ))
    for proof in proofs {
      XCTAssertEqual(reports(for: proof, in: stores, records: [record]), [])
    }
  }

  func testUnreadableLinkTableShowsNoLinkContent() throws {
    let linkURL = directory.appendingPathComponent("report-proof-links.json")
    try Data("not a link table".utf8).write(to: linkURL)
    let stores = makeStores(linkURL: linkURL)
    let proofs = seedThreeSessions(in: stores.proofs)
    let record = makeRecord(id: 9, createdAt: 150)
    XCTAssertEqual(stores.links.proofId(forWindowId: record.id), .failure(.unreadable))

    XCTAssertNil(ReportProofLinkPresentation.session(
      for: record, linkStore: stores.links, proofStore: stores.proofs, hasSelfProof: { _ in true }
    ))
    XCTAssertEqual(reports(for: proofs[0], in: stores, records: [record]), [])
  }

  /// M9: a link row alone is not enough; its Proof must still be stored.
  func testLinkToAProofMissingFromTheStoreShowsNothing() throws {
    let stores = makeStores()
    _ = seedThreeSessions(in: stores.proofs)
    let absent = Proof(
      id: uuid(99), eventName: "ETH Tokyo 2026",
      date: Date(timeIntervalSince1970: 400), peersVerified: 0, eventCode: eventCode
    )
    let record = makeRecord(id: 9, createdAt: 150)
    try stores.links.add(windowId: record.id, proofId: absent.id)

    XCTAssertNil(ReportProofLinkPresentation.session(
      for: record, linkStore: stores.links, proofStore: stores.proofs, hasSelfProof: { _ in true }
    ))
    XCTAssertEqual(reports(for: absent, in: stores, records: [record]), [])
  }

  func testLinkAcrossDifferentEventCodesShowsNothing() throws {
    let stores = makeStores()
    let proofs = seedThreeSessions(in: stores.proofs)
    let record = makeRecord(id: 9, createdAt: 150, eventCode: "OTHER2026")
    try stores.links.add(windowId: record.id, proofId: proofs[0].id)

    XCTAssertNil(ReportProofLinkPresentation.session(
      for: record, linkStore: stores.links, proofStore: stores.proofs, hasSelfProof: { _ in true }
    ))
    XCTAssertEqual(reports(for: proofs[0], in: stores, records: [record]), [])
  }

  /// The event-code check is the grouping key, not raw string equality.
  func testLinkMatchesEventCodesUnderTheGroupingNormalization() throws {
    let stores = makeStores()
    let proofs = seedThreeSessions(in: stores.proofs)
    let record = makeRecord(id: 9, createdAt: 150, eventCode: " ethtokyo2026 ")
    try stores.links.add(windowId: record.id, proofId: proofs[0].id)

    XCTAssertEqual(ReportProofLinkPresentation.session(
      for: record, linkStore: stores.links, proofStore: stores.proofs, hasSelfProof: { _ in false }
    )?.ordinal, 1)
    XCTAssertEqual(
      reports(for: proofs[0], in: stores, records: [record]),
      [LinkedReport(ordinal: 1, record: record)]
    )
  }

  /// M10/M13: 12 reads 08's state for the linked Proof, and nothing else.
  func testProofStateIsEventDetailsStateForTheLinkedProof() throws {
    let stores = makeStores()
    let proofs = seedThreeSessions(in: stores.proofs)
    let record = makeRecord(id: 9, createdAt: 150)
    try stores.links.add(windowId: record.id, proofId: proofs[1].id)

    var askedIDs: [UUID] = []
    let sealed = ReportProofLinkPresentation.session(
      for: record, linkStore: stores.links, proofStore: stores.proofs,
      hasSelfProof: { id in
        askedIDs.append(id)
        return id == proofs[1].id
      }
    )
    XCTAssertEqual(askedIDs, [proofs[1].id])
    XCTAssertEqual(sealed?.proofState, "SEALED")
    XCTAssertEqual(sealed?.proofState, SessionDisplay.proofState(hasSelfProof: true))
    XCTAssertEqual(sealed?.proofSubtitle, "SEALED · 0000…0002")

    // Another session's SelfProofRecord never seals this one.
    let recorded = ReportProofLinkPresentation.session(
      for: record, linkStore: stores.links, proofStore: stores.proofs,
      hasSelfProof: { $0 == proofs[0].id }
    )
    XCTAssertEqual(recorded?.proofState, "RECORDED ON DEVICE")
    XCTAssertEqual(recorded?.proofState, SessionDisplay.proofState(hasSelfProof: false))

    for subtitle in [sealed?.proofSubtitle, recorded?.proofSubtitle].compactMap({ $0 }) {
      XCTAssertFalse(subtitle.localizedCaseInsensitiveContains("verif"), subtitle)
      XCTAssertFalse(subtitle.localizedCaseInsensitiveContains("mutual"), subtitle)
    }
  }

  // MARK: - 09 / 11: reports of one Proof

  /// Rows keep Event Detail's event-wide numbers and order, so `Report #3`
  /// is the same report on 08, 09 and 11.
  func testLinkedReportsKeepEventDetailOrdinalsAndOrder() throws {
    let stores = makeStores()
    let proofs = seedThreeSessions(in: stores.proofs)
    let first = makeRecord(id: 11, createdAt: 110)
    let second = makeRecord(id: 12, createdAt: 210)
    let third = makeRecord(id: 13, createdAt: 120)
    for record in [first, second, third] { try stores.submissions.add(record) }
    try stores.links.add(windowId: first.id, proofId: proofs[0].id)
    try stores.links.add(windowId: second.id, proofId: proofs[1].id)
    try stores.links.add(windowId: third.id, proofId: proofs[0].id)

    let eventOrder = try stores.submissions.eventRecords(forEventCode: eventCode).get()
    XCTAssertEqual(eventOrder.map(\.id), [first.id, third.id, second.id])

    XCTAssertEqual(
      ReportProofLinkPresentation.reports(
        for: proofs[0], submissionStore: stores.submissions,
        linkStore: stores.links, proofStore: stores.proofs
      ),
      [LinkedReport(ordinal: 1, record: first), LinkedReport(ordinal: 2, record: third)]
    )
    XCTAssertEqual(
      ReportProofLinkPresentation.reports(
        for: proofs[1], submissionStore: stores.submissions,
        linkStore: stores.links, proofStore: stores.proofs
      ),
      [LinkedReport(ordinal: 3, record: second)]
    )
    XCTAssertEqual(
      ReportProofLinkPresentation.reports(
        for: proofs[2], submissionStore: stores.submissions,
        linkStore: stores.links, proofStore: stores.proofs
      ),
      []
    )
  }

  func testUnreadableReportStoreShowsNoLinkedReports() throws {
    let reportURL = directory.appendingPathComponent("report-submissions.json")
    try Data("not a report list".utf8).write(to: reportURL)
    let stores = makeStores(reportURL: reportURL)
    let proofs = seedThreeSessions(in: stores.proofs)
    try stores.links.add(windowId: uuid(11), proofId: proofs[0].id)

    XCTAssertEqual(ReportProofLinkPresentation.reports(
      for: proofs[0], submissionStore: stores.submissions,
      linkStore: stores.links, proofStore: stores.proofs
    ), [])
  }

  // MARK: - Session ordinal (§C)

  /// 08 numbers its rows by `orderedSessions`; 11 receives that number and
  /// 12 derives it through `sessionOrdinal`. Equal dates fall back to the
  /// id, whatever order the store holds them in (M11).
  func testSessionOrdinalMatchesEventDetailOrderIncludingAnEqualDateTie() throws {
    let early = makeProof(id: 3, at: 100)
    let tiedLow = makeProof(id: 1, at: 200)
    let tiedHigh = makeProof(id: 2, at: 200)
    let late = makeProof(id: 4, at: 300)
    let otherEvent = makeProof(id: 5, at: 50, eventCode: "OTHER2026")
    let expected = [early.id, tiedLow.id, tiedHigh.id, late.id]

    for stored in [
      [late, tiedHigh, tiedLow, early, otherEvent],
      [otherEvent, early, tiedLow, tiedHigh, late],
      [tiedHigh, otherEvent, late, early, tiedLow],
    ] {
      let eventDetailOrder = EventGrouping.orderedSessions(for: late, in: stored)
      XCTAssertEqual(eventDetailOrder.map(\.id), expected)
      for (index, proof) in eventDetailOrder.enumerated() {
        XCTAssertEqual(EventGrouping.sessionOrdinal(of: proof, in: stored), index + 1)
      }
    }
    XCTAssertEqual(EventGrouping.sessionOrdinal(of: otherEvent, in: [early, otherEvent]), 1)
    XCTAssertNil(EventGrouping.sessionOrdinal(of: late, in: [early, tiedLow]))

    // The 12 path over a real store, whose insertion order is newest-first.
    let stores = makeStores()
    for proof in [tiedHigh, early, late, tiedLow] { stores.proofs.add(proof) }
    let record = makeRecord(id: 9, createdAt: 250)
    try stores.links.add(windowId: record.id, proofId: tiedHigh.id)
    XCTAssertEqual(ReportProofLinkPresentation.session(
      for: record, linkStore: stores.links, proofStore: stores.proofs, hasSelfProof: { _ in false }
    )?.ordinal, 3)
  }

  // MARK: - Helpers

  private struct Stores {
    let proofs: ProofStore
    let submissions: ReportSubmissionStore
    let links: ReportProofLinkStore
  }

  private func makeStores(linkURL: URL? = nil, reportURL: URL? = nil) -> Stores {
    Stores(
      proofs: ProofStore(fileURL: directory.appendingPathComponent("proofs.json")),
      submissions: ReportSubmissionStore(
        fileURL: reportURL ?? directory.appendingPathComponent("report-submissions.json")
      ),
      links: ReportProofLinkStore(
        fileURL: linkURL ?? directory.appendingPathComponent("report-proof-links.json")
      )
    )
  }

  /// Sessions 1, 2, 3 by date; returned in that order.
  private func seedThreeSessions(in store: ProofStore) -> [Proof] {
    let proofs = [makeProof(id: 1, at: 100), makeProof(id: 2, at: 200), makeProof(id: 3, at: 300)]
    for proof in proofs.reversed() { store.add(proof) }
    return proofs
  }

  private func reports(for proof: Proof, in stores: Stores, records: [ReportSubmissionRecord]) -> [LinkedReport] {
    for record in records { _ = try? stores.submissions.add(record) }
    return ReportProofLinkPresentation.reports(
      for: proof, submissionStore: stores.submissions,
      linkStore: stores.links, proofStore: stores.proofs
    )
  }

  private func makeProof(id: Int, at seconds: TimeInterval, eventCode: String? = nil) -> Proof {
    Proof(
      id: uuid(id), eventName: "ETH Tokyo 2026",
      date: Date(timeIntervalSince1970: seconds), peersVerified: 0,
      eventCode: eventCode ?? self.eventCode
    )
  }

  private func makeRecord(
    id: Int,
    createdAt seconds: TimeInterval,
    eventCode: String? = nil
  ) -> ReportSubmissionRecord {
    ReportSubmissionRecord(
      id: uuid(id),
      eventCode: eventCode ?? self.eventCode,
      endpoint: "https://example.invalid/observations",
      receiptPublicKeyHex: String(repeating: "a", count: 64),
      eventIdHex: nil,
      eventDefinitionDigestHex: nil,
      validFrom: nil,
      validUntil: nil,
      signedObservationHex: "d28440a04040",
      observationDigestHex: String(repeating: "b", count: 64),
      submissionState: .prepared,
      createdAt: Date(timeIntervalSince1970: seconds)
    )
  }

  private func uuid(_ value: Int) -> UUID {
    UUID(uuidString: String(format: "00000000-0000-4000-8000-%012ld", value))!
  }
}
