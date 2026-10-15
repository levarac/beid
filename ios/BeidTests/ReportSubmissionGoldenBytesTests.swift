// Copyright (c) 2024-2026 Levarac Foundation
// SPDX-License-Identifier: MIT

import BeidSharedKit
import Foundation
import XCTest
@testable import Beid

/// The three byte strings one fixed pending capture turns into on its way to
/// the operator.
struct ReportSubmissionGoldenBytes: Equatable {
  /// What `SensingCryptography.signWindowReport` was asked to sign.
  let signatureInputHex: String
  /// `ReportSubmissionRecord.signedObservationHex` as persisted.
  let signedObservationHex: String
  /// The exact POST body the operator received.
  let postBodyHex: String
}

/// beid#701 T3's fixed scenario, kept apart from anything beid#701 added so
/// this file compiles on the commit before it. It uses only production API
/// that existed at `62531fe` plus `Support/ReportSubmissionOperatorTestSupport.swift`.
///
/// Every input to the Observation is fixed here: the window id, ENIN, the
/// RPIDs, the commitment, `finalizedAt`, the Event Definition, and the
/// signer, whose nonce is fixed (`TestSecp256k1`). The operator endpoint
/// changes per run (a loopback port) but is not part of any of the three
/// byte strings.
@MainActor
enum ReportSubmissionGoldenScenario {
  static let captureId = UUID(uuidString: "70100000-0000-4000-8000-000000000701")!
  static let eventCode = "BEID701-GOLDEN-EVENT"
  static let eventIdHex = String(repeating: "11", count: 32)
  static let definitionDigestHex = String(repeating: "22", count: 32)
  static let enin = 7
  static let finalizedAt: TimeInterval = 1_774_487_000
  static let createdAt = Date(timeIntervalSince1970: 1_774_487_000)
  static let reporterRpid = "01" + String(repeating: "aa", count: 16)
  static let peerRpids = (1...3).map { "01" + String(format: "%032x", $0) }
  static let participantCommitment = Data(repeating: 0x5c, count: 32)

  private static let receiptKeyHex = "02c6047f9441ed7d6d3045406e95c07cd85c778e4b8cef3ca7abac09b95c709ee5"
  private static let receiptPrivateKey = [UInt8](repeating: 0, count: 31) + [2]

  // MARK: Golden values
  //
  // Recorded by running `testRuntimeBytesEqualGoldenRecordedBeforeBeid701`
  // on UNMODIFIED `62531fe` production code (thegreeting/beid, the base of
  // `work/issue-701-report-link`). Values measured on any later commit pin
  // that commit's behaviour, not the pre-#701 behaviour, and must not be
  // pasted here. Replace each marker with the hex the failure message
  // prints, and record the recording host and date beside it.
  static let unrecordedMarker = "UNRECORDED-RUN-ON-62531fe"
  // Recorded by PM a-20260925-125 on 2026-09-27 on host ko-mini2 (iOS 26.5 simulator),
  // on UNMODIFIED production code at 62531fe with only this test file and the moved
  // test-support types added; two runs produced byte-identical values.
  static let goldenSignatureInputHex =
    "846a5369676e6174757265315839a301382e0378286170706c69636174696f6e2f766e642e6c6576617261632e6f62736572766174696f6e2b63626f7204485ef036280edf16eb40590117a801010250701000000000400080000000000007010378196c6576617261632e6d757475616c2d73656e73696e672f763104582011111111111111111111111111111111111111111111111111111111111111110558210279be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798061a69c485d8075101aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa085883a501582022222222222222222222222222222222222222222222222222222222222222220207038351010000000000000000000000000000000151010000000000000000000000000000000251010000000000000000000000000000000304f60558205c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c"
  static let goldenSignedObservationHex =
    "d2845839a301382e0378286170706c69636174696f6e2f766e642e6c6576617261632e6f62736572766174696f6e2b63626f7204485ef036280edf16eba0590117a801010250701000000000400080000000000007010378196c6576617261632e6d757475616c2d73656e73696e672f763104582011111111111111111111111111111111111111111111111111111111111111110558210279be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798061a69c485d8075101aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa085883a501582022222222222222222222222222222222222222222222222222222222222222220207038351010000000000000000000000000000000151010000000000000000000000000000000251010000000000000000000000000000000304f60558205c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c584079be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f817983f94644c4e0af36c9392426110fc71f22a00398b1736917ce6f9d71ae29e904f"
  static let goldenPostBodyHex =
    "d2845839a301382e0378286170706c69636174696f6e2f766e642e6c6576617261632e6f62736572766174696f6e2b63626f7204485ef036280edf16eba0590117a801010250701000000000400080000000000007010378196c6576617261632e6d757475616c2d73656e73696e672f763104582011111111111111111111111111111111111111111111111111111111111111110558210279be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798061a69c485d8075101aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa085883a501582022222222222222222222222222222222222222222222222222222222222222220207038351010000000000000000000000000000000151010000000000000000000000000000000251010000000000000000000000000000000304f60558205c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c584079be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f817983f94644c4e0af36c9392426110fc71f22a00398b1736917ce6f9d71ae29e904f"

  static func assertMatchesGolden(
    _ actual: ReportSubmissionGoldenBytes,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    for (name, golden, measured) in [
      ("goldenSignatureInputHex", goldenSignatureInputHex, actual.signatureInputHex),
      ("goldenSignedObservationHex", goldenSignedObservationHex, actual.signedObservationHex),
      ("goldenPostBodyHex", goldenPostBodyHex, actual.postBodyHex)
    ] {
      guard golden != unrecordedMarker else {
        XCTFail(
          """
          GOLDEN NOT RECORDED: \(name) is still a placeholder, so this test \
          pins nothing. Record it by running this test on unmodified 62531fe \
          production code and pasting the value measured there. Value \
          measured on THIS build (use it only if this build is 62531fe): \
          \(measured)
          """,
          file: file,
          line: line
        )
        continue
      }
      XCTAssertEqual(
        measured,
        golden,
        """
        \(name) changed. The signed and sent bytes for a fixed capture must \
        be identical to what 62531fe produced (beid#701: do not change what \
        is sent or signed).
        """,
        file: file,
        line: line
      )
    }
  }

  /// Seeds the fixed capture as a pending capture in `directory`, lets a real
  /// `ReportSubmissionRuntime` prepare, sign and POST it to a loopback
  /// operator, and returns the bytes it produced.
  static func run(in directory: URL) async throws -> ReportSubmissionGoldenBytes {
    let server = try StubOperatorServer(
      eventId: try XCTUnwrap(goldenData(fromHex: eventIdHex)),
      signingPrivateKey: receiptPrivateKey,
      signingPublicKey: try XCTUnwrap(goldenData(fromHex: receiptKeyHex))
    )
    defer { server.stop() }
    let endpoint = try await server.start()
    let fileURL = directory.appendingPathComponent("report-submissions.json")

    try ReportSubmissionStore(fileURL: fileURL).addPendingCapture(
      ReportSubmissionCapture(
        id: captureId,
        eventCode: eventCode,
        eventIdHex: eventIdHex,
        enin: enin,
        peerRpids: peerRpids,
        reporterRpid: reporterRpid,
        participantCommitment: participantCommitment,
        finalizedAt: finalizedAt,
        createdAt: createdAt
      )
    )

    let configuration = try XCTUnwrap(
      ExportedKotlinPackages.org.levarac.parallax.submission
        .createSubmissionOperatorConfiguration(
          endpoint: endpoint.absoluteString,
          receiptPublicKeyHex: receiptKeyHex,
          eventIdHex: eventIdHex,
          eventDefinitionDigestHex: definitionDigestHex,
          validFrom: nil,
          validUntil: nil,
          allowInsecureLoopbackForTests: true
        )
    )
    let cryptography = SignatureInputRecordingCryptography(wrapping: TestSensingCryptography())
    let runtime = try XCTUnwrap(ReportSubmissionRuntime.makeIfEnabled(
      bundle: try makeSubmissionEnabledBundle(in: directory),
      eventSigningCryptography: cryptography,
      definitionProvider: StaticEventDefinitionContextProvider(configuration: configuration),
      fileURL: fileURL,
      allowInsecureLoopbackForTests: true
    ))

    runtime.submitPending()
    try await server.waitFor(postCount: 1)
    try await waitForAcceptedRecord(at: fileURL)
    // The runtime's own callbacks hold it weakly; keep it alive until its
    // receipt write has landed.
    withExtendedLifetime(runtime) {}

    let record = try XCTUnwrap(ReportSubmissionStore(fileURL: fileURL).records.first)
    XCTAssertEqual(record.id, captureId)
    XCTAssertEqual(cryptography.signatureInputs.count, 1, "exactly one Observation must be signed")
    XCTAssertEqual(server.postBodies.count, 1, "exactly one POST must be sent")
    let signatureInput = try XCTUnwrap(cryptography.signatureInputs.first)
    let postBody = try XCTUnwrap(server.postBodies.first)
    return ReportSubmissionGoldenBytes(
      signatureInputHex: goldenHex(signatureInput),
      signedObservationHex: record.signedObservationHex.lowercased(),
      postBodyHex: goldenHex(postBody)
    )
  }

  private static func waitForAcceptedRecord(at fileURL: URL) async throws {
    for _ in 0..<1_000 {
      if ReportSubmissionStore(fileURL: fileURL).records.first?.submissionState == .accepted {
        return
      }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    throw StubOperatorError.submissionStateTimedOut(expected: ReportSubmissionState.accepted.rawValue)
  }

  private static func makeSubmissionEnabledBundle(in directory: URL) throws -> Bundle {
    let bundleDirectory = directory.appendingPathComponent("submission-enabled.bundle", isDirectory: true)
    try FileManager.default.createDirectory(at: bundleDirectory, withIntermediateDirectories: true)
    let plist: [String: Any] = [
      "CFBundleIdentifier": "org.levarac.beid.tests.\(UUID().uuidString)",
      "CFBundlePackageType": "BNDL",
      "BeidReportSubmissionEnabled": "1"
    ]
    let plistData = try PropertyListSerialization.data(
      fromPropertyList: plist,
      format: .xml,
      options: 0
    )
    try plistData.write(to: bundleDirectory.appendingPathComponent("Info.plist"))
    return try XCTUnwrap(Bundle(url: bundleDirectory))
  }
}

/// Delegates to the fixed-nonce test signer and records each input it was
/// asked to sign.
final class SignatureInputRecordingCryptography: SensingCryptography {
  private let wrapped: any SensingCryptography
  private(set) var signatureInputs: [Data] = []

  init(wrapping wrapped: any SensingCryptography) {
    self.wrapped = wrapped
  }

  func eventSigningPublicKey(eventCode: String) -> Data {
    wrapped.eventSigningPublicKey(eventCode: eventCode)
  }

  func ownerPublicKey() throws -> Data {
    try wrapped.ownerPublicKey()
  }

  func signWindowReport(eventCode: String, bytes: Data) -> SensingRecoverableSignature {
    signatureInputs.append(bytes)
    return wrapped.signWindowReport(eventCode: eventCode, bytes: bytes)
  }

  func signSelfProof(
    eventIdHash: Data,
    eventSigningPublicKey: Data,
    eninStart: UInt64,
    eninEnd: UInt64
  ) throws -> SensingRecoverableSignature? {
    try wrapped.signSelfProof(
      eventIdHash: eventIdHash,
      eventSigningPublicKey: eventSigningPublicKey,
      eninStart: eninStart,
      eninEnd: eninEnd
    )
  }

  func signWalletAcknowledgement(
    walletAddress: Data,
    walletSignature: Data
  ) throws -> SensingRecoverableSignature? {
    try wrapped.signWalletAcknowledgement(
      walletAddress: walletAddress,
      walletSignature: walletSignature
    )
  }
}

func goldenHex(_ data: Data) -> String {
  data.map { String(format: "%02x", $0) }.joined()
}

func goldenData(fromHex hex: String) -> Data? {
  guard hex.count.isMultiple(of: 2) else { return nil }
  var bytes: [UInt8] = []
  bytes.reserveCapacity(hex.count / 2)
  var index = hex.startIndex
  while index < hex.endIndex {
    let next = hex.index(index, offsetBy: 2)
    guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
    bytes.append(byte)
    index = next
  }
  return Data(bytes)
}

/// beid#701 T3, the half that runs on `62531fe`: the bytes one fixed capture
/// becomes must equal the golden values recorded there.
@MainActor
final class ReportSubmissionGoldenBytesTests: XCTestCase {
  func testRuntimeBytesEqualGoldenRecordedBeforeBeid701() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("beid-report-submission-golden-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }

    let actual = try await ReportSubmissionGoldenScenario.run(in: directory)

    XCTAssertEqual(
      actual.postBodyHex,
      actual.signedObservationHex,
      "the POST body must be exactly the persisted signed Observation"
    )
    ReportSubmissionGoldenScenario.assertMatchesGolden(actual)
  }
}
