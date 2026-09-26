// SPDX-License-Identifier: MIT

import Foundation

/// What the shell sees.
///
/// The tool is driven over ssh from a room where a measurement is running, so
/// the exit code has to carry the verdict on its own: an operator should not
/// have to parse JSON to find out whether a run failed or the host needs
/// attention. The split is the Barnard lab runner's, kept deliberately
/// identical so one orchestrator can judge both.
enum LabExit: Int32 {
  /// The run did what it was asked for the whole window.
  case ok = 0
  /// Arguments, a missing file, or an interrupt. The radio produced no
  /// verdict.
  case harness = 1
  /// The radio worked and the expectation was not met in time. Only
  /// `participate --expect-peers` can produce this: `observe` and `venue`
  /// have no rendezvous to miss.
  case expectationNotMet = 2
  /// Bluetooth is denied, restricted, powered off, unsupported, or the
  /// one-time grant has not been made on this host. Not a result about the
  /// radio — a host that needs a person.
  case bluetoothUnavailable = 3
}
