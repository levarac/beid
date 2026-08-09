// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import Foundation

/// A locally collected proof of attendance. No server or chain calls in this
/// slice — proofs live only in `ProofStore`'s on-device JSON file.
/// `signatureState` is optional enrichment (see `ProofSignatureState`): a
/// proof is stored the instant BLE evidence resolves, regardless of it.
struct Proof: Identifiable, Codable, Hashable {
  let id: UUID
  let eventName: String
  let date: Date
  let method: String
  /// `var`, not `let`: under the merged `.recording` phase this grows in
  /// place while a proof is being recorded — see `ProofStore
  /// .updatePeersVerified(for:to:)` and `docs/specs/scan-slice2-redesign.md`
  /// §4.6.
  var peersVerified: Int
  let gradientSeed: Int
  var signatureState: ProofSignatureState
  /// The event join code this proof was recorded under (beid#137, DECISIONS
  /// 2026-08-09 "#137 は履歴スコープを採り、Proof に eventCode を optional で追加
  /// する"). `nil` for any proof persisted before this field existed —
  /// `Proof.init(from:)` already tolerates a *missing field* the same way
  /// it does for `signatureState` below (`decodeIfPresent`, no schema
  /// version marker). This is deliberately `String?`, never a required
  /// field, and deliberately decoded with `decodeIfPresent`, never by
  /// adding a case to an existing enum: `Proof.init(from:)` tolerates a
  /// missing *field* today but not an unknown *enum case*, and this stays
  /// inside that documented tolerance rather than widening it. See beid#155
  /// for the still-open, general schema-versioning question this does not
  /// attempt to solve. Used by `TransparencyView`'s "Recorded on device"
  /// row to filter `WindowReportStore.reports`; `nil` here means that row
  /// renders as "not yet available," the same honest-gap treatment as the
  /// rows that have no data source at all yet — never a false zero.
  let eventCode: String?

  init(
    id: UUID = UUID(),
    eventName: String,
    date: Date,
    method: String = "Bluetooth Sensing",
    peersVerified: Int,
    gradientSeed: Int? = nil,
    signatureState: ProofSignatureState = .notRequested,
    eventCode: String? = nil
  ) {
    self.id = id
    self.eventName = eventName
    self.date = date
    self.method = method
    self.peersVerified = peersVerified
    self.gradientSeed = gradientSeed ?? eventName.hashValue
    self.signatureState = signatureState
    self.eventCode = eventCode
  }

  private enum CodingKeys: String, CodingKey {
    case id, eventName, date, method, peersVerified, gradientSeed, signatureState, eventCode
  }

  /// Custom `init(from:)` so proofs persisted before `signatureState` or
  /// `eventCode` existed keep decoding instead of tripping
  /// `ProofStore.load()`'s broad `try?` and silently discarding every
  /// previously stored proof.
  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(UUID.self, forKey: .id)
    eventName = try container.decode(String.self, forKey: .eventName)
    date = try container.decode(Date.self, forKey: .date)
    method = try container.decode(String.self, forKey: .method)
    peersVerified = try container.decode(Int.self, forKey: .peersVerified)
    gradientSeed = try container.decode(Int.self, forKey: .gradientSeed)
    signatureState = try container.decodeIfPresent(ProofSignatureState.self, forKey: .signatureState) ?? .notRequested
    eventCode = try container.decodeIfPresent(String.self, forKey: .eventCode)
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encode(eventName, forKey: .eventName)
    try container.encode(date, forKey: .date)
    try container.encode(method, forKey: .method)
    try container.encode(peersVerified, forKey: .peersVerified)
    try container.encode(gradientSeed, forKey: .gradientSeed)
    try container.encode(signatureState, forKey: .signatureState)
    try container.encodeIfPresent(eventCode, forKey: .eventCode)
  }
}
