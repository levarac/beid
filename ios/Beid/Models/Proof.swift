// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import Foundation

/// A locally collected proof of attendance. No server or chain calls in this
/// slice — proofs live only in `ProofStore`'s on-device JSON file.
struct Proof: Identifiable, Codable, Hashable {
  let id: UUID
  let eventName: String
  let date: Date
  let method: String
  let peersVerified: Int
  let gradientSeed: Int

  init(
    id: UUID = UUID(),
    eventName: String,
    date: Date,
    method: String = "Bluetooth Sensing",
    peersVerified: Int,
    gradientSeed: Int? = nil
  ) {
    self.id = id
    self.eventName = eventName
    self.date = date
    self.method = method
    self.peersVerified = peersVerified
    self.gradientSeed = gradientSeed ?? eventName.hashValue
  }
}
