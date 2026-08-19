// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import XCTest
@testable import Beid

/// Covers #219: `Proof`'s default `gradientSeed` (used when the caller
/// doesn't pass one explicitly) must be derived deterministically — the
/// same `eventCode`/`eventName` input must always produce the same seed,
/// across process launches, not just within one. `String.hashValue`/
/// `Hasher` are seeded per process (SE-0206) and cannot be used for this;
/// see `Proof.deterministicSeed(for:)`.
///
/// These first two tests use hardcoded golden `Int` literals, not a
/// same-process round-trip comparison. A same-process comparison (calling
/// the derivation twice and asserting equal) would already pass today
/// against the pre-fix `eventName.hashValue` code, because the process
/// seed is fixed for the lifetime of one test run — the bug only shows up
/// *across* launches, which a single test process can't reproduce by
/// construction. The golden literals below were computed once, offline,
/// from the shipped FNV-1a implementation, and are what makes this an
/// actual RED/GREEN test against the pre-fix code (the golden values do
/// not match any `eventName.hashValue` output, whose value differs per
/// process run).
final class ProofTests: XCTestCase {
  private let fixedDate = Date(timeIntervalSince1970: 0)

  /// RED evidence for #219: run before the fix, this fails against
  /// `eventName.hashValue` (see the #219 fix's `red-test-run.log`).
  func testGradientSeedIsDeterministicallyDerivedFromEventCode() {
    let proof = Proof(
      eventName: "ETHGlobal Tokyo",
      date: fixedDate,
      peersVerified: 3,
      eventCode: "ETHTOKYO2026"
    )

    XCTAssertEqual(proof.gradientSeed, -7349755631808400896)
  }

  /// RED evidence for #219 (fallback path — no `eventCode`): same golden-
  /// literal reasoning as above, keyed off `eventName` since `eventCode` is
  /// `nil` here.
  func testGradientSeedFallsBackToEventNameWhenEventCodeIsNil() {
    let proof = Proof(
      eventName: "ETHGlobal Tokyo",
      date: fixedDate,
      peersVerified: 3
    )

    XCTAssertEqual(proof.gradientSeed, -4723829000006765075)
  }

  /// `eventCode` wins over `eventName` when both are present: two proofs
  /// for the same event, recorded under different display names, still get
  /// the same default artwork seed.
  func testGradientSeedIsSameForSameEventCodeDifferentEventName() {
    let first = Proof(
      eventName: "ETHGlobal Tokyo",
      date: fixedDate,
      peersVerified: 3,
      eventCode: "ETHTOKYO2026"
    )
    let second = Proof(
      eventName: "ETH Global — Tokyo (renamed)",
      date: fixedDate,
      peersVerified: 5,
      eventCode: "ETHTOKYO2026"
    )

    XCTAssertEqual(first.gradientSeed, second.gradientSeed)
  }

  /// An explicit `gradientSeed:` argument bypasses derivation entirely and
  /// is kept verbatim.
  func testExplicitGradientSeedIsPreservedVerbatim() {
    let proof = Proof(
      eventName: "ETHGlobal Tokyo",
      date: fixedDate,
      peersVerified: 3,
      gradientSeed: 42,
      eventCode: "ETHTOKYO2026"
    )

    XCTAssertEqual(proof.gradientSeed, 42)
  }
}
