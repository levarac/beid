// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import XCTest

/// Two absences the relay work depends on (beid#367).
///
/// The issue asks for these to be pinned rather than merely intended, and the
/// only honest way to pin an absence is to read the source. A behavioural test
/// can show that today's code path signs nothing and that no scenario arms a
/// radio; it cannot stop someone adding a proof write to the verifier, or
/// teaching a scenario to seed discovery, next month. That is the regression
/// worth preventing.
///
/// Deliberately blunt: each check fails on a name, and the fix is either to
/// move the new work out of the named file or to argue here why a term on the
/// list is not what it looks like.
///
/// **These lists are mirrored in Android's `ParticipantRelayIsolationTest` and
/// must stay identical.** A name dropped from one side is a hole on that
/// platform only, which is the hardest kind of gap to notice: the suite still
/// passes everywhere someone thinks to look.
final class ParticipantRelayIsolationTests: XCTestCase {
  func testTheRelaySourcesNameNothingFromTheRecordingSigningOrSubmissionPaths() throws {
    try assertSources(
      Self.relaySources,
      avoid: Self.recordingSigningSubmission,
      role: "relay"
    )
  }

  /// The other direction, and the reason it is a separate list: the relay
  /// sources legitimately name the relay-arming and discovery symbols, while
  /// the scenario sources must never name any of them. A scenario that could
  /// seed discovery or arm the relay would put fabricated candidates on a real
  /// radio.
  func testTheScenarioSourcesNameNothingThatSeedsDiscoveryOrArmsTheRelay() throws {
    try assertSources(
      Self.scenarioSources,
      avoid: Self.discoverySeedingAndRelayArming,
      role: "scenario"
    )
  }

  private func assertSources(
    _ relativePaths: [String],
    avoid forbidden: [String],
    role: String
  ) throws {
    for relativePath in relativePaths {
      // `#filePath` is this file inside the checkout, which is the only way a
      // test bundle can reach app source at all.
      let source = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent(relativePath)
      let text = try String(contentsOf: source, encoding: .utf8)

      for name in forbidden {
        XCTAssertFalse(
          text.contains(name),
          "\(relativePath) references \(name), which a \(role) source must not reach into"
        )
      }
    }
  }

  private static let relaySources = [
    "Beid/Sensing/ParticipantRelayVerifier.swift"
  ]

  private static let scenarioSources = [
    "Beid/Models/DemoScenario.swift"
  ]

  /// Names owned by the paths relay is fenced off from: the observation
  /// ledger, self-proof signing, and report submission. Keep identical to
  /// Android's list of the same name.
  private static let recordingSigningSubmission = [
    "SelfProof",
    "ProofRecord",
    "SensingCryptography",
    "WindowObservation",
    "WindowAccumulator",
    "WindowReport",
    "UnsentWindowLedger",
    "BindingRecord",
    "ReportSubmission",
    "AggregationRuntime",
    "ScanPhase",
  ]

  /// Names that seed the discovery store or arm the participant relay. A
  /// scenario reaching any of these would put fabricated candidates in front
  /// of the join gate, or fabricated bytes on a radio. Keep identical to
  /// Android's list of the same name.
  private static let discoverySeedingAndRelayArming = [
    "recordNearbyEventRadioSelfVerified",
    "completeNearbyEventRegistryResolution",
    "applyNearbyEventRegistryAgreement",
    "configureParticipantRelay",
    "setParticipantRelayVerifier",
  ]
}
