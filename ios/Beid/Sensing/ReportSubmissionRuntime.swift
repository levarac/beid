// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import BeidSharedKit
import Foundation
import os

/// Bounded, read-only projection for the authenticated Lab host.
/// Signed payloads, receipts, keys, and raw errors stay on-device.
struct LabRecordMetadata: Equatable {
  let windowId: String
  let eventId: String
  let observationDigest: String?
  let status: String
  let receiptStored: Bool
  let terminalError: String?
}

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
    eventIdHex: String,
    completion: @escaping (VerifiedSubmissionDefinition?) -> Void
  )
}

/// Native adapter from the registry module's verified EventDefinitionContext
/// to the shared submission configuration. The endpoint, receipt key, event
/// identity, digest, and validity all come from one context object.
@MainActor
final class RegistryEventDefinitionContextProvider: EventDefinitionContextProvider {
  private let resolveByCanonicalEventId: (
    String,
    @escaping (VerifiedSubmissionDefinition?) -> Void
  ) -> Void

  init(
    client: ExportedKotlinPackages.org.levarac.parallax.registry.RegistryClient,
    allowInsecureLoopbackForTests: Bool = false
  ) {
    self.resolveByCanonicalEventId = { eventIdHex, completion in
      client.resolveEventDefinition(
        eventIdHex: eventIdHex,
        pin: ExportedKotlinPackages.org.levarac.parallax.registry.safeRegistryReadPin(),
        useTimeEpochSeconds: Int64(Date().timeIntervalSince1970)
      ) { resolution in
        Task { @MainActor in
          guard resolution.isSuccess, let context = resolution.context,
                let configuration =
                  ExportedKotlinPackages.org.levarac.parallax.submission
                    .createSubmissionOperatorConfigurationFromEventDefinition(
                      context: context,
                      allowInsecureLoopbackForTests: allowInsecureLoopbackForTests
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

  /// Hermetic registry lookup seam used by the integration test. It still
  /// exercises this concrete production adapter and requires the caller to
  /// supply the canonical Event ID; it does not restore event-code hashing.
  init(
    lookup: @escaping (
      String,
      @escaping (VerifiedSubmissionDefinition?) -> Void
    ) -> Void
  ) {
    self.resolveByCanonicalEventId = lookup
  }

  func resolve(
    eventIdHex: String,
    completion: @escaping (VerifiedSubmissionDefinition?) -> Void
  ) {
    guard let normalized = eventIdHex.normalizedCanonicalEventIdHex else {
      completion(nil)
      return
    }
    resolveByCanonicalEventId(normalized, completion)
  }
}

@MainActor
protocol WindowReportSubmissionRuntimeProtocol: AnyObject {
  func captureAndQueueWindow(
    id: UUID,
    eventCode: String,
    eventIdHex: String?,
    enin: Int,
    peerRpids: Set<String>,
    reporterRpid: String?,
    participantCommitment: Data?
  )

  func submitPending()

  /// beid#292's Transparency screen ("Sent"/"Acceptance receipt" rows): the
  /// most-advanced durable submission state (`.accepted` > `.submitting` >
  /// `.prepared`) among this runtime's records for `eventCode`, or `nil` if
  /// no submission has ever been queued for it. A pure read of already-
  /// persisted state — never triggers a network call or a write.
  func submissionState(forEventCode eventCode: String) -> ReportSubmissionState?
  func excludedWindowCount(forEventCode eventCode: String) -> Int
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
    eventIdHex: String?,
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
      let exclusion = ReportSubmissionExclusion(
        id: id,
        eventCode: eventCode,
        eventIdHex: eventIdHex,
        enin: enin,
        peerCount: peerRpids.count,
        // ObservationModels.kt's LEGACY_COUNT_ONLY wire name; the exported
        // factory cannot accept nil reporter RPID, so classification is native.
        reasonCode: "legacy-count-only",
        createdAt: Date()
      )
      do {
        try store.addExclusion(exclusion)
      } catch {
        Self.log.error(
          "Unable to persist count-only exclusion: \(String(describing: error), privacy: .public)"
        )
      }
      submitPending()
      return
    }

    // Persist the close-window inputs before any registry lookup. A process
    // boundary or a failed definition fetch must not erase the only copy of
    // the RPID set and timing needed to reconstruct the Observation.
    let capture = ReportSubmissionCapture(
      id: id,
      eventCode: eventCode,
      eventIdHex: eventIdHex,
      enin: enin,
      peerRpids: peerRpids.sorted(),
      reporterRpid: reporterRpid,
      participantCommitment: participantCommitment,
      finalizedAt: Date().timeIntervalSince1970
    )
    do {
      try store.addPendingCapture(capture)
    } catch {
      Self.log.error("Unable to persist raw close-window capture: \(String(describing: error), privacy: .public)")
      return
    }
    processPendingCapture(capture)
  }

  private func processPendingCapture(_ capture: ReportSubmissionCapture) {
    if store.record(id: capture.id) != nil {
      do {
        try store.removePendingCapture(id: capture.id)
      } catch {
        Self.log.error("Unable to remove a completed raw close-window capture: \(String(describing: error), privacy: .public)")
      }
      return
    }
    guard let eventIdHex = capture.eventIdHex,
          eventIdHex.normalizedCanonicalEventIdHex != nil
    else {
      Self.log.error("Deferred canonical submission without a canonical Event ID")
      return
    }
    guard inFlight.insert(capture.id).inserted else { return }
    definitionProvider.resolve(eventIdHex: eventIdHex) { [weak self] verified in
      Task { @MainActor [weak self] in
        guard let self else { return }
        self.inFlight.remove(capture.id)
        self.prepareAndQueueWindow(capture: capture, verified: verified)
      }
    }
  }

  private func prepareAndQueueWindow(
    capture: ReportSubmissionCapture,
    verified: VerifiedSubmissionDefinition?
  ) {
    guard let verified,
          let eventId = verified.configuration.eventId,
          let definitionDigest = verified.configuration.eventDefinitionDigest,
          let requestedEventIdHex = capture.eventIdHex
    else {
      Self.log.error("Deferred canonical submission without a verified Event Definition")
      return
    }

    let reporterRpid = capture.reporterRpid
    let eventIdHex = Data(bytesFromKotlinByteArray: eventId.toByteArray()).hexString
    guard requestedEventIdHex.normalizedCanonicalEventIdHex == eventIdHex else {
      Self.log.error("Deferred canonical submission whose definition Event ID did not match the requested Event ID")
      return
    }
    let definitionDigestHex = Data(
      bytesFromKotlinByteArray: definitionDigest.toByteArray()
    ).hexString
    let observerHex = eventSigningCryptography
      .eventSigningPublicKey(eventCode: capture.eventCode)
      .hexString
    let observedRpidHexes = capture.peerRpids.map { $0.lowercased() }.sorted()
    let evidence = ExportedKotlinPackages.org.levarac.parallax.observation
      .createMutualSensingWindowEvidence(
        idHex: capture.id.hexString,
        eventIdHex: eventIdHex,
        eventDefinitionDigestHex: definitionDigestHex,
        observerHex: observerHex,
        finalizedAt: capture.finalizedAt,
        reporterRpidHex: reporterRpid,
        enin: Int64(capture.enin),
        observedRpidHexes: observedRpidHexes,
        rpidClaimHex: nil,
        participantCommitmentHex: capture.participantCommitment?.hexString,
        legacyPeerCount: nil
      )
    guard let evidence else {
      Self.log.error("Skipped canonical submission with malformed close-window evidence")
      return
    }

    let preparation = ExportedKotlinPackages.org.levarac.parallax.observation
      .prepareMutualSensingObservation(evidence: evidence)
    guard let eligible = preparation as?
      ExportedKotlinPackages.org.levarac.parallax.observation.ObservationPreparationResult.Eligible
    else {
      Self.log.error("Skipped an ineligible canonical close-window observation")
      return
    }

    let signatureInput = Data(
      bytesFromKotlinByteArray: eligible.prepared.signatureStructure.toByteArray()
    )
    let signature = eventSigningCryptography.signWindowReport(
      eventCode: capture.eventCode,
      bytes: signatureInput
    )
    let signed = eligible.prepared.signWithCompactSignatureHex(
      rHex: signature.r.hexString,
      sHex: signature.s.hexString
    )
    let stored = ExportedKotlinPackages.org.levarac.parallax.submission
      .storeSignedObservation(signed: signed)
    let record = ReportSubmissionRecord(
      id: capture.id,
      eventCode: capture.eventCode,
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
      try store.removePendingCapture(id: capture.id)
    } catch {
      Self.log.error("Unable to persist canonical Observation: \(String(describing: error), privacy: .public)")
    }
    submitPending()
  }

  func submissionState(forEventCode eventCode: String) -> ReportSubmissionState? {
    store.records
      .filter { $0.eventCode == eventCode }
      .max { $0.submissionState.progressRank < $1.submissionState.progressRank }?
      .submissionState
  }

  func excludedWindowCount(forEventCode eventCode: String) -> Int {
    store.exclusions.filter { $0.eventCode == eventCode }.count
  }

  func labRecordMetadata() -> [LabRecordMetadata] {
    store.records.compactMap { record in
      guard let eventId = record.eventIdHex else { return nil }
      return LabRecordMetadata(
        windowId: record.id.uuidString.lowercased(),
        eventId: eventId,
        observationDigest: record.observationDigestHex,
        status: record.submissionState.rawValue,
        receiptStored: record.acceptanceReceiptHex != nil,
        terminalError: record.terminalErrorCode
      )
    }
  }

  func submitPending() {
    for capture in store.pendingCaptures {
      processPendingCapture(capture)
    }
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
    ExportedKotlinPackages.org.levarac.parallax.submission
      .createSubmissionOperatorConfigurationWithOperatorId(
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

  /// Exposes the same `BeidReportSubmissionEnabled` build-flag check
  /// `makeIfEnabled(bundle:...)` already gates on, for callers (gh#291's
  /// Daily Summary screen) that need to state the submission pipeline's
  /// on/off status in words without constructing a runtime instance. Reuses
  /// `isEnabled(bundle:)` rather than re-reading the Info.plist key a second
  /// time, so the two can never disagree about what "enabled" means.
  static func isSubmissionEnabled(bundle: Bundle = .main) -> Bool {
    isEnabled(bundle: bundle)
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

private extension ReportSubmissionState {
  /// Ordering for `submissionState(forEventCode:)`'s "most advanced state
  /// wins" rule: an event with both a `.submitting` and an `.accepted`
  /// record must report `.accepted`, not whichever record happened to be
  /// stored first.
  var progressRank: Int {
    switch self {
    case .prepared: return 0
    case .submitting: return 1
    case .accepted: return 2
    }
  }
}

private extension String {
  var normalizedCanonicalEventIdHex: String? {
    let value = hasPrefix("0x") || hasPrefix("0X") ? String(dropFirst(2)) : self
    guard value.count == 64,
          value.allSatisfy({
            ($0 >= "0" && $0 <= "9") ||
              ($0 >= "a" && $0 <= "f") ||
              ($0 >= "A" && $0 <= "F")
          })
    else {
      return nil
    }
    return value.lowercased()
  }
}
