// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import BeidSharedKit
import Foundation
import os

@MainActor
protocol WindowReportSubmissionRuntimeProtocol: AnyObject {
  func captureAndQueueWindow(
    id: UUID,
    eventCode: String,
    enin: Int,
    peerRpids: Set<String>,
    reporterRpid: String?,
    participantCommitment: Data?
  )

  func submitPending()
}

/// Native composition boundary for the inactive-by-default report pipeline.
///
/// Barnard remains the only owner of the event signing key. This type maps
/// the lossless close-window snapshot into the shared ObservationV1 decision,
/// stores the resulting exact COSE bytes, and hands those same bytes to the
/// shared HTTPS client. It does not alter the legacy WindowReport or ledger.
@MainActor
final class ReportSubmissionRuntime: WindowReportSubmissionRuntimeProtocol {
  private static let log = Logger(subsystem: "org.levarac.beid", category: "submission")

  private let eventSigningCryptography: any SensingCryptography
  private let store: ReportSubmissionStore
  private let client: ExportedKotlinPackages.org.levarac.parallax.submission.SubmissionClient
  private let configuration: ExportedKotlinPackages.org.levarac.parallax.submission.SubmissionOperatorConfiguration
  private var inFlight = Set<UUID>()

  private init(
    eventSigningCryptography: any SensingCryptography,
    store: ReportSubmissionStore,
    client: ExportedKotlinPackages.org.levarac.parallax.submission.SubmissionClient,
    configuration: ExportedKotlinPackages.org.levarac.parallax.submission.SubmissionOperatorConfiguration
  ) {
    self.eventSigningCryptography = eventSigningCryptography
    self.store = store
    self.client = client
    self.configuration = configuration
  }

  static func makeIfEnabled(
    bundle: Bundle = .main,
    eventSigningCryptography: any SensingCryptography,
    fileURL: URL? = nil
  ) -> ReportSubmissionRuntime? {
    guard isEnabled(bundle: bundle) else { return nil }
    guard
      let endpoint = nonEmptyString(
        bundle.object(forInfoDictionaryKey: "BeidReportSubmissionEndpoint")
      ),
      let operatorKey = nonEmptyString(
        bundle.object(forInfoDictionaryKey: "BeidOperatorReceiptPublicKey")
      ),
      let eventId = nonEmptyString(bundle.object(forInfoDictionaryKey: "BeidEventId")),
      let definitionDigest = nonEmptyString(
        bundle.object(forInfoDictionaryKey: "BeidEventDefinitionDigest")
      )
    else {
      return nil
    }

    let allowInsecureLoopbackForTests: Bool
    #if DEBUG
    allowInsecureLoopbackForTests = ProcessInfo.processInfo.environment[
      "BEID_RUN_OPERATOR_SUBMISSION_TEST"
    ] == "1"
    #else
    allowInsecureLoopbackForTests = false
    #endif

    guard let configuration =
      ExportedKotlinPackages.org.levarac.parallax.submission.createSubmissionOperatorConfiguration(
        endpoint: endpoint,
        receiptPublicKeyHex: operatorKey,
        eventIdHex: eventId,
        eventDefinitionDigestHex: definitionDigest,
        validFrom: parseOptionalInt64(
          bundle.object(forInfoDictionaryKey: "BeidEventDefinitionValidFrom")
        ),
        validUntil: parseOptionalInt64(
          bundle.object(forInfoDictionaryKey: "BeidEventDefinitionValidUntil")
        ),
        allowInsecureLoopbackForTests: allowInsecureLoopbackForTests
      )
    else {
      return nil
    }

    return ReportSubmissionRuntime(
      eventSigningCryptography: eventSigningCryptography,
      store: ReportSubmissionStore(fileURL: fileURL),
      client: ExportedKotlinPackages.org.levarac.parallax.submission.createSubmissionClient(),
      configuration: configuration
    )
  }

  func captureAndQueueWindow(
    id: UUID,
    eventCode: String,
    enin: Int,
    peerRpids: Set<String>,
    reporterRpid: String?,
    participantCommitment: Data?
  ) {
    // A missing reporter RPID means this window has only legacy/count-style
    // evidence. It is deliberately ineligible and is never synthesized into
    // an Observation from the peer count.
    guard let reporterRpid else {
      Self.log.error("Skipped canonical submission for a window without reporter RPID")
      submitPending()
      return
    }
    guard let eventId = configuration.eventId,
          let definitionDigest = configuration.eventDefinitionDigest
    else {
      Self.log.error("Skipped canonical submission without Event Definition identity")
      submitPending()
      return
    }

    let eventIdHex = Data(bytesFromKotlinByteArray: eventId.toByteArray()).hexString
    let definitionDigestHex = Data(
      bytesFromKotlinByteArray: definitionDigest.toByteArray()
    ).hexString
    let observerHex = eventSigningCryptography
      .eventSigningPublicKey(eventCode: eventCode)
      .hexString
    let observedRpidHexes = peerRpids.map { $0.lowercased() }.sorted()
    let evidence = ExportedKotlinPackages.org.levarac.parallax.observation
      .createMutualSensingWindowEvidence(
        idHex: id.hexString,
        eventIdHex: eventIdHex,
        eventDefinitionDigestHex: definitionDigestHex,
        observerHex: observerHex,
        finalizedAt: Date().timeIntervalSince1970,
        reporterRpidHex: reporterRpid,
        enin: Int64(enin),
        observedRpidHexes: observedRpidHexes,
        rpidClaimHex: nil,
        participantCommitmentHex: participantCommitment?.hexString,
        legacyPeerCount: nil
      )
    guard let evidence else {
      Self.log.error("Skipped canonical submission with malformed close-window evidence")
      submitPending()
      return
    }

    let preparation = ExportedKotlinPackages.org.levarac.parallax.observation
      .prepareMutualSensingObservation(evidence: evidence)
    guard let eligible = preparation as?
      ExportedKotlinPackages.org.levarac.parallax.observation.ObservationPreparationResult.Eligible
    else {
      Self.log.error("Skipped an ineligible canonical close-window observation")
      submitPending()
      return
    }

    let signatureInput = Data(
      bytesFromKotlinByteArray: eligible.prepared.signatureStructure.toByteArray()
    )
    let signature = eventSigningCryptography.signWindowReport(
      eventCode: eventCode,
      bytes: signatureInput
    )
    let signed = eligible.prepared.signWithCompactSignatureHex(
      rHex: signature.r.hexString,
      sHex: signature.s.hexString
    )
    let stored = ExportedKotlinPackages.org.levarac.parallax.submission
      .storeSignedObservation(signed: signed)
    let record = ReportSubmissionRecord(
      id: id,
      eventCode: eventCode,
      endpoint: configuration.submissionEndpoint,
      receiptPublicKeyHex: Data(
        bytesFromKotlinByteArray: configuration.receiptPublicKey.toByteArray()
      ).hexString,
      eventIdHex: eventIdHex,
      eventDefinitionDigestHex: definitionDigestHex,
      validFrom: configuration.validFrom,
      validUntil: configuration.validUntil,
      signedObservationHex: Data(
        bytesFromKotlinByteArray: stored.signedBytes.toByteArray()
      ).hexString,
      observationDigestHex: Data(
        bytesFromKotlinByteArray: stored.observationDigest.toByteArray()
      ).hexString
    )

    do {
      try store.add(record)
    } catch {
      Self.log.error("Unable to persist canonical Observation: \(String(describing: error), privacy: .public)")
    }
    submitPending()
  }

  func submitPending() {
    for record in store.pendingRecords {
      guard inFlight.insert(record.id).inserted else { continue }
      guard
        let stored = ExportedKotlinPackages.org.levarac.parallax.submission
          .restoreStoredObservation(signedBytesHex: record.signedObservationHex),
        Data(bytesFromKotlinByteArray: stored.observationDigest.toByteArray())
          .hexString.caseInsensitiveCompare(
          record.observationDigestHex
        ) == .orderedSame,
        let configuration = makeConfiguration(for: record)
      else {
        inFlight.remove(record.id)
        Self.log.error("Skipped a persisted submission with invalid queue metadata")
        continue
      }

      client.submit(observation: stored, configuration: configuration) { [weak self] result in
        Task { @MainActor [weak self] in
          guard let self else { return }
          defer { self.inFlight.remove(record.id) }
          guard result.isSuccess, let receipt = result.receipt else {
            // Only transport failures explicitly classified as retryable may
            // remain pending. HTTP 4xx, protocol failures, and cancellation
            // are terminal for this exact window and must not be submitted
            // again on every lifecycle trigger.
            guard !result.isRetryable else { return }
            do {
              _ = try self.store.markTerminalFailure(
                for: record.id,
                code: result.errorCode ?? "submission_failed"
              )
            } catch {
              Self.log.error("Unable to persist terminal submission failure: \(String(describing: error), privacy: .public)")
            }
            return
          }
          do {
            _ = try self.store.storeReceipt(
              for: record.id,
              signedReceiptHex: Data(
                bytesFromKotlinByteArray: receipt.signedBytes.toByteArray()
              ).hexString
            )
          } catch {
            Self.log.error("Unable to persist verified AcceptanceReceipt: \(String(describing: error), privacy: .public)")
          }
        }
      }
    }
  }

  private func makeConfiguration(
    for record: ReportSubmissionRecord
  ) -> ExportedKotlinPackages.org.levarac.parallax.submission.SubmissionOperatorConfiguration? {
    ExportedKotlinPackages.org.levarac.parallax.submission.createSubmissionOperatorConfiguration(
      endpoint: record.endpoint,
      receiptPublicKeyHex: record.receiptPublicKeyHex,
      eventIdHex: record.eventIdHex,
      eventDefinitionDigestHex: record.eventDefinitionDigestHex,
      validFrom: record.validFrom,
      validUntil: record.validUntil,
      allowInsecureLoopbackForTests: {
        #if DEBUG
        return ProcessInfo.processInfo.environment["BEID_RUN_OPERATOR_SUBMISSION_TEST"] == "1"
        #else
        return false
        #endif
      }()
    )
  }

  private static func isEnabled(bundle: Bundle) -> Bool {
    guard let raw = bundle.object(forInfoDictionaryKey: "BeidReportSubmissionEnabled") as? String else {
      return false
    }
    return ["1", "yes", "true", "on"].contains(raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
  }

  private static func nonEmptyString(_ value: Any?) -> String? {
    guard let string = value as? String else { return nil }
    let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  private static func parseOptionalInt64(_ value: Any?) -> Int64? {
    guard let string = value as? String else { return nil }
    return Int64(string.trimmingCharacters(in: .whitespacesAndNewlines))
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
