// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import Foundation

/// Centralized, app-wide protocol/UX constants — see
/// `docs/specs/scan-slice2-redesign.md` §4.4.
enum BeidConfig {
  /// Distinct devices that must be present **in one ENIN window** before
  /// `SensingCoordinator` auto-transitions `.eventFound → .recording`
  /// (D3, background-capable, zero-tap).
  ///
  /// Counted from the window's proximity identifiers, which do not rotate
  /// inside a window, so this needs no display id and survives a total
  /// Barnard B003 outage — see
  /// `SensingCoordinator.hasEnoughCoPresentDevicesToConfirm`. It asks whether
  /// enough devices were here *at once*, which is a stricter question than a
  /// session-wide device total, and a different one from the
  /// `devicesVerified` figure that lands in the signed proof.
  ///
  /// The old wording here said "mutual-sensing peer observations". None of
  /// those three words survived: the app cannot tell whether a peer sensed it
  /// back, and this counts devices rather than observations (beid#154).
  ///
  /// A single named constant so the
  /// later rework to a per-event, organizer-configurable value
  /// (`event.confirmThreshold ?? BeidConfig.eventConfirmThreshold`) is a
  /// one-line, one-call-site change.
  static var eventConfirmThreshold: Int {
    #if DEBUG
    let args = ProcessInfo.processInfo.arguments
    if let flagIndex = args.firstIndex(of: "-beid-threshold-override"),
       args.indices.contains(flagIndex + 1),
       let override = Int(args[flagIndex + 1]) {
      return override
    }
    #endif
    return 3
  }
}
