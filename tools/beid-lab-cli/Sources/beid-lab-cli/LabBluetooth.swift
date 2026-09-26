// SPDX-License-Identifier: MIT

import CoreBluetooth
import Foundation

/// Why the radio could not have worked, in words an operator reading an ssh
/// transcript can act on.
///
/// Separated from the runners because the distinction it draws is the same
/// for all three and is easy to get subtly wrong: a run that could not use
/// the radio has produced **no result about the radio**, and reporting it as
/// a failed measurement would put a number in a report that means nothing.
/// Exit code 3 exists to keep those apart.
enum LabBluetooth {
  /// A one-time grant that has not been answered is the expected shape of a
  /// host nobody has set up yet, not a radio failure — and the prompt can
  /// still be answered while the run is going, so this case does not end a
  /// run on its own.
  static func blocker(managerStates: [CBManagerState] = []) -> String? {
    switch CBManager.authorization {
    case .denied:
      return "bluetooth permission denied for \(LabBundle.identifier)"
    case .restricted:
      return "bluetooth permission restricted for \(LabBundle.identifier)"
    case .notDetermined:
      return
        "bluetooth permission not determined for \(LabBundle.identifier); the one-time grant has not been made on this host"
    default:
      break
    }
    for state in managerStates {
      switch state {
      case .poweredOff: return "bluetooth is powered off"
      case .unsupported: return "bluetooth is unsupported on this host"
      case .unauthorized: return "bluetooth is unauthorized for this process"
      default: continue
      }
    }
    return nil
  }

  static var authorizationIsUndecided: Bool {
    CBManager.authorization == .notDetermined
  }

  static func name(for state: CBManagerState) -> String {
    switch state {
    case .unknown: return "unknown"
    case .resetting: return "resetting"
    case .unsupported: return "unsupported"
    case .unauthorized: return "unauthorized"
    case .poweredOff: return "poweredOff"
    case .poweredOn: return "poweredOn"
    @unknown default: return "unrecognised"
    }
  }
}
