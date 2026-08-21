// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import Foundation

enum ReportSubmissionStoreError: Error {
  case conflictingObservation
  case missingObservation
  case invalidReceipt
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
    self.acceptanceReceiptHex = acceptanceReceiptHex
    self.terminalErrorCode = terminalErrorCode
    self.createdAt = createdAt
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
    records.filter { !$0.isReceiptStored && !$0.isTerminal }
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
      ".report-submissions-(UUID().uuidString.lowercased()).tmp"
    )
    defer { try? FileManager.default.removeItem(at: stagedURL) }
    try data.write(to: stagedURL)
    let handle = try FileHandle(forWritingTo: stagedURL)
    try handle.synchronize()
    try handle.close()
    if FileManager.default.fileExists(atPath: fileURL.path) {
      try FileManager.default.replaceItemAt(fileURL, withItemAt: stagedURL)
    } else {
      try FileManager.default.moveItem(at: stagedURL, to: fileURL)
    }
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
