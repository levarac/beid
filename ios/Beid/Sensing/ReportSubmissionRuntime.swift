// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import BeidSharedKit
import Foundation
import os

/// The only submission trust material accepted by the runtime. Production
/// instances are produced from a verified registry EventDefinitionContext;
/// tests may inject a hermetic equivalent without changing the runtime path.
struct VerifiedSubmissionDefinition {
  let configuration: ExportedKotlinPackages.org.levarac.parallax.submission
    .SubmissionOperatorConfiguration
}

@MainActor
protocol EventDefinitionContextProvider: AnyObject {
  func resolve(
    eventCode: String,
    completion: @escaping (VerifiedSubmissionDefinition?) -> Void
  )
}

/// Native adapter from the registry module's verified EventDefinitionContext
/// to the shared submission configuration. The endpoint, receipt key, event
/// identity, digest, and validity all come from one context object.
@MainActor
final class RegistryEventDefinitionContextProvider: EventDefinitionContextProvider {
  private let client: ExportedKotlinPackages.org.levarac.parallax.registry.RegistryClient
  private let allowInsecureLoopbackForTests: Bool

  init(
    client: ExportedKotlinPackages.org.levarac.parallax.registry.RegistryClient,
    allowInsecureLoopbackForTests: Bool = false
  ) {
    self.client = client
    self.allowInsecureLoopbackForTests = allowInsecureLoopbackForTests
  }

  func resolve(
    eventCode: String,
    completion: @escaping (VerifiedSubmissionDefinition?) -> Void
  ) {
    let eventIdHex = EventIdHash.compute(eventCode: eventCode).hexString
    client.resolveEventDefinition(
      eventIdHex: eventIdHex,
      pin: ExportedKotlinPackages.org.levarac.parallax.registry.safeRegistryReadPin(),
      useTimeEpochSeconds: Int64(Date().timeIntervalSince1970)
    ) { [weak self] resolution in
      Task { @MainActor [weak self] in
        guard let self else { return }
        guard resolution.isSuccess, let context = resolution.context,
              let configuration =
                ExportedKotlinPackages.org.levarac.parallax.submission
                  .createSubmissionOperatorConfigurationFromEventDefinition(
                    context: context,
                    allowInsecureLoopbackForTests: self.allowInsecureLoopbackForTests
                  )
        else {
          completion(nil)
          return
        }
        completion(VerifiedSubmissionDefinition(configuration: configuration))
      }
    }
  }
}

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
  private let definitionProvider: any EventDefinitionContextProvider
  private let store: ReportSubmissionStore
  private let client: ExportedKotlinPackages.org.levarac.parallax.submission.SubmissionClient
  private let allowInsecureLoopbackForTests: Bool
  private var inFlight = Set<UUID>()

  #if DEBUG
  /// Test-only crash boundary: returning false leaves the durable record in
  /// SUBMITTING after a verified operator response, exactly like a process
  /// death before the receipt write.
  var receiptPersistenceGate: (() -> Bool)?
  #endif

  private init(
    eventSigningCryptography: any SensingCryptography,
    definitionProvider: any EventDefinitionContextProvider,
    store: ReportSubmissionStore,
    client: ExportedKotlinPackages.org.levarac.parallax.submission.SubmissionClient,
    allowInsecureLoopbackForTests: Bool
  ) {
    self.eventSigningCryptography = eventSigningCryptography
    self.definitionProvider = definitionProvider
    self.store = store
    self.client = client
    self.allowInsecureLoopbackForTests = allowInsecureLoopbackForTests
  }

  static func makeIfEnabled(
    bundle: Bundle = .main,
    eventSigningCryptography: any SensingCryptography,
    definitionProvider: (any EventDefinitionContextProvider)? = nil,
    fileURL: URL? = nil,
    allowInsecureLoopbackForTests: Bool = false
  ) -> ReportSubmissionRuntime? {
    guard isEnabled(bundle: bundle), let definitionProvider else { return nil }

    return ReportSubmissionRuntime(
      eventSigningCryptography: eventSigningCryptography,
      definitionProvider: definitionProvider,
      store: ReportSubmissionStore(fileURL: fileURL),
      client: ExportedKotlinPackages.org.levarac.parallax.submission.createSubmissionClient(),
      allowInsecureLoopbackForTests: allowInsecureLoopbackForTests
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
    guard reporterRpid != nil else {
      Self.log.error("Skipped canonical submission for a window without reporter RPID")
      submitPending()
      return
    }

    // These are already copied by SensingCoordinator before its RPID set is
    // discarded. Definition resolution may be asynchronous, so retain only
    // the lossless close-window inputs in this closure.
    definitionProvider.resolve(eventCode: eventCode) { [weak self] verified in
      Task { @MainActor [weak self] in
        guard let self else { return }
        self.prepareAndQueueWindow(
          id: id,
          eventCode: eventCode,
          enin: enin,
          peerRpids: peerRpids,
          reporterRpid: reporterRpid,
          participantCommitment: participantCommitment,
          verified: verified
        )
      }
    }
  }

  private func prepareAndQueueWindow(
    id: UUID,
    eventCode: String,
    enin: Int,
    peerRpids: Set<String>,
    reporterRpid: String?,
    participantCommitment: Data?,
    verified: VerifiedSubmissionDefinition?
  ) {
    guard let verified,
          let eventId = verified.configuration.eventId,
          let definitionDigest = verified.configuration.eventDefinitionDigest,
          let reporterRpid
    else {
      Self.log.error("Skipped canonical submission without a verified Event Definition")
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
      endpoint: verified.configuration.submissionEndpoint,
      receiptPublicKeyHex: Data(
        bytesFromKotlinByteArray: verified.configuration.receiptPublicKey.toByteArray()
      ).hexString,
      eventIdHex: eventIdHex,
      eventDefinitionDigestHex: definitionDigestHex,
      validFrom: verified.configuration.validFrom,
      validUntil: verified.configuration.validUntil,
      signedObservationHex: Data(
        bytesFromKotlinByteArray: stored.signedBytes.toByteArray()
      ).hexString,
      observationDigestHex: Data(
        bytesFromKotlinByteArray: stored.observationDigest.toByteArray()
      ).hexString,
      operatorIdHex: Data(
        bytesFromKotlinByteArray: verified.configuration.operatorId.toByteArray()
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
      guard let stored = ExportedKotlinPackages.org.levarac.parallax.submission
        .restoreStoredObservation(signedBytesHex: record.signedObservationHex) else {
        inFlight.remove(record.id)
        Self.log.error("Skipped a persisted submission with invalid queue bytes")
        continue
      }
      guard Data(bytesFromKotlinByteArray: stored.observationDigest.toByteArray())
        .hexString.caseInsensitiveCompare(record.observationDigestHex) == .orderedSame else {
        inFlight.remove(record.id)
        Self.log.error("Skipped a persisted submission with mismatched queue digest")
        continue
      }
      guard let configuration = makeConfiguration(for: record) else {
        inFlight.remove(record.id)
        Self.log.error("Skipped a persisted submission with invalid queue metadata")
        continue
      }
      if record.submissionState == .submitting {
        lookupReceipt(
          for: record,
          stored: stored,
          configuration: configuration
        )
      } else {
        beginPost(
          for: record,
          stored: stored,
          configuration: configuration
        )
      }
    }
  }

  private func beginPost(
    for record: ReportSubmissionRecord,
    stored: ExportedKotlinPackages.org.levarac.parallax.submission.StoredObservationV1,
    configuration: ExportedKotlinPackages.org.levarac.parallax.submission.SubmissionOperatorConfiguration
  ) {
    do {
      _ = try store.markSubmitting(for: record.id)
    } catch {
      inFlight.remove(record.id)
      Self.log.error("Unable to persist SUBMITTING state: \(String(describing: error), privacy: .public)")
      return
    }
    post(
      for: record,
      stored: stored,
      configuration: configuration
    )
  }

  private func lookupReceipt(
    for record: ReportSubmissionRecord,
    stored: ExportedKotlinPackages.org.levarac.parallax.submission.StoredObservationV1,
    configuration: ExportedKotlinPackages.org.levarac.parallax.submission.SubmissionOperatorConfiguration
  ) {
    client.lookupReceipt(observation: stored, configuration: configuration) { [weak self] result in
      Task { @MainActor [weak self] in
        guard let self else { return }
        if result.isSuccess, let receipt = result.receipt {
          self.persistAcceptedReceipt(receipt, for: record)
        } else if result.errorCode == "receipt_not_found" {
          // A durable SUBMITTING state means a POST may have reached the
          // operator. Only an explicit missing receipt permits the POST.
          self.post(for: record, stored: stored, configuration: configuration)
        } else {
          self.finishFailedSubmission(result, for: record)
        }
      }
    }
  }

  private func post(
    for record: ReportSubmissionRecord,
    stored: ExportedKotlinPackages.org.levarac.parallax.submission.StoredObservationV1,
    configuration: ExportedKotlinPackages.org.levarac.parallax.submission.SubmissionOperatorConfiguration
  ) {
    client.submit(observation: stored, configuration: configuration) { [weak self] result in
      Task { @MainActor [weak self] in
        guard let self else { return }
        guard result.isSuccess, let receipt = result.receipt else {
          self.finishFailedSubmission(result, for: record)
          return
        }
        #if DEBUG
        if let receiptPersistenceGate = self.receiptPersistenceGate,
           !receiptPersistenceGate() {
          self.inFlight.remove(record.id)
          return
        }
        #endif
        self.persistAcceptedReceipt(receipt, for: record)
      }
    }
  }

  private func persistAcceptedReceipt(
    _ receipt: ExportedKotlinPackages.org.levarac.parallax.submission.AcceptanceReceipt,
    for record: ReportSubmissionRecord
  ) {
    defer { inFlight.remove(record.id) }
    do {
      _ = try store.storeReceipt(
        for: record.id,
        signedReceiptHex: Data(
          bytesFromKotlinByteArray: receipt.signedBytes.toByteArray()
        ).hexString
      )
    } catch {
      Self.log.error("Unable to persist verified AcceptanceReceipt: \(String(describing: error), privacy: .public)")
    }
  }

  private func finishFailedSubmission(
    _ result: ExportedKotlinPackages.org.levarac.parallax.submission.SubmissionResult,
    for record: ReportSubmissionRecord
  ) {
    defer { inFlight.remove(record.id) }
    guard !result.isRetryable else { return }
    do {
      _ = try store.markTerminalFailure(
        for: record.id,
        code: result.errorCode ?? "submission_failed"
      )
    } catch {
      Self.log.error("Unable to persist terminal submission failure: \(String(describing: error), privacy: .public)")
    }
  }

  private func makeConfiguration(
    for record: ReportSubmissionRecord
  ) -> ExportedKotlinPackages.org.levarac.parallax.submission.SubmissionOperatorConfiguration? {
    ExportedKotlinPackages.org.levarac.parallax.submission.createSubmissionOperatorConfiguration(
      endpoint: record.endpoint,
      receiptPublicKeyHex: record.receiptPublicKeyHex,
      operatorIdHex: record.operatorIdHex,
      eventIdHex: record.eventIdHex,
      eventDefinitionDigestHex: record.eventDefinitionDigestHex,
      validFrom: record.validFrom,
      validUntil: record.validUntil,
      allowInsecureLoopbackForTests: allowInsecureLoopbackForTests
    )
  }

  private static func isEnabled(bundle: Bundle) -> Bool {
    guard let raw = bundle.object(forInfoDictionaryKey: "BeidReportSubmissionEnabled") as? String else {
      return false
    }
    return ["1", "yes", "true", "on"].contains(
      raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    )
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
