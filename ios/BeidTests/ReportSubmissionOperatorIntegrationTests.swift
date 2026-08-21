// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import BeidSharedKit
import Foundation
import XCTest
@testable import Beid

@MainActor
final class ReportSubmissionOperatorIntegrationTests: XCTestCase {
  func testRealSignedWindowGetsVerifiedReceiptFromReferenceOperator() async throws {
    let environment = ProcessInfo.processInfo.environment
    guard environment["BEID_RUN_OPERATOR_SUBMISSION_TEST"] == "1" else {
      throw XCTSkip("set BEID_RUN_OPERATOR_SUBMISSION_TEST=1 to run the local operator integration")
    }

    let endpoint = try requiredEnvironment("BEID_OPERATOR_SUBMISSION_ENDPOINT", from: environment)
    let receiptPublicKey = try requiredEnvironment("BEID_OPERATOR_RECEIPT_PUBLIC_KEY", from: environment)
    let eventId = try requiredEnvironment("BEID_EVENT_ID", from: environment)
    let definitionDigest = try requiredEnvironment("BEID_EVENT_DEFINITION_DIGEST", from: environment)
    let configuration = try XCTUnwrap(
      ExportedKotlinPackages.org.levarac.parallax.submission
        .createSubmissionOperatorConfiguration(
          endpoint: endpoint,
          receiptPublicKeyHex: receiptPublicKey,
          eventIdHex: eventId,
          eventDefinitionDigestHex: definitionDigest,
          validFrom: nil,
          validUntil: nil,
          allowInsecureLoopbackForTests: true
        )
    )

    let eventCode = "operator-integration-\(UUID().uuidString)"
    let cryptography = BarnardSensingCryptography()
    let reporterRpid = "01" + String(repeating: "aa", count: 16)
    let observedRpid = "01" + String(repeating: "bb", count: 16)
    let evidence = try XCTUnwrap(
      ExportedKotlinPackages.org.levarac.parallax.observation
        .createMutualSensingWindowEvidence(
          idHex: UUID().hexString,
          eventIdHex: eventId,
          eventDefinitionDigestHex: definitionDigest,
          observerHex: cryptography.eventSigningPublicKey(eventCode: eventCode).hexString,
          finalizedAt: Date().timeIntervalSince1970,
          reporterRpidHex: reporterRpid,
          enin: 1,
          observedRpidHexes: [observedRpid],
          rpidClaimHex: nil,
          participantCommitmentHex: nil,
          legacyPeerCount: nil
        )
    )
    let preparation = ExportedKotlinPackages.org.levarac.parallax.observation
      .prepareMutualSensingObservation(evidence: evidence)
    let eligible = try XCTUnwrap(
      preparation as?
        ExportedKotlinPackages.org.levarac.parallax.observation.ObservationPreparationResult.Eligible
    )
    let signature = cryptography.signWindowReport(
      eventCode: eventCode,
      bytes: Data(bytesFromKotlinByteArray: eligible.prepared.signatureStructure.toByteArray())
    )
    let signed = eligible.prepared.signWithCompactSignatureHex(
      rHex: signature.r.hexString,
      sHex: signature.s.hexString
    )
    let stored = ExportedKotlinPackages.org.levarac.parallax.submission
      .storeSignedObservation(signed: signed)
    let client = ExportedKotlinPackages.org.levarac.parallax.submission.createSubmissionClient()
    defer { client.close() }

    let result = await withCheckedContinuation {
      (continuation: CheckedContinuation<ExportedKotlinPackages.org.levarac.parallax.submission.SubmissionResult, Never>) in
      client.submit(observation: stored, configuration: configuration) { result in
        continuation.resume(returning: result)
      }
    }

    XCTAssertTrue(result.isSuccess, result.errorMessage ?? "reference operator did not accept the Observation")
    XCTAssertNotNil(result.receipt)
    XCTAssertEqual(result.statusCode, 201, "the test submits a fresh Observation, not an idempotent retry")
  }

  private func requiredEnvironment(
    _ name: String,
    from environment: [String: String]
  ) throws -> String {
    guard let value = environment[name], !value.isEmpty else {
      throw XCTSkip("set \(name) for the local operator integration")
    }
    return value
  }
}

private extension Data {
  init(bytesFromKotlinByteArray bytes: ExportedKotlinPackages.kotlin.ByteArray) {
    self.init((0..<Int(bytes.size)).map { index in
      UInt8(bitPattern: bytes[Int32(index)])
    })
  }

  var hexString: String {
    map { String(format: "%02x", $0) }.joined()
  }
}

private extension UUID {
  var hexString: String {
    var copy = self
    return withUnsafeBytes(of: &copy) { Data($0).hexString }
  }
}
