// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import Foundation

/// Drives screens 05 (Sensing) through 07 (Proof Collected), plus the 06d
/// Signal Lost branch.
enum ScanPhase: Equatable {
  case idle
  case sensing
  case eventFound(DemoEvent)
  case verifying(event: DemoEvent, peersVerified: Int)
  case verified(event: DemoEvent, peersVerified: Int)
  case signalLost(event: DemoEvent)
  case collected(Proof)
}
