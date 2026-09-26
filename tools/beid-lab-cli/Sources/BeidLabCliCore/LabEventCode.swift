// SPDX-License-Identifier: MIT

import Foundation

/// The string `participate` hands `BarnardEngine.joinEvent`, and how to tell
/// a usable one from the mistake that has already cost a measurement window.
///
/// ## The join string is the Event ID, not the code a human was told
///
/// beid does not join with the event code an operator types. `shared/`'s
/// `RegistryVerifiedJoinContext` carries a `joinCode` field documented as
/// "the exact string the native adapter hands `BarnardEngine.joinEvent`", and
/// both of its construction paths set it to `canonicalEventIdHex` — the
/// 32-byte Event ID rendered as 64 lowercase hex characters with no `0x`,
/// which is what that file's `normalizedHexOrNull` produces. Its own doc says
/// it outright: *the operator's human code remains a lookup/UI input only.*
///
/// Barnard then derives B004 as the first eight bytes of SHA-256 over the
/// UTF-8 bytes of whatever string it was handed
/// (`BarnardCoreCrypto.computeEventCodeHash`, v0.9.2). And the definition
/// side computes the same value from the Event ID directly
/// (`BarnardB005EnvelopeV2.openEventCodeHash`, which hex-renders the id and
/// hashes that). The two agree by construction — but only if the join string
/// really was the Event ID hex.
///
/// ## Why this file exists rather than a line in the README
///
/// On 2026-09-17 a lab run joined with `parallax-sepolia-20260917-05`, the
/// operator lookup code. Every layer behaved correctly: the Mac derived B004
/// from the string it was given, the phones derived theirs from the Event ID,
/// the values differed, and `BarnardEngine` discarded the peer at its gate
/// before reading B002 — so no detection was emitted and no phone's count
/// moved. Nothing errored. The run simply produced nothing, which looks
/// exactly like a run where nobody was in the room.
///
/// A failure mode that costs a measurement window and reports success is
/// worth a type and a warning, not a sentence somebody reads afterwards.
public enum LabEventCode {
  /// A canonical Event ID is 32 bytes.
  public static let eventIdHexLength = 64

  /// Normalises an Event ID to the exact string beid hands the engine:
  /// lowercase, no `0x`, 64 hex characters. Mirrors `shared/`'s
  /// `normalizedHexOrNull` for this one length.
  ///
  /// Returns nil for anything that is not a 32-byte hex value, because a
  /// join string that is *nearly* an Event ID is not a near miss on the wire
  /// — it hashes to something unrelated.
  public static func joinString(forEventIdHex raw: String) -> String? {
    let body = raw.hasPrefix("0x") || raw.hasPrefix("0X") ? String(raw.dropFirst(2)) : raw
    guard body.count == eventIdHexLength, LabRedaction.isHex(body) else { return nil }
    return body.lowercased()
  }

  /// Whether a string has the shape beid actually puts on the wire.
  ///
  /// Case is part of the answer, not a detail: what gets hashed is the
  /// characters, so `9F` and `9f` are different join strings with different
  /// B004 values. An uppercase Event ID of the right length is still wrong.
  public static func looksCanonical(_ joinString: String) -> Bool {
    joinString.count == eventIdHexLength
      && LabRedaction.isHex(joinString)
      && joinString.lowercased() == joinString
  }

  /// What to tell an operator whose join string is not an Event ID.
  ///
  /// It has to name the flag to use instead. An operator who learns only
  /// that something is wrong is no better off than the one who lost the
  /// 2026-09-17 window.
  public static let nonCanonicalWarning =
    "beid joins with the canonical Event ID as 64 lowercase hex characters, not with the "
    + "operator's lookup code, so B004 will not match the phones: BarnardEngine discards every "
    + "peer at its gate, no detection is emitted, and the run looks exactly like an empty room. "
    + "Pass --event-id <hex>, or --container <path> to take it from a signed container."

  /// Said on a run that was told to go ahead anyway.
  public static let syntheticRehearsalNote =
    "joining with a non-canonical string on purpose: this run cannot move any phone's count, "
    + "which is what makes it safe to rehearse beside a live measurement."
}
