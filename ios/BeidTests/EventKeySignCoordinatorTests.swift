// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import BarnardCore
import CryptoKit
import XCTest
@testable import Beid

/// The golden vector is the one mizar's contract and evaluator test against
/// (shared `EventKeySignRequestTest`). It was produced with `@noble/curves`,
/// so signing it here with Barnard and getting the same bytes back shows the
/// two RFC 6979 low-S implementations agree end to end.
@MainActor
final class EventKeySignCoordinatorTests: XCTestCase {
  // TEST KEY ONLY: SHA256("beid/event-key-sign/v1 golden vector key").
  private static let testPrivateKeyHex = "289dff4932755a4e636361c4f2a5264e5bde7cde6d6a5a9c81bf201864d7b971"
  private static let testEventKeyHex = "02157f569f4ba8298dc31bf69aaac9efc75c16f9f8fb1630cf06443610e6e26581"
  private static let eventIdHex = "996ab4d7cd0785199b715e6ff004f41ef740ead3b3363602ce1cb14b812d1f94"
  private static let claimBody =
    "0000000000000000000000000000000000000000000000000000000000aa36a7"
    + "5fbdb2315678afecb367f032d93f642f64180aa3"
    + "70997970c51812dc3a010c7d01b50e0d17dc79c8"
  private static let claimLink = URL(string:
    "beid://event-key-sign?v=1&p=02&e=\(eventIdHex)&b=\(claimBody)&st=state_1&k=\(testEventKeyHex)")!
  private static let personhoodLink = URL(string:
    "beid://event-key-sign?v=1&p=01&e=\(eventIdHex)&b=\(String(repeating: "a1", count: 32))&st=state_2")!

  private static let callbacks = EventKeySignCoordinator.Callbacks(
    personhoodBinding: URL(string: "https://alcor.example.test/bind/callback"),
    claim: URL(string: "https://mizar.example.test/claim/callback")
  )

  private var opened: [URL] = []
  private var signer: GoldenKeySigner!

  override func setUp() {
    super.setUp()
    opened = []
    signer = GoldenKeySigner(privateKey: Self.bytes(Self.testPrivateKeyHex), publicKey: Self.bytes(Self.testEventKeyHex))
  }

  private func makeCoordinator(
    recordedEventIdHex: String? = eventIdHex,
    callbacks: EventKeySignCoordinator.Callbacks = callbacks
  ) -> EventKeySignCoordinator {
    let signer = self.signer!
    return EventKeySignCoordinator(
      resolveEvent: { requested in
        requested == recordedEventIdHex ? ("golden-event-code", "Golden Event") : nil
      },
      cryptography: { signer },
      callbacks: callbacks,
      openURL: { [weak self] url in self?.opened.append(url) }
    )
  }

  func testClaimReturnsTheGoldenSignatureToTheClaimCallbackOnly() {
    let coordinator = makeCoordinator()

    XCTAssertTrue(coordinator.handle(url: Self.claimLink))
    let pending = try? XCTUnwrap(coordinator.pending)
    XCTAssertEqual(pending?.eventTitle, "Golden Event")
    XCTAssertEqual(pending?.callbackHost, "mizar.example.test")
    XCTAssertEqual(
      pending?.purpose,
      .claim(
        chainId: "11155111",
        contract: "0x5fbdb2315678afecb367f032d93f642f64180aa3",
        recipient: "0x70997970c51812dc3a010c7d01b50e0d17dc79c8"
      )
    )
    XCTAssertTrue(opened.isEmpty, "nothing may leave the app before the participant confirms")

    coordinator.approve()

    XCTAssertNil(coordinator.pending)
    XCTAssertNil(coordinator.failure)
    XCTAssertEqual(opened.map(\.absoluteString), [
      "https://mizar.example.test/claim/callback#v=1&st=state_1"
        + "&sig=0x3f710e304a2fce9324cfd5540b90966bbc8cdd1969d4461e51ae658404571dcb"
        + "73b3866bb6649866d99b2f467f1e768c5144ce5e7126c1deb86c77ffb6dcf7581b"
        + "&k=0x02157f569f4ba8298dc31bf69aaac9efc75c16f9f8fb1630cf06443610e6e26581"
        + "&a=0x05e8bdca0d0523483bc1a2f490a2f03cb00b776d",
    ])
    XCTAssertEqual(signer.signedEventCodes, ["golden-event-code"])
  }

  func testPersonhoodSignsTheGoldenMessageWithTheRecordedEventsKey() {
    let coordinator = makeCoordinator()

    XCTAssertTrue(coordinator.handle(url: Self.personhoodLink))
    coordinator.approve()

    let fragment = opened.first.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.fragment }
    XCTAssertEqual(opened.first?.host, "alcor.example.test")
    XCTAssertTrue(fragment?.contains(
      "sig=0xb590702126af9e2a06084467616635796968aa89dace7659880c55c471f5bf29"
        + "3443f426bfd0fd8528bcf518f062580b9b83015a722bde22536d8f687c63e6421b"
    ) == true, fragment ?? "no callback")
  }

  func testDeclineReturnsOnlyTheStateAndSignsNothing() {
    let coordinator = makeCoordinator()

    XCTAssertTrue(coordinator.handle(url: Self.claimLink))
    coordinator.decline()

    XCTAssertEqual(opened.map(\.absoluteString), [
      "https://mizar.example.test/claim/callback#v=1&st=state_1&err=cancelled",
    ])
    XCTAssertTrue(signer.signedEventCodes.isEmpty)
  }

  func testAnEventThisPhoneNeverRecordedIsRefusedWithoutDerivingAKey() {
    let coordinator = makeCoordinator(recordedEventIdHex: nil)

    XCTAssertTrue(coordinator.handle(url: Self.claimLink))

    XCTAssertNil(coordinator.pending)
    XCTAssertEqual(coordinator.failure, .eventNotOnThisPhone)
    XCTAssertTrue(signer.publicKeyRequests.isEmpty)
    XCTAssertTrue(opened.isEmpty)
  }

  func testAnExpectedKeyThatIsNotThisPhonesIsRefused() {
    let coordinator = makeCoordinator()
    let otherKey = "03" + String(repeating: "11", count: 32)
    let link = URL(string: Self.claimLink.absoluteString.replacingOccurrences(of: Self.testEventKeyHex, with: otherKey))!

    XCTAssertTrue(coordinator.handle(url: link))

    XCTAssertNil(coordinator.pending)
    XCTAssertEqual(coordinator.failure, .keyMismatch)
  }

  func testOtherBeidLinksAreLeftForTheWalletConnector() {
    let coordinator = makeCoordinator()

    XCTAssertFalse(coordinator.handle(url: URL(string: "beid://mmsdk?message=abc")!))
    XCTAssertFalse(coordinator.handle(url: URL(string: "https://event-key-sign/?v=1")!))
    XCTAssertNil(coordinator.pending)
    XCTAssertNil(coordinator.failure)
  }

  func testAMalformedSigningLinkIsConsumedButShowsNothing() {
    let coordinator = makeCoordinator()

    XCTAssertTrue(coordinator.handle(url: URL(string: "beid://event-key-sign?v=1&p=02&cb=evil")!))
    XCTAssertNil(coordinator.pending)
    XCTAssertTrue(opened.isEmpty)
  }

  func testASecondLinkCannotReplaceTheOneBeingRead() {
    let coordinator = makeCoordinator()

    XCTAssertTrue(coordinator.handle(url: Self.claimLink))
    let first = coordinator.pending?.id
    XCTAssertTrue(coordinator.handle(url: Self.personhoodLink))

    XCTAssertEqual(coordinator.pending?.id, first)
  }

  func testAPurposeWithoutAValidCallbackIsRefused() {
    let coordinator = makeCoordinator(callbacks: .init(personhoodBinding: Self.callbacks.personhoodBinding, claim: nil))

    XCTAssertTrue(coordinator.handle(url: Self.claimLink))

    XCTAssertNil(coordinator.pending)
    XCTAssertEqual(coordinator.failure, .unavailable)
  }

  func testASignatureThatDoesNotRecoverToTheEventKeyIsNeverReturned() {
    signer.corruptSignatures = true
    let coordinator = makeCoordinator()

    XCTAssertTrue(coordinator.handle(url: Self.claimLink))
    coordinator.approve()

    XCTAssertTrue(opened.isEmpty)
    XCTAssertEqual(coordinator.failure, .unavailable)
  }

  func testCallbacksMustBePlainHttps() {
    typealias Callbacks = EventKeySignCoordinator.Callbacks
    XCTAssertNotNil(Callbacks.validated("https://mizar.example.test/claim/callback"))
    XCTAssertNil(Callbacks.validated("http://mizar.example.test/claim/callback"))
    XCTAssertNil(Callbacks.validated("beid://event-key-sign"))
    XCTAssertNil(Callbacks.validated("https://user@mizar.example.test/cb"))
    XCTAssertNil(Callbacks.validated("https://mizar.example.test/cb#already"))
    XCTAssertNil(Callbacks.validated("https:///cb"))
    XCTAssertNil(Callbacks.validated(""))
    XCTAssertNil(Callbacks.validated(nil))
  }

  func testRecipientIsShownInFullInGroupsOfFour() {
    XCTAssertEqual(
      EventKeySignSheet.grouped("0x70997970c51812dc3a010c7d01b50e0d17dc79c8"),
      "0x7099 7970 C518 12DC 3A01 0C7D 01B5 0E0D 17DC 79C8"
    )
  }

  private static func bytes(_ hex: String) -> [UInt8] {
    stride(from: 0, to: hex.count, by: 2).map { offset in
      let start = hex.index(hex.startIndex, offsetBy: offset)
      return UInt8(hex[start..<hex.index(start, offsetBy: 2)], radix: 16)!
    }
  }
}

/// Signs with a fixed test key through Barnard's own primitive, exactly as
/// `BarnardIdentity.sign(eventCode:bytes:)` does with a derived key.
private final class GoldenKeySigner: SensingCryptography {
  let privateKey: [UInt8]
  let publicKey: [UInt8]
  var corruptSignatures = false
  private(set) var signedEventCodes: [String] = []
  private(set) var publicKeyRequests: [String] = []

  init(privateKey: [UInt8], publicKey: [UInt8]) {
    self.privateKey = privateKey
    self.publicKey = publicKey
  }

  func eventSigningPublicKey(eventCode: String) -> Data {
    publicKeyRequests.append(eventCode)
    return Data(publicKey)
  }

  func ownerPublicKey() throws -> Data { Data() }

  func signWindowReport(eventCode: String, bytes: Data) -> SensingRecoverableSignature {
    signedEventCodes.append(eventCode)
    let digest = [UInt8](SHA256.hash(data: bytes))
    let signature = SensingRecoverableSignature(
      barnardCore: BarnardCoreSigning.signRecoverable(privateKey: privateKey, messageHash32: digest)
    )
    guard corruptSignatures else { return signature }
    var s = signature.s
    s[s.count - 1] ^= 0x01
    return SensingRecoverableSignature(r: signature.r, s: s, v: signature.v)
  }

  func signSelfProof(eventIdHash: Data, eventSigningPublicKey: Data, eninStart: UInt64, eninEnd: UInt64) throws
    -> SensingRecoverableSignature? { nil }

  func signWalletAcknowledgement(walletAddress: Data, walletSignature: Data) throws
    -> SensingRecoverableSignature? { nil }
}
