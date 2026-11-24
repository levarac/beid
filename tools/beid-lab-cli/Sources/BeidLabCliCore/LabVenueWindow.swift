// SPDX-License-Identifier: MIT

import Foundation

/// The wall-clock bounds `venue_ready` prints for a B005 v2 envelope, so an
/// operator in a room can compare them with a watch instead of ENIN numbers.
///
/// Phones accept an envelope while `validFromEnin <= currentEnin <
/// relayExpiresAtEnin` (Barnard spec 134), so the last second worth serving it
/// is the one before `relayExpiresAtEnin` begins. `validThroughEnin` is the
/// envelope's outer bound and can end later; serving by it hands phones an
/// envelope they already refuse.
public enum LabVenueWindow {
  /// First second of `validFromEnin`.
  public static func validFromUnix(validFromEnin: Int64, eninSeconds: Int64) -> Int64 {
    validFromEnin * eninSeconds
  }

  /// Last second phones accept the envelope.
  public static func acceptedThroughUnix(relayExpiresAtEnin: Int64, eninSeconds: Int64) -> Int64 {
    relayExpiresAtEnin * eninSeconds - 1
  }

  /// Last second of `validThroughEnin`.
  public static func validThroughUnix(validThroughEnin: Int64, eninSeconds: Int64) -> Int64 {
    (validThroughEnin + 1) * eninSeconds - 1
  }
}
