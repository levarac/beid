// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import BeidSharedKit
import XCTest
@testable import Beid

/// beid#597 — the venue screen's single input: a link whose fragment carries the
/// handoff, pasted or scanned.
///
/// These tests are about the carrier, not about verification. Verification is
/// unchanged and is covered where it already was; what is new is that the handoff
/// arrives in a fragment instead of from a second URL, and that a link the operator
/// mistypes must be reported as a bad link rather than as a rejected bundle.
@MainActor
final class VenueLinkSupplyTests: XCTestCase {
  private var ports: ScriptedVenuePorts!
  private var acquisition: StubVenueArtifactAcquisition!
  private var store: VenuePublicArtifactStore!
  private var fixture: VenueServingContractFixture!

  private static let bundleUrl = "https://artifacts.example/artifacts/venue-bundles/abc"

  override func setUp() async throws {
    try await super.setUp()
    ports = ScriptedVenuePorts()
    acquisition = StubVenueArtifactAcquisition()
    store = makeTemporaryArtifactStore()
    fixture = try VenueServingContractFixture.load()
  }

  private func makeViewModel() -> VenueSignedServingViewModel {
    VenueSignedServingViewModel(
      verifier: ports,
      broadcasting: ports,
      acquisition: acquisition,
      store: store,
      clock: { .available(unixSeconds: VenueServingContractFixture.currentUnixSeconds) },
      expiry: FakeVenueExpiryScheduler()
    )
  }

  // MARK: - Fragment decode

  func testLinkFragmentSuppliesTheHandoffBytesItCarriesAndFetchesTheBundleItNames() async throws {
    let handoffBytes = Self.handoffWithBundleUrl(fixture.artifact.handoffBytes, url: Self.bundleUrl)
    let link = Self.link(base: Self.bundleUrl, handoff: handoffBytes)
    let expected = VenuePublicArtifact(bundleBytes: fixture.artifact.bundleBytes, handoffBytes: handoffBytes)
    ports.importReplies = [.immediate(.imported(VenueServingContractTestFactory.imported(
      identity: fixture.identity, publicArtifact: expected)))]
    ports.evaluationReplies = [.immediate(.blocked(try XCTUnwrap(VenueServingRejection(reason: .expired))))]
    acquisition.replies = [.artifact(expected)]

    let viewModel = makeViewModel()
    await viewModel.supply(link: link)

    // The bundle is fetched from the handoff's own bundleUrl. No second URL is
    // typed, and no handoff is fetched at all — that is the whole point of the
    // fragment carrier.
    XCTAssertEqual(acquisition.requestedSources.count, 1)
    XCTAssertEqual(acquisition.requestedSources.first?.bundle.absoluteString, Self.bundleUrl)
    XCTAssertNil(acquisition.requestedSources.first?.handoff)
    // The verifier receives the bytes the LINK carried, byte for byte. If these
    // ever diverged, every field and digest comparison downstream would be run
    // against something the operator was not handed.
    XCTAssertTrue(ports.calls.contains(
      .importing(id: 0, bundle: fixture.artifact.bundleBytes, handoff: handoffBytes)))
    XCTAssertEqual(
      viewModel.linkEventIdHex,
      VenueServingContractFixture.eventIdHex,
      "the screen must show the event the link itself named"
    )
  }

  func testAPastedLinkSurvivesTheWhitespaceAClipboardAndAScannerAdd() async throws {
    let handoffBytes = Self.handoffWithBundleUrl(fixture.artifact.handoffBytes, url: Self.bundleUrl)
    let link = Self.link(base: Self.bundleUrl, handoff: handoffBytes)
    ports.importReplies = [.immediate(.rejected(.handoffMismatch))]
    acquisition.replies = [.artifact(
      VenuePublicArtifact(bundleBytes: fixture.artifact.bundleBytes, handoffBytes: handoffBytes))]

    let viewModel = makeViewModel()
    await viewModel.supply(link: "\n  \(link)  \n")

    // It reached the verifier at all: a link refused for its surrounding
    // whitespace would have set `linkFailure` and fetched nothing.
    XCTAssertEqual(viewModel.status, .importRejected(.handoffMismatch))
  }

  // MARK: - Links that are not links

  func testAMalformedLinkIsReportedAsABadLinkAndNeverAsARejectedBundle() async {
    let viewModel = makeViewModel()
    for malformed in [
      "",
      "not a link",
      "https://artifacts.example/bundle",            // no fragment at all
      "https://artifacts.example/bundle#not-base64!", // fragment is not base64url
      "#pgEBAlgg",                                    // fragment without an absolute URI
    ] {
      await viewModel.supply(link: malformed)
      XCTAssertEqual(viewModel.linkFailure, .malformedLink, malformed)
      XCTAssertNil(viewModel.linkEventIdHex, malformed)
    }
    // Nothing was fetched and nothing was verified, so no verdict about a bundle
    // may have been produced.
    XCTAssertEqual(acquisition.requestedSources.count, 0)
    XCTAssertTrue(ports.calls.isEmpty)
  }

  func testAFragmentThatIsValidBase64UrlButNotAHandoffIsStillABadLink() async {
    let viewModel = makeViewModel()
    await viewModel.supply(link: "https://artifacts.example/bundle#" + Self.base64url(Data([0x01, 0x02, 0x03])))
    XCTAssertEqual(viewModel.linkFailure, .malformedLink)
    XCTAssertEqual(acquisition.requestedSources.count, 0)
  }

  // MARK: - A handoff with no bundle to fetch

  func testAHandoffWithoutABundleUrlNamesItsEventAndThenSaysThereIsNothingToFetch() async {
    // The six-field form. `venue-bundle.md` makes label 7 optional, so this is a
    // valid handoff — it just cannot drive this screen, which has no second field
    // left to type a bundle URL into.
    let link = Self.link(base: "https://venue.example/join", handoff: fixture.artifact.handoffBytes)
    let viewModel = makeViewModel()
    await viewModel.supply(link: link)

    XCTAssertEqual(viewModel.linkFailure, .missingBundleUrl)
    // The event id is still shown: the operator learns which event they were
    // handed, which is what tells them whether the link is merely incomplete or
    // outright the wrong one.
    XCTAssertEqual(viewModel.linkEventIdHex, VenueServingContractFixture.eventIdHex)
    XCTAssertEqual(acquisition.requestedSources.count, 0)
  }

  func testABundleUrlThisAppCannotFetchIsRefusedBeforeAnyRequest() async {
    // The shared decoder checks URI syntax only, and says so: which transports are
    // permitted is a native policy. Both of these are well-formed absolute URIs.
    let viewModel = makeViewModel()
    for url in [
      "ftp://artifacts.example/b",
      // `file:` is the one that matters. Acquisition can read it, and the old
      // two-URL form used that for a bundle the operator had put on the device.
      // Here the value comes from whoever wrote the link, so honouring it would
      // let a handed-over link name a path on this device.
      "file:///etc/passwd",
      "http://artifacts.example/b",
    ] {
      let handoffBytes = Self.handoffWithBundleUrl(fixture.artifact.handoffBytes, url: url)
      await viewModel.supply(link: Self.link(base: "https://venue.example/join", handoff: handoffBytes))
      XCTAssertEqual(viewModel.linkFailure, .unsupportedBundleUrl, url)
      XCTAssertEqual(acquisition.requestedSources.count, 0, url)
    }
  }

  // MARK: - A bad paste must not take a live event off the air

  func testARefusedLinkLeavesAServingDeviceServing() async throws {
    let handoffBytes = Self.handoffWithBundleUrl(fixture.artifact.handoffBytes, url: Self.bundleUrl)
    let artifact = VenuePublicArtifact(bundleBytes: fixture.artifact.bundleBytes, handoffBytes: handoffBytes)
    ports.importReplies = [.immediate(.imported(VenueServingContractTestFactory.imported(
      identity: fixture.identity, publicArtifact: artifact)))]
    ports.evaluationReplies = [.immediate(.permitted(fixture.permit()))]
    acquisition.replies = [.artifact(artifact)]

    let viewModel = makeViewModel()
    await viewModel.supply(link: Self.link(base: Self.bundleUrl, handoff: handoffBytes))
    guard case .serving = viewModel.status else {
      return XCTFail("the fixture must reach serving before this test means anything: \(viewModel.status)")
    }
    let callsWhileServing = ports.calls

    // The venue is running. Someone fumbles a paste into the field and taps Supply.
    await viewModel.supply(link: "https://artifacts.example/bundle#not-base64!")

    XCTAssertEqual(viewModel.linkFailure, .malformedLink)
    // Still on the air. Routing a refused link through `status` would have
    // cleared the radio on the way — the operator would have lost the event to a
    // typo, which is the accident this issue removes rather than relocates.
    guard case .serving = viewModel.status else {
      return XCTFail("a refused link must not change what is being served: \(viewModel.status)")
    }
    XCTAssertEqual(ports.calls, callsWhileServing, "a refused link must reach no port at all")
    XCTAssertFalse(ports.calls.contains(.clearing))
    XCTAssertEqual(viewModel.servingEventIdHex, VenueServingContractFixture.eventIdHex)
  }

  func testEveryLinkFailureIsReachableFromSomeLink() async {
    let viewModel = makeViewModel()
    var observed: Set<VenueLinkFailure> = []
    for link in [
      "not a link",
      Self.link(base: "https://venue.example/join", handoff: fixture.artifact.handoffBytes),
      Self.link(
        base: "https://venue.example/join",
        handoff: Self.handoffWithBundleUrl(fixture.artifact.handoffBytes, url: "ftp://artifacts.example/b")),
    ] {
      await viewModel.supply(link: link)
      if let failure = viewModel.linkFailure { observed.insert(failure) }
    }
    // Observed, never prefilled from allCases: the same rule
    // `assertVenueOutcomeCoverage` applies to the other venue enums. A case added
    // here without a link that produces it fails this.
    XCTAssertEqual(observed, Set(VenueLinkFailure.allCases))
  }

  // MARK: - Fetching the pack the link named

  func testEveryAcquisitionRefusalOnTheLinkPathIsSaidAsItself() async {
    let handoffBytes = Self.handoffWithBundleUrl(fixture.artifact.handoffBytes, url: Self.bundleUrl)
    let link = Self.link(base: Self.bundleUrl, handoff: handoffBytes)
    // allCases, not a list: a refusal added later is covered here without anyone
    // remembering to come back. `.timedOut` arrived that way (beid#597 review).
    for failure in VenueAcquisitionFailure.allCases {
      ports = ScriptedVenuePorts()
      acquisition = StubVenueArtifactAcquisition()
      store = makeTemporaryArtifactStore()
      let viewModel = makeViewModel()
      acquisition.replies = [.failure(failure)]

      await viewModel.supply(link: link)

      XCTAssertEqual(viewModel.status, .acquisitionFailed(failure), failure.rawValue)
      // The link was fine. Saying it was not would send the operator to retype a
      // link that is not the problem.
      XCTAssertNil(viewModel.linkFailure, failure.rawValue)
      XCTAssertEqual(viewModel.linkEventIdHex, VenueServingContractFixture.eventIdHex, failure.rawValue)
      XCTAssertTrue(ports.calls.isEmpty, failure.rawValue)
    }
  }

  // MARK: - What is stored

  func testTheStoredSourceNamesTheBundleHostAndNeverClaimsAHostForTheHandoff() async throws {
    let handoffBytes = Self.handoffWithBundleUrl(fixture.artifact.handoffBytes, url: Self.bundleUrl)
    let artifact = VenuePublicArtifact(bundleBytes: fixture.artifact.bundleBytes, handoffBytes: handoffBytes)
    ports.importReplies = [.immediate(.imported(VenueServingContractTestFactory.imported(
      identity: fixture.identity, publicArtifact: artifact)))]
    ports.evaluationReplies = [.immediate(.blocked(try XCTUnwrap(VenueServingRejection(reason: .expired))))]
    acquisition.replies = [.artifact(artifact)]

    let viewModel = makeViewModel()
    await viewModel.supply(link: Self.link(base: Self.bundleUrl, handoff: handoffBytes))

    let record = try XCTUnwrap(store.record)
    XCTAssertEqual(record.handoffBytes, handoffBytes)
    XCTAssertEqual(record.sourceDescription, "link, bundle from artifacts.example")
  }

  func testStopClearsWhatTheScreenSaysAboutTheLastLink() async {
    let viewModel = makeViewModel()
    await viewModel.supply(
      link: Self.link(base: "https://venue.example/join", handoff: fixture.artifact.handoffBytes))
    XCTAssertEqual(viewModel.linkFailure, .missingBundleUrl)
    XCTAssertNotNil(viewModel.linkEventIdHex)

    viewModel.stop()

    // Both belong to a link that is no longer being acted on. Leaving them would
    // show an event id and a complaint beside an empty screen.
    XCTAssertNil(viewModel.linkEventIdHex)
    XCTAssertNil(viewModel.linkFailure)
    XCTAssertEqual(viewModel.status, .idle)
  }

  func testLoadingTheStoredPackClearsWhatTheLastLinkLeftBehind() async throws {
    let handoffBytes = Self.handoffWithBundleUrl(fixture.artifact.handoffBytes, url: Self.bundleUrl)
    let artifact = VenuePublicArtifact(bundleBytes: fixture.artifact.bundleBytes, handoffBytes: handoffBytes)
    ports.importReplies = [
      .immediate(.imported(VenueServingContractTestFactory.imported(
        identity: fixture.identity, publicArtifact: artifact))),
      .immediate(.imported(VenueServingContractTestFactory.imported(
        identity: fixture.identity, publicArtifact: artifact))),
    ]
    ports.evaluationReplies = [
      .immediate(.blocked(try XCTUnwrap(VenueServingRejection(reason: .expired)))),
      .immediate(.blocked(try XCTUnwrap(VenueServingRejection(reason: .expired)))),
    ]
    acquisition.replies = [.artifact(artifact)]

    let viewModel = makeViewModel()
    await viewModel.supply(link: Self.link(base: Self.bundleUrl, handoff: handoffBytes))
    XCTAssertNotNil(store.record)
    // Then a bad paste, which leaves a complaint and an event id on the screen.
    await viewModel.supply(link: "https://artifacts.example/bundle#not-base64!")
    XCTAssertEqual(viewModel.linkFailure, .malformedLink)

    await viewModel.restoreFromStorage()

    // Loading the stored pack is a different act on a different pack. Carrying
    // the last link's complaint into it would have the screen arguing about a
    // link that is no longer the subject.
    XCTAssertNil(viewModel.linkFailure)
    XCTAssertNil(viewModel.linkEventIdHex)
  }

  // MARK: - Fixtures

  /// base64url, unpadded — the form `venueHandoffLink` on the operator side emits.
  private static func base64url(_ bytes: Data) -> String {
    bytes.base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }

  private static func link(base: String, handoff: Data) -> String {
    base + "#" + base64url(handoff)
  }

  /// Appends label 7 to the fixture's six-field handoff.
  ///
  /// The repository's venue fixtures are all the six-field form, and this screen's
  /// whole input now depends on the seventh. Rather than commit a second binary
  /// fixture, the field is appended here in deterministic CBOR — and the shared
  /// decoder is what proves the result well-formed, because every test that uses
  /// this would fail at `.malformedLink` if the encoding were wrong.
  private static func handoffWithBundleUrl(_ sixFieldHandoff: Data, url: String) -> Data {
    var bytes = sixFieldHandoff
    XCTAssertEqual(bytes.first, 0xA6, "fixture is expected to be the six-field handoff")
    bytes[bytes.startIndex] = 0xA7
    bytes.append(0x07)
    let utf8 = Array(url.utf8)
    XCTAssertTrue(utf8.count < 256, "the short-text encoding below covers this fixture only")
    if utf8.count < 24 {
      bytes.append(UInt8(0x60 + utf8.count))
    } else {
      bytes.append(0x78)
      bytes.append(UInt8(utf8.count))
    }
    bytes.append(contentsOf: utf8)
    return bytes
  }
}
