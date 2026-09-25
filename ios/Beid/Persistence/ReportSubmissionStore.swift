// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import Darwin
import BeidSharedKit
import Foundation

enum ReportSubmissionStoreError: Error {
  case conflictingObservation
  case conflictingCapture
  case conflictingExclusion
  case missingObservation
  case invalidReceipt
  case invalidState
}

/// A window that was durably classified as unable to become a canonical
/// Observation. Kept separate from submission records because count-only
/// evidence has none of their required exact-byte or operator fields.
struct ReportSubmissionExclusion: Identifiable, Codable, Equatable {
  let id: UUID
  let eventCode: String
  let eventIdHex: String?
  let enin: Int
  let peerCount: Int
  let reasonCode: String
  let createdAt: Date

  func hasSameWindowInputs(as other: ReportSubmissionExclusion) -> Bool {
    id == other.id &&
      eventCode == other.eventCode &&
      eventIdHex == other.eventIdHex &&
      enin == other.enin &&
      peerCount == other.peerCount &&
      reasonCode == other.reasonCode
  }
}

/// Durable lifecycle state for one exact-byte submission.
///
/// `SUBMITTING` is written before the network POST. If the process dies after
/// the operator accepted the Observation but before the receipt write lands,
/// the next process must perform a receipt lookup before considering a POST.
enum ReportSubmissionState: String, Codable {
  case prepared = "PREPARED"
  case submitting = "SUBMITTING"
  case accepted = "ACCEPTED"
}

/// Lossless window-close inputs captured before registry resolution and
/// Observation preparation. This is a separate durable file because the
/// inputs must survive a process boundary even when no signed Observation
/// exists yet.
struct ReportSubmissionCapture: Identifiable, Codable, Equatable {
  let id: UUID
  let eventCode: String
  let eventIdHex: String?
  let enin: Int
  let peerRpids: [String]
  let reporterRpid: String
  let participantCommitment: Data?
  let finalizedAt: TimeInterval
  let createdAt: Date

  init(
    id: UUID,
    eventCode: String,
    eventIdHex: String?,
    enin: Int,
    peerRpids: [String],
    reporterRpid: String,
    participantCommitment: Data?,
    finalizedAt: TimeInterval = Date().timeIntervalSince1970,
    createdAt: Date = Date()
  ) {
    self.id = id
    self.eventCode = eventCode
    self.eventIdHex = eventIdHex
    self.enin = enin
    self.peerRpids = Array(Set(peerRpids)).sorted()
    self.reporterRpid = reporterRpid
    self.participantCommitment = participantCommitment
    self.finalizedAt = finalizedAt
    self.createdAt = createdAt
  }

  func hasSameWindowInputs(as other: ReportSubmissionCapture) -> Bool {
    id == other.id &&
      eventCode == other.eventCode &&
      eventIdHex == other.eventIdHex &&
      enin == other.enin &&
      peerRpids == other.peerRpids &&
      reporterRpid == other.reporterRpid &&
      participantCommitment == other.participantCommitment &&
      finalizedAt == other.finalizedAt
  }
}

/// One canonical Observation and its operator receipt.
///
/// The signed Observation is stored as hex only because it is a lossless,
/// Swift Export-friendly representation of the exact COSE bytes. The store
/// never decodes, re-encodes, or reconstructs those bytes before a retry.
struct ReportSubmissionRecord: Identifiable, Codable, Equatable {
  let id: UUID
  let eventCode: String
  let endpoint: String
  let receiptPublicKeyHex: String
  let operatorIdHex: String?
  let eventIdHex: String?
  let eventDefinitionDigestHex: String?
  let validFrom: Int64?
  let validUntil: Int64?
  let signedObservationHex: String
  let observationDigestHex: String
  var submissionState: ReportSubmissionState
  var acceptanceReceiptHex: String?
  var terminalErrorCode: String?
  let createdAt: Date

  init(
    id: UUID,
    eventCode: String,
    endpoint: String,
    receiptPublicKeyHex: String,
    eventIdHex: String?,
    eventDefinitionDigestHex: String?,
    validFrom: Int64?,
    validUntil: Int64?,
    signedObservationHex: String,
    observationDigestHex: String,
    operatorIdHex: String? = nil,
    submissionState: ReportSubmissionState = .prepared,
    acceptanceReceiptHex: String? = nil,
    terminalErrorCode: String? = nil,
    createdAt: Date = Date()
  ) {
    self.id = id
    self.eventCode = eventCode
    self.endpoint = endpoint
    self.receiptPublicKeyHex = receiptPublicKeyHex
    self.operatorIdHex = operatorIdHex
    self.eventIdHex = eventIdHex
    self.eventDefinitionDigestHex = eventDefinitionDigestHex
    self.validFrom = validFrom
    self.validUntil = validUntil
    self.signedObservationHex = signedObservationHex
    self.observationDigestHex = observationDigestHex
    self.submissionState = submissionState
    self.acceptanceReceiptHex = acceptanceReceiptHex
    self.terminalErrorCode = terminalErrorCode
    self.createdAt = createdAt
  }

  private enum CodingKeys: String, CodingKey {
    case id
    case eventCode
    case endpoint
    case receiptPublicKeyHex
    case operatorIdHex
    case eventIdHex
    case eventDefinitionDigestHex
    case validFrom
    case validUntil
    case signedObservationHex
    case observationDigestHex
    case submissionState
    case acceptanceReceiptHex
    case terminalErrorCode
    case createdAt
  }

  /// Older queue files predate the state field. They are still exact-byte
  /// records, so load them as PREPARED and let the normal state machine take
  /// over before the next POST.
  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(UUID.self, forKey: .id)
    eventCode = try container.decode(String.self, forKey: .eventCode)
    endpoint = try container.decode(String.self, forKey: .endpoint)
    receiptPublicKeyHex = try container.decode(String.self, forKey: .receiptPublicKeyHex)
    operatorIdHex = try container.decodeIfPresent(String.self, forKey: .operatorIdHex)
    eventIdHex = try container.decodeIfPresent(String.self, forKey: .eventIdHex)
    eventDefinitionDigestHex = try container.decodeIfPresent(
      String.self,
      forKey: .eventDefinitionDigestHex
    )
    validFrom = try container.decodeIfPresent(Int64.self, forKey: .validFrom)
    validUntil = try container.decodeIfPresent(Int64.self, forKey: .validUntil)
    signedObservationHex = try container.decode(String.self, forKey: .signedObservationHex)
    observationDigestHex = try container.decode(String.self, forKey: .observationDigestHex)
    submissionState = try container.decodeIfPresent(
      ReportSubmissionState.self,
      forKey: .submissionState
    ) ?? .prepared
    acceptanceReceiptHex = try container.decodeIfPresent(String.self, forKey: .acceptanceReceiptHex)
    terminalErrorCode = try container.decodeIfPresent(String.self, forKey: .terminalErrorCode)
    createdAt = try container.decode(Date.self, forKey: .createdAt)
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encode(eventCode, forKey: .eventCode)
    try container.encode(endpoint, forKey: .endpoint)
    try container.encode(receiptPublicKeyHex, forKey: .receiptPublicKeyHex)
    try container.encodeIfPresent(operatorIdHex, forKey: .operatorIdHex)
    try container.encodeIfPresent(eventIdHex, forKey: .eventIdHex)
    try container.encodeIfPresent(eventDefinitionDigestHex, forKey: .eventDefinitionDigestHex)
    try container.encodeIfPresent(validFrom, forKey: .validFrom)
    try container.encodeIfPresent(validUntil, forKey: .validUntil)
    try container.encode(signedObservationHex, forKey: .signedObservationHex)
    try container.encode(observationDigestHex, forKey: .observationDigestHex)
    try container.encode(submissionState, forKey: .submissionState)
    try container.encodeIfPresent(acceptanceReceiptHex, forKey: .acceptanceReceiptHex)
    try container.encodeIfPresent(terminalErrorCode, forKey: .terminalErrorCode)
    try container.encode(createdAt, forKey: .createdAt)
  }

  var isReceiptStored: Bool { acceptanceReceiptHex != nil }
  var isTerminal: Bool { terminalErrorCode != nil }

  func hasSameObservationAndConfiguration(as other: ReportSubmissionRecord) -> Bool {
    id == other.id &&
      eventCode == other.eventCode &&
      endpoint == other.endpoint &&
      receiptPublicKeyHex == other.receiptPublicKeyHex &&
      operatorIdHex == other.operatorIdHex &&
      eventIdHex == other.eventIdHex &&
      eventDefinitionDigestHex == other.eventDefinitionDigestHex &&
      validFrom == other.validFrom &&
      validUntil == other.validUntil &&
      signedObservationHex == other.signedObservationHex &&
      observationDigestHex == other.observationDigestHex
  }
}

/// Exact-byte local queue for canonical Observation submissions.
///
/// It is deliberately separate from the legacy `WindowReportStore` and the
/// shared ledger. A receipt is written into the same record only after the
/// shared client has verified its signature and its Observation digest.
@MainActor
final class ReportSubmissionStore: ObservableObject {
  @Published private(set) var records: [ReportSubmissionRecord] = []
  @Published private(set) var pendingCaptures: [ReportSubmissionCapture] = []
  @Published private(set) var exclusions: [ReportSubmissionExclusion] = []

  private let fileURL: URL
  private let pendingCaptureFileURL: URL
  private let exclusionFileURL: URL
  private var loadError: Error?
  private var pendingCaptureLoadError: Error?
  private var exclusionLoadError: Error?

  enum LabRecordProjectionError: Error, Equatable {
    case unreadable
  }

  enum EventRecordsReadError: Error, Equatable {
    case unreadableStore
    case invalidEventCode
  }

  init(fileURL: URL? = nil) {
    let resolvedFileURL = fileURL ?? Self.defaultFileURL()
    self.fileURL = resolvedFileURL
    self.pendingCaptureFileURL = resolvedFileURL.deletingPathExtension()
      .appendingPathExtension("pending.json")
    self.exclusionFileURL = resolvedFileURL.deletingPathExtension()
      .appendingPathExtension("exclusions.json")
    load()
    loadPendingCaptures()
    loadExclusions()
  }

  /// Reads the durable submission file without creating a submission client
  /// or starting the sender. Lab builds use this when submission is disabled.
  func labRecordProjection() -> Result<[LabRecordMetadata], LabRecordProjectionError> {
    guard loadError == nil else { return .failure(.unreadable) }
    return .success(records.compactMap { record in
      guard let eventId = record.eventIdHex else { return nil }
      return LabRecordMetadata(
        windowId: record.id.uuidString.lowercased(),
        eventId: eventId,
        observationDigest: record.observationDigestHex,
        status: record.submissionState.rawValue,
        receiptStored: record.acceptanceReceiptHex != nil,
        terminalError: boundedLabTerminalError(record.terminalErrorCode)
      )
    })
  }

  /// Read-only Event Detail projection. A failed load is unavailable, never
  /// an authoritative empty report list. Normalize by the same shared event
  /// code decision used by Proof grouping, including legacy Proof codes.
  func eventRecords(forEventCode eventCode: String) -> Result<[ReportSubmissionRecord], EventRecordsReadError> {
    guard loadError == nil else { return .failure(.unreadableStore) }
    guard let key = BeidSharedKit.event.normalizedEventCodeOrNull(rawEventCode: eventCode) else {
      return .failure(.invalidEventCode)
    }
    let matching = records.filter {
      BeidSharedKit.event.normalizedEventCodeOrNull(rawEventCode: $0.eventCode) == key
    }
    return .success(matching.sorted { left, right in
      if left.createdAt == right.createdAt {
        return left.id.uuidString < right.id.uuidString
      }
      return left.createdAt < right.createdAt
    })
  }

  private static func defaultFileURL() -> URL {
    let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    return directory.appendingPathComponent("report-submissions.json")
  }

  @discardableResult
  func add(_ record: ReportSubmissionRecord) throws -> ReportSubmissionRecord {
    try ensureWritable()
    if let existing = records.first(where: { $0.id == record.id }) {
      guard existing.hasSameObservationAndConfiguration(as: record) else {
        throw ReportSubmissionStoreError.conflictingObservation
      }
      return existing
    }

    let updated = records + [record]
    try persist(updated)
    records = updated
    return record
  }

  @discardableResult
  func addPendingCapture(_ capture: ReportSubmissionCapture) throws -> ReportSubmissionCapture {
    try ensureWritable()
    if let existing = pendingCaptures.first(where: { $0.id == capture.id }) {
      guard existing.hasSameWindowInputs(as: capture) else {
        throw ReportSubmissionStoreError.conflictingCapture
      }
      return existing
    }

    let updated = pendingCaptures + [capture]
    try persistPendingCaptures(updated)
    pendingCaptures = updated
    return capture
  }

  @discardableResult
  func addExclusion(_ exclusion: ReportSubmissionExclusion) throws -> ReportSubmissionExclusion {
    try ensureWritable()
    if let existing = exclusions.first(where: { $0.id == exclusion.id }) {
      guard existing.hasSameWindowInputs(as: exclusion) else {
        throw ReportSubmissionStoreError.conflictingExclusion
      }
      return existing
    }
    let updated = exclusions + [exclusion]
    try persistExclusions(updated)
    exclusions = updated
    return exclusion
  }

  func removePendingCapture(id: UUID) throws {
    try ensureWritable()
    guard let index = pendingCaptures.firstIndex(where: { $0.id == id }) else { return }
    var updated = pendingCaptures
    updated.remove(at: index)
    try persistPendingCaptures(updated)
    pendingCaptures = updated
  }

  func record(id: UUID) -> ReportSubmissionRecord? {
    records.first { $0.id == id }
  }

  var pendingRecords: [ReportSubmissionRecord] {
    records.filter {
      !$0.isReceiptStored && !$0.isTerminal && $0.submissionState != .accepted
    }
  }

  /// Durably advances PREPARED to SUBMITTING before a POST is started.
  /// Repeating the call for an already-submitting record is idempotent.
  @discardableResult
  func markSubmitting(for id: UUID) throws -> ReportSubmissionRecord {
    try ensureWritable()
    guard let index = records.firstIndex(where: { $0.id == id }) else {
      throw ReportSubmissionStoreError.missingObservation
    }
    guard records[index].terminalErrorCode == nil,
          records[index].acceptanceReceiptHex == nil
    else {
      throw ReportSubmissionStoreError.invalidState
    }
    guard records[index].submissionState == .prepared ||
      records[index].submissionState == .submitting
    else {
      throw ReportSubmissionStoreError.invalidState
    }
    guard records[index].submissionState != .submitting else {
      return records[index]
    }

    var updatedRecord = records[index]
    updatedRecord.submissionState = .submitting
    var updated = records
    updated[index] = updatedRecord
    try persist(updated)
    records = updated
    return updatedRecord
  }

  @discardableResult
  func storeReceipt(
    for id: UUID,
    signedReceiptHex: String
  ) throws -> ReportSubmissionRecord {
    try ensureWritable()
    guard !signedReceiptHex.isEmpty, signedReceiptHex.isEvenLengthHex else {
      throw ReportSubmissionStoreError.invalidReceipt
    }
    guard let index = records.firstIndex(where: { $0.id == id }) else {
      throw ReportSubmissionStoreError.missingObservation
    }
    guard records[index].terminalErrorCode == nil else {
      throw ReportSubmissionStoreError.invalidReceipt
    }
    if let existing = records[index].acceptanceReceiptHex {
      guard existing == signedReceiptHex else {
        throw ReportSubmissionStoreError.invalidReceipt
      }
      return records[index]
    }

    var updatedRecord = records[index]
    updatedRecord.acceptanceReceiptHex = signedReceiptHex
    updatedRecord.submissionState = .accepted
    var updated = records
    updated[index] = updatedRecord
    try persist(updated)
    records = updated
    return updatedRecord
  }

  @discardableResult
  func markTerminalFailure(
    for id: UUID,
    code: String
  ) throws -> ReportSubmissionRecord {
    try ensureWritable()
    guard !code.isEmpty, let index = records.firstIndex(where: { $0.id == id }) else {
      throw ReportSubmissionStoreError.missingObservation
    }
    if records[index].isReceiptStored || records[index].terminalErrorCode != nil {
      return records[index]
    }

    var updatedRecord = records[index]
    updatedRecord.terminalErrorCode = code
    var updated = records
    updated[index] = updatedRecord
    try persist(updated)
    records = updated
    return updatedRecord
  }

  private func ensureWritable() throws {
    if let loadError { throw loadError }
    if let pendingCaptureLoadError { throw pendingCaptureLoadError }
    if let exclusionLoadError { throw exclusionLoadError }
  }

  private func persist(_ records: [ReportSubmissionRecord]) throws {
    try persistEncoded(
      records,
      to: fileURL,
      stagingPrefix: ".report-submissions"
    )
  }

  private func persistPendingCaptures(_ captures: [ReportSubmissionCapture]) throws {
    try persistEncoded(
      captures,
      to: pendingCaptureFileURL,
      stagingPrefix: ".report-submission-captures"
    )
  }

  private func persistExclusions(_ exclusions: [ReportSubmissionExclusion]) throws {
    try persistEncoded(
      exclusions,
      to: exclusionFileURL,
      stagingPrefix: ".report-submission-exclusions"
    )
  }

  private func persistEncoded<Value: Encodable>(
    _ value: Value,
    to destinationURL: URL,
    stagingPrefix: String
  ) throws {
    try FileManager.default.createDirectory(
      at: destinationURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let data = try JSONEncoder().encode(value)
    let stagedURL = destinationURL.deletingLastPathComponent().appendingPathComponent(
      "\(stagingPrefix)-\(UUID().uuidString.lowercased()).tmp"
    )
    var stagedFileWasMoved = false
    defer {
      if !stagedFileWasMoved {
        try? FileManager.default.removeItem(at: stagedURL)
      }
    }
    try data.write(to: stagedURL)
    let handle = try FileHandle(forWritingTo: stagedURL)
    try handle.synchronize()
    try handle.close()
    let renameResult = stagedURL.path.withCString { stagedPath in
      destinationURL.path.withCString { destinationPath in
        Darwin.rename(stagedPath, destinationPath)
      }
    }
    guard renameResult == 0 else {
      throw NSError(
        domain: NSPOSIXErrorDomain,
        code: Int(errno),
        userInfo: [NSFilePathErrorKey: destinationURL.path]
      )
    }
    stagedFileWasMoved = true
  }

  private func load() {
    guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
    do {
      records = try JSONDecoder().decode(
        [ReportSubmissionRecord].self,
        from: Data(contentsOf: fileURL)
      )
    } catch {
      // Never replace an unreadable queue with an empty durable file. The
      // caller can surface this state and retry after the next process start.
      loadError = error
    }
  }

  private func loadPendingCaptures() {
    guard FileManager.default.fileExists(atPath: pendingCaptureFileURL.path) else { return }
    do {
      pendingCaptures = try JSONDecoder().decode(
        [ReportSubmissionCapture].self,
        from: Data(contentsOf: pendingCaptureFileURL)
      )
    } catch {
      pendingCaptureLoadError = error
    }
  }

  private func loadExclusions() {
    guard FileManager.default.fileExists(atPath: exclusionFileURL.path) else { return }
    do {
      exclusions = try JSONDecoder().decode(
        [ReportSubmissionExclusion].self,
        from: Data(contentsOf: exclusionFileURL)
      )
    } catch {
      // Latch the error so a later write cannot replace unreadable durable data.
      exclusionLoadError = error
    }
  }
}

private extension String {
  var isEvenLengthHex: Bool {
    count.isMultiple(of: 2) && allSatisfy {
      ($0 >= "0" && $0 <= "9") ||
        ($0 >= "a" && $0 <= "f") ||
        ($0 >= "A" && $0 <= "F")
    }
  }
}
