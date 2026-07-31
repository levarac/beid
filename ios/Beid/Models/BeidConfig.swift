// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import Foundation

/// Centralized, app-wide protocol/UX constants — see
/// `docs/specs/scan-slice2-redesign.md` §4.4.
enum BeidConfig {
  /// Distinct mutual-sensing peer observations required before
  /// `SensingCoordinator` auto-transitions `.eventFound → .recording`
  /// (D3, background-capable, zero-tap). A single named constant so the
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
