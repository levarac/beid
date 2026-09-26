// SPDX-License-Identifier: MIT

import Foundation

/// The single gate every identifier and byte string passes through before it
/// reaches the log.
///
/// It is a type rather than a convention because the alternative — each call
/// site remembering the rule — is how the Barnard lab runner ends up printing
/// raw RPIDs: its debug mapping forwards every JSON-valid field the engine
/// emits, so a new field is logged in full the day it is added. Nothing here
/// is forwarded; a value is logged because a call site named it.
///
/// The rule (issue #588, as amended by Ken on 2026-09-17): key material never
/// appears at any level; an RPID appears in full only at `trace` and as a
/// short prefix everywhere else.
public enum LabRedaction {
  /// Enough to correlate two lines about the same peer within one run, and
  /// not enough to be an identifier outside it.
  public static let rpidPrefixLength = 4

  /// Marks a value as cut short, so a reader never mistakes a prefix for a
  /// whole value.
  public static let redactionMarker = "..."

  public static func rpid(_ value: String, at level: LabLogLevel) -> String {
    guard level != .trace else { return value }
    return String(value.prefix(rpidPrefixLength)) + redactionMarker
  }

  /// The run's event label: the first 8 hex characters of an event id, which
  /// is what issue #588 asks every line to carry.
  ///
  /// Returns nil for anything that is not hex, so a typo is refused at
  /// argument time rather than labelling a whole run with nonsense.
  public static func eventIdPrefix(_ raw: String) -> String? {
    let body = raw.hasPrefix("0x") || raw.hasPrefix("0X") ? String(raw.dropFirst(2)) : raw
    guard body.count >= 8, isHex(body) else { return nil }
    return String(body.prefix(8)).lowercased()
  }

  /// Raw bytes for a field that carries no secret, offered only at `trace`.
  /// Below that it is `.null` rather than absent, so the field set of a stage
  /// does not change with the level.
  public static func rawBytes(_ bytes: [UInt8], at level: LabLogLevel) -> LabValue {
    level == .trace ? .string(hex(bytes)) : .null
  }

  public static func hex(_ bytes: [UInt8]) -> String {
    bytes.map { String(format: "%02x", $0) }.joined()
  }

  public static func isHex(_ value: String) -> Bool {
    !value.isEmpty && value.allSatisfy { $0.isHexDigit && $0.isASCII }
  }
}
