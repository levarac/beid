// Copyright (c) 2024-2026 Levarac Foundation
// SPDX-License-Identifier: MIT

import Foundation

/// A locally signed per-ENIN-window sensing report (Q9,
/// `docs/specs/scan-slice2-redesign.md` §4.5). Signed by the event signing
/// key (`BarnardIdentity.sign(eventCode:bytes:)`), queued on-device — no
/// network transport or batch/anchor pipeline exists yet; that is separate
/// downstream work (`docs/specs/scan-protocol-model.md` §9).
struct WindowReport: Identifiable, Codable, Equatable {
  let id: UUID
  let eventCode: String
  let enin: Int
  /// Distinct peer RPIDs observed during this window.
  let peerCount: Int
  /// `EventCommitment.compute(...)`, hex-encoded — the opaque per-event
  /// identity commitment this report is filed under.
  let commitHex: String
  let signatureRHex: String
  let signatureSHex: String
  let signatureV: Int
  let signedAt: Date

  init(
    id: UUID = UUID(),
    eventCode: String,
    enin: Int,
    peerCount: Int,
    commit: Data,
    signature: SensingRecoverableSignature,
    signedAt: Date = Date()
  ) {
    self.id = id
    self.eventCode = eventCode
    self.enin = enin
    self.peerCount = peerCount
    self.commitHex = commit.hexString
    self.signatureRHex = signature.r.hexString
    self.signatureSHex = signature.s.hexString
    self.signatureV = signature.v
    self.signedAt = signedAt
  }
}

private extension Data {
  var hexString: String {
    map { String(format: "%02x", $0) }.joined()
  }
}
