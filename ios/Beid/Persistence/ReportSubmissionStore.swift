// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import Darwin
import Foundation

enum ReportSubmissionStoreError: Error {
  case conflictingObservation
  case missingObservation
  case invalidReceipt
  case invalidState
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
    submissionState: ReportSubmissionState = .prepared,
    acceptanceReceiptHex: String? = nil,
    terminalErrorCode: String? = nil,
    createdAt: Date = Date()
  ) {
    self.id = id
    self.eventCode = eventCode
    self.endpoint = endpoint
    self.receiptPublicKeyHex = receiptPublicKeyHex
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

  private let fileURL: URL
  private var loadError: Error?

  init(fileURL: URL? = nil) {
    self.fileURL = fileURL ?? Self.defaultFileURL()
    load()
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
  }

  private func persist(_ records: [ReportSubmissionRecord]) throws {
    try FileManager.default.createDirectory(
      at: fileURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let data = try JSONEncoder().encode(records)
    let stagedURL = fileURL.deletingLastPathComponent().appendingPathComponent(
      ".report-submissions-\(UUID().uuidString.lowercased()).tmp"
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
      fileURL.path.withCString { destinationPath in
        Darwin.rename(stagedPath, destinationPath)
      }
    }
    guard renameResult == 0 else {
      throw NSError(
        domain: NSPOSIXErrorDomain,
        code: Int(errno),
        userInfo: [NSFilePathErrorKey: fileURL.path]
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
