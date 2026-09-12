// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import Foundation

/// The first production supplier of `VenueClockReading`. Nothing in `ios/Beid`
/// constructed one before beid#432's entry point.
///
/// This is a conservative placeholder, not a preflight: it declares the
/// device clock unavailable only when it reads earlier than a fixed sanity
/// floor (this repo's own commit date), which catches a device whose clock
/// was never set or was reset to an implausible past. It does NOT attempt to
/// detect a clock that is wrong in more subtle ways (skewed but plausible,
/// or manually set forward) -- beid#464 is the named future preflight that
/// takes on that job, for example by corroborating against a trusted network
/// time source. `.unavailable` must stay reachable rather than dead code, so
/// the floor exists specifically to keep it reachable on a real device
/// (factory-reset devices and simulators without network time frequently
/// boot at 2001-01-01) while still passing through every normal reading.
enum VenueDeviceClock {
  /// 2025-09-04T00:00:00Z, a date safely before this feature's development
  /// began. Any device clock reading earlier than this is treated as
  /// unavailable rather than trusted to bound a signed permit's deadline.
  static let sanityFloorUnixSeconds: Int64 = 1_756_944_000

  static func read(now: () -> Date = Date.init) -> VenueClockReading {
    let seconds = Int64(now().timeIntervalSince1970)
    guard seconds >= sanityFloorUnixSeconds else { return .unavailable }
    return .available(unixSeconds: seconds)
  }
}
