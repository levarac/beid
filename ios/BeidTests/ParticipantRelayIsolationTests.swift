// Copyright (c) 2024-2026 Levarac Foundation
// SPDX-License-Identifier: MIT

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
    let sources = try Self.scenarioSources()
    // Naming the files the walk must find, so a broken path cannot pass by
    // checking nothing. The list is a floor, not a ceiling: new demo sources
    // are picked up without touching this test, which is the whole point of
    // walking rather than listing.
    for expected in ["Beid/Models/DemoScenario.swift", "Beid/Models/DemoEvent.swift"] {
      XCTAssertTrue(
        sources.contains(expected),
        "the demo-source walk did not find \(expected); found \(sources)"
      )
    }

    try assertSources(sources, avoid: Self.discoverySeedingAndRelayArming, role: "scenario")
  }

  private func assertSources(
    _ relativePaths: [String],
    avoid forbidden: [String],
    role: String
  ) throws {
    for relativePath in relativePaths {
      let text = try String(contentsOf: Self.appSource(relativePath), encoding: .utf8)

      for name in forbidden {
        XCTAssertFalse(
          text.contains(name),
          "\(relativePath) references \(name), which a \(role) source must not reach into"
        )
      }
    }
  }

  /// App source as it sits inside the test bundle.
  ///
  /// `ios/project.yml` copies the `Beid` tree in as a folder reference, which
  /// is the only reachable copy at test time. An earlier version read
  /// `#filePath` and walked up to the checkout; that works on a machine that
  /// still has the checkout mounted where the file was compiled, and fails on
  /// Xcode Cloud, which runs the built bundle somewhere else entirely. One
  /// mechanism rather than a fallback: a fallback would have hidden the same
  /// failure by silently checking a different copy, or none.
  private static func appSource(_ relativePath: String) -> URL {
    guard let resources = Bundle(for: ParticipantRelayIsolationTests.self).resourceURL else {
      preconditionFailure("the test bundle has no resource directory")
    }
    return resources.appendingPathComponent(relativePath)
  }

  private static let relaySources = [
    "Beid/Sensing/ParticipantRelayVerifier.swift"
  ]

  /// Every demo or scenario source, found by walking the app rather than
  /// listed by hand, mirroring how Android checks its whole `scenario`
  /// package. A hand-written list would have covered the one file someone
  /// thought of, and the demo surface is spread across several: a new
  /// `DemoSomething.swift` is exactly the file most likely to reach for a
  /// discovery seed to look convincing, and exactly the one a fixed list
  /// would miss.
  private static func scenarioSources() throws -> [String] {
    let root = appSource("Beid")
    let enumerator = FileManager.default.enumerator(
      at: root,
      includingPropertiesForKeys: nil
    )
    var found: [String] = []
    while let url = enumerator?.nextObject() as? URL {
      guard url.pathExtension == "swift" else { continue }
      let name = url.deletingPathExtension().lastPathComponent
      guard name.localizedCaseInsensitiveContains("demo")
        || name.localizedCaseInsensitiveContains("scenario")
      else { continue }
      // Reported relative to the bundle root, so a failure names the file the
      // way the repository does.
      let relative = url.path.replacingOccurrences(
        of: root.deletingLastPathComponent().path + "/",
        with: ""
      )
      found.append(relative)
    }
    return found.sorted()
  }

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
