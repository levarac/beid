// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import Foundation

/// Shapes for driving `SensingCoordinator.handleDetection(enin:rpid:detectedDisplayId:)`
/// in tests.
///
/// Barnard's real `detectedDisplayId` is `SHA256(TEK)[0:4]` rendered as 8
/// lowercase hex characters, read from the B003 GATT characteristic. These
/// helpers produce values in that shape so a test that says "same device" is
/// saying it in the same alphabet production uses — a test that passed a
/// human-readable token would not exercise the normalization the coordinator
/// applies.
enum DetectionFixture {
  /// A stable 8-hex-character display id for the nth simulated device. Stable
  /// across ENIN windows by construction, exactly like the real value: it is
  /// derived from the per-event key, which does not rotate.
  static func displayId(device index: Int) -> String {
    String(format: "%08x", UInt32(truncatingIfNeeded: 0xbe1d_0000 &+ index))
  }

  /// A rotating proximity identifier for the nth device in the given ENIN
  /// window. Distinct per (device, window) pair, mirroring the real RPI, which
  /// changes every window.
  static func rotatingRpid(device index: Int, enin: Int) -> String {
    "rpid-device-\(index)-enin-\(enin)"
  }
}
