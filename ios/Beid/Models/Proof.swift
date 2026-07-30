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

  init(
    id: UUID = UUID(),
    eventName: String,
    date: Date,
    method: String = "Bluetooth Sensing",
    peersVerified: Int,
    gradientSeed: Int? = nil,
    signatureState: ProofSignatureState = .notRequested
  ) {
    self.id = id
    self.eventName = eventName
    self.date = date
    self.method = method
    self.peersVerified = peersVerified
    self.gradientSeed = gradientSeed ?? eventName.hashValue
    self.signatureState = signatureState
  }

  private enum CodingKeys: String, CodingKey {
    case id, eventName, date, method, peersVerified, gradientSeed, signatureState
  }

  /// Custom `init(from:)` so proofs persisted before `signatureState`
  /// existed keep decoding instead of tripping `ProofStore.load()`'s
  /// broad `try?` and silently discarding every previously stored proof.
  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(UUID.self, forKey: .id)
    eventName = try container.decode(String.self, forKey: .eventName)
    date = try container.decode(Date.self, forKey: .date)
    method = try container.decode(String.self, forKey: .method)
    peersVerified = try container.decode(Int.self, forKey: .peersVerified)
    gradientSeed = try container.decode(Int.self, forKey: .gradientSeed)
    signatureState = try container.decodeIfPresent(ProofSignatureState.self, forKey: .signatureState) ?? .notRequested
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
  }
}
