// Copyright (c) 2024-2026 Levarac Foundation
// SPDX-License-Identifier: MIT

import XCTest
@testable import Beid

/// beid#217 — `EventGrouping` is the shared display-side aggregation
/// `CollectionHomeView`/`ItemDetailView` both use (spec §3). `Proof` itself
/// stays session-granular; these tests cover only the grouping/derivation
/// logic, not any view rendering (this codebase has no view-rendering test
/// harness — see `ParticipationSummaryDataTests` for the same
/// data-layer-only precedent).
final class EventGroupingTests: XCTestCase {
  func testHomeGroupsSortByDateAndHideEverySessionOfActiveEvent() {
    let earlierActive = Proof(
      eventName: "Active event", date: Date(timeIntervalSince1970: 100),
      peersVerified: 1, eventCode: "ACTIVE"
    )
    let latestActive = Proof(
      eventName: "Active event", date: Date(timeIntervalSince1970: 400),
      peersVerified: 2, eventCode: "active"
    )
    let older = Proof(
      eventName: "Older event", date: Date(timeIntervalSince1970: 200),
      peersVerified: 1, eventCode: "OLDER"
    )
    let newer = Proof(
      eventName: "Newer event", date: Date(timeIntervalSince1970: 300),
      peersVerified: 1, eventCode: "NEWER"
    )
    // Storage order can differ from dates, for example after import or a
    // device-clock correction. The active event already has two Proofs.
    let stored = [older, earlierActive, newer, latestActive]

    let whileActive = EventGrouping.homeGroups(from: stored, activeEventCode: " active ")
    XCTAssertEqual(whileActive.map { $0[0].eventName }, ["Newer event", "Older event"])

    let afterClose = EventGrouping.homeGroups(from: stored, activeEventCode: nil)
    XCTAssertEqual(afterClose.map { $0[0].eventName }, ["Active event", "Newer event", "Older event"])
    XCTAssertEqual(afterClose[0].map(\.id), [latestActive.id, earlierActive.id])
  }

  func testHomeGroupsKeepLegacyProofsSeparate() {
    let first = Proof(
      eventName: "Legacy A", date: Date(timeIntervalSince1970: 100),
      peersVerified: 1, eventCode: nil
    )
    let second = Proof(
      eventName: "Legacy B", date: Date(timeIntervalSince1970: 200),
      peersVerified: 1, eventCode: nil
    )

    let groups = EventGrouping.homeGroups(from: [first, second], activeEventCode: "ACTIVE")

    XCTAssertEqual(groups.map { $0.map(\.id) }, [[second.id], [first.id]])
  }

  // MARK: - groups(from:)

  func testGroupsOrdersByFirstAppearanceAndPreservesNewestFirstWithinGroup() {
    // Newest-first input, matching ProofStore.proofs' real invariant
    // (ProofStore.add inserts at index 0).
    let newestOfA = Proof(eventName: "Event A", date: Date(), peersVerified: 1, eventCode: "A")
    let onlyOfB = Proof(eventName: "Event B", date: Date(), peersVerified: 1, eventCode: "B")
    let oldestOfA = Proof(eventName: "Event A", date: Date(), peersVerified: 1, eventCode: "A")
    let proofs = [newestOfA, onlyOfB, oldestOfA]

    let groups = EventGrouping.groups(from: proofs)

    XCTAssertEqual(groups.count, 2, "Two distinct eventCodes must produce exactly two groups.")
    XCTAssertEqual(groups[0].map(\.id), [newestOfA.id, oldestOfA.id], "Group A must keep both sessions, newest-first.")
    XCTAssertEqual(groups[1].map(\.id), [onlyOfB.id])
  }

  func testGroupsNeverMergesTwoNilEventCodeProofs() {
    let first = Proof(eventName: "Legacy 1", date: Date(), peersVerified: 1, eventCode: nil)
    let second = Proof(eventName: "Legacy 2", date: Date(), peersVerified: 1, eventCode: nil)
    let proofs = [second, first]

    let groups = EventGrouping.groups(from: proofs)

    XCTAssertEqual(groups.count, 2, "Two eventCode == nil proofs must never be grouped together.")
    XCTAssertEqual(groups[0], [second])
    XCTAssertEqual(groups[1], [first])
  }

  func testGroupsSingleSessionGroupHasOldestEqualNewest() {
    let solo = Proof(eventName: "Solo Event", date: Date(), peersVerified: 1, eventCode: "SOLO")

    let groups = EventGrouping.groups(from: [solo])

    XCTAssertEqual(groups.count, 1)
    XCTAssertEqual(groups[0].first, groups[0].last, "A single-session group must degenerate to first == last.")
  }

  // MARK: - sessions(for:in:)

  func testSessionsForProofWithEventCodeReturnsAllMatchingSessionsNewestFirst() {
    let newest = Proof(eventName: "Event A", date: Date(), peersVerified: 1, eventCode: "A")
    let unrelated = Proof(eventName: "Event B", date: Date(), peersVerified: 1, eventCode: "B")
    let oldest = Proof(eventName: "Event A", date: Date(), peersVerified: 1, eventCode: "A")
    let proofs = [newest, unrelated, oldest]

    let sessions = EventGrouping.sessions(for: newest, in: proofs)

    XCTAssertEqual(sessions.map(\.id), [newest.id, oldest.id])
  }

  func testSessionsForNilEventCodeProofIsAlwaysASingletonRegardlessOfOtherNilProofs() {
    let target = Proof(eventName: "Legacy", date: Date(), peersVerified: 1, eventCode: nil)
    let otherNil = Proof(eventName: "Other Legacy", date: Date(), peersVerified: 1, eventCode: nil)
    let proofs = [target, otherNil]

    let sessions = EventGrouping.sessions(for: target, in: proofs)

    XCTAssertEqual(sessions, [target], "A nil-eventCode proof's session list must never include another nil-eventCode proof.")
  }

  // MARK: - Regression: artwork stability across re-scans (PM-required A1 fix)

  /// The exact scenario the PM's spec-review comment describes: a user
  /// scans event A, then re-scans it in a later app run where
  /// `gradientSeed` (via #219's known instability, SE-0206) differs from
  /// the first scan. The group's *oldest* session must still drive the
  /// artwork seed — this is the property that makes `ProofCardView`'s and
  /// `ItemDetailView`'s artwork stop mutating on re-scan (spec §5.1/§6.1).
  func testOldestSessionGradientSeedIsUnaffectedByANewerSessionWithADifferentSeed() {
    let firstScanSeed = 111
    let oldest = Proof(
      eventName: "ETHGlobal Tokyo", date: Date().addingTimeInterval(-86_400), peersVerified: 1,
      gradientSeed: firstScanSeed, eventCode: "ETHTOKYO"
    )
    var proofs = [oldest]
    let groupsBeforeRescan = EventGrouping.groups(from: proofs)
    XCTAssertEqual(groupsBeforeRescan[0].last?.gradientSeed, firstScanSeed)

    // Re-scan in a "later app run": a new Proof becomes newest, carrying a
    // different gradientSeed (per #219, String.hashValue is not stable
    // across process launches).
    let secondScanSeed = 999
    let newest = Proof(
      eventName: "ETHGlobal Tokyo", date: Date(), peersVerified: 1,
      gradientSeed: secondScanSeed, eventCode: "ETHTOKYO"
    )
    proofs.insert(newest, at: 0) // ProofStore.add semantics: newest-first.

    let groupsAfterRescan = EventGrouping.groups(from: proofs)
    let group = groupsAfterRescan[0]

    XCTAssertEqual(group.last?.gradientSeed, firstScanSeed, "Artwork-driving seed (oldest session) must not change after a re-scan.")
    XCTAssertEqual(group.first?.gradientSeed, secondScanSeed, "The newest session's own seed is unrelated to the artwork seed — only its title/date are used.")
    XCTAssertEqual(group.first?.date, newest.date, "Title/date must still track the newest session.")
  }

  // MARK: - beid#226/DECISIONS 2026-08-20: normalized comparison key

  func testGroupsMergesEventCodesDifferingOnlyByCase() {
    let upper = Proof(eventName: "Event", date: Date(), peersVerified: 1, eventCode: "ETHTOKYO")
    let lower = Proof(eventName: "Event", date: Date(), peersVerified: 1, eventCode: "ethtokyo")
    let proofs = [upper, lower]

    let groups = EventGrouping.groups(from: proofs)

    XCTAssertEqual(groups.count, 1, "\"ETHTOKYO\" and \"ethtokyo\" must normalize to the same group.")
    XCTAssertEqual(groups[0].map(\.id), [upper.id, lower.id])
  }

  func testSessionsForEitherCasingReturnsBoth() {
    let upper = Proof(eventName: "Event", date: Date(), peersVerified: 1, eventCode: "ETHTOKYO")
    let lower = Proof(eventName: "Event", date: Date(), peersVerified: 1, eventCode: "ethtokyo")
    let proofs = [upper, lower]

    XCTAssertEqual(
      EventGrouping.sessions(for: upper, in: proofs).map(\.id), [upper.id, lower.id],
      "sessions(for:in:) from the upper-case proof must include the lower-case one."
    )
    XCTAssertEqual(
      EventGrouping.sessions(for: lower, in: proofs).map(\.id), [upper.id, lower.id],
      "sessions(for:in:) from the lower-case proof must include the upper-case one."
    )
  }

  func testPastEventsCollapsesDifferentlyCasedEventCodesToOneRepresentative() {
    let older = Proof(eventName: "Event", date: Date().addingTimeInterval(-3600), peersVerified: 1, eventCode: "ETHTOKYO")
    let newer = Proof(eventName: "Event", date: Date(), peersVerified: 1, eventCode: "ethtokyo")
    let proofs = [newer, older] // newest-first

    let past = EventGrouping.pastEvents(from: proofs)

    XCTAssertEqual(past.count, 1, "Differently-cased eventCodes for the same event must collapse to one past-events entry.")
    XCTAssertEqual(past[0].id, newer.id, "The representative must still be the group's newest proof.")
  }

  // MARK: - pastEvents(from:) — beid#230

  func testPastEventsReturnsOneRepresentativePerDistinctEventCodeNewestFirst() {
    let newestOfA = Proof(eventName: "Event A", date: Date(), peersVerified: 1, eventCode: "A")
    let onlyOfB = Proof(eventName: "Event B", date: Date(), peersVerified: 1, eventCode: "B")
    let oldestOfA = Proof(eventName: "Event A", date: Date(), peersVerified: 1, eventCode: "A")
    // Newest-first input, matching ProofStore.proofs' real invariant.
    let proofs = [onlyOfB, newestOfA, oldestOfA]

    let past = EventGrouping.pastEvents(from: proofs)

    XCTAssertEqual(past.map(\.id), [onlyOfB.id, newestOfA.id], "One representative per eventCode, ordered by that eventCode's first (newest) appearance.")
  }

  func testPastEventsRepresentativeIsTheNewestProofInEachGroup() {
    let older = Proof(eventName: "Old Name", date: Date().addingTimeInterval(-3600), peersVerified: 1, eventCode: "A")
    let newer = Proof(eventName: "New Name", date: Date(), peersVerified: 1, eventCode: "A")
    let proofs = [newer, older] // newest-first

    let past = EventGrouping.pastEvents(from: proofs)

    XCTAssertEqual(past.count, 1)
    XCTAssertEqual(past[0].id, newer.id, "The representative must be the group's newest proof, not its oldest.")
  }

  func testPastEventsOmitsNilEventCodeProofsEntirely() {
    let legacy = Proof(eventName: "Legacy", date: Date(), peersVerified: 1, eventCode: nil)
    let real = Proof(eventName: "Event A", date: Date(), peersVerified: 1, eventCode: "A")
    let proofs = [legacy, real]

    let past = EventGrouping.pastEvents(from: proofs)

    XCTAssertEqual(past.map(\.id), [real.id], "A nil-eventCode proof must never appear in the past-events list, not even as a false/placeholder entry.")
  }

  func testPastEventsWithOnlyNilEventCodeProofsIsEmpty() {
    let first = Proof(eventName: "Legacy 1", date: Date(), peersVerified: 1, eventCode: nil)
    let second = Proof(eventName: "Legacy 2", date: Date(), peersVerified: 1, eventCode: nil)

    let past = EventGrouping.pastEvents(from: [first, second])

    XCTAssertTrue(past.isEmpty)
  }

  func testPastEventsWithNoProofsIsEmpty() {
    XCTAssertTrue(EventGrouping.pastEvents(from: []).isEmpty)
  }
}
