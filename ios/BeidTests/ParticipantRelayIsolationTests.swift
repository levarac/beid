// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import XCTest

/// Relay must never touch recording, signing, or submission (beid#367).
///
/// The issue asks for this to be pinned rather than merely intended, and the
/// only honest way to pin an absence is to read the source. A behavioural test
/// can show that today's code path signs nothing; it cannot stop someone
/// adding a proof write to the verifier next month, which is the regression
/// worth preventing.
///
/// Deliberately blunt: it fails on a name, and the fix is either to move the
/// new work out of the relay file or to argue here why a term on this list is
/// not what it looks like. Its Android counterpart is
/// `ParticipantRelayIsolationTest`.
final class ParticipantRelayIsolationTests: XCTestCase {
  func testTheRelayFileNamesNothingFromTheRecordingSigningOrSubmissionPaths() throws {
    // `#filePath` is this file inside the checkout, which is the only way a
    // test bundle can reach app source at all.
    let source = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Beid/Sensing/ParticipantRelayVerifier.swift")
    let text = try String(contentsOf: source, encoding: .utf8)

    for forbidden in Self.forbidden {
      XCTAssertFalse(
        text.contains(forbidden),
        "ParticipantRelayVerifier.swift references \(forbidden); relay must not reach "
          + "into recording, signing or submission"
      )
    }
  }

  /// Type and concept names owned by the paths relay is fenced off from: the
  /// observation ledger, self-proof signing, and report submission.
  private static let forbidden = [
    "SelfProof",
    "ProofRecord",
    "SensingCryptography",
    "WindowReport",
    "UnsentWindowLedger",
    "BindingRecord",
    "AggregationRuntime",
    "ScanPhase",
  ]
}
