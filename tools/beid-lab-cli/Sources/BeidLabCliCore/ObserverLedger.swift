// SPDX-License-Identifier: MIT

import Foundation

/// What the ledger decided about one sighting or one sweep.
public enum ObserverOutcome: Equatable, Sendable {
  /// A peripheral that was not being tracked is now being tracked. Emitted
  /// again when a peripheral returns after a loss, because a restart is the
  /// event dispatch#66 is looking for, not a continuation.
  case firstSeen(id: String, at: TimeInterval, rssi: Int)
  /// A tracked peripheral is still there, at most once per `repeatEvery`.
  case seen(id: String, at: TimeInterval, rssi: Int)
  /// Nothing has arrived from a tracked peripheral for `lostAfter`.
  case lost(id: String, lastSeenAt: TimeInterval, at: TimeInterval)
}

/// Turns a stream of advertisement sightings into intervals.
///
/// dispatch#66 asks when a venue stopped emitting, and a stop produces
/// nothing to observe: it is an absence. So the measurement is this reducer's
/// `lost` output — a deadline that expires — rather than anything the radio
/// hands over. `lastSeenAt` on that outcome is the answer to the question;
/// `at` is only when the deadline fell due.
///
/// Pure and clock-free on purpose: it takes every instant as an argument, so
/// the edges that matter can be tested without a radio or a real ten seconds.
public struct ObserverLedger {
  /// Quiet time after which a tracked peripheral is declared lost.
  public let lostAfter: TimeInterval
  /// Minimum gap between two printed lines about the same peripheral. Zero
  /// prints every sighting.
  public let repeatEvery: TimeInterval

  private struct Tracked {
    var lastSeenAt: TimeInterval
    var lastReportedAt: TimeInterval
  }

  private var tracked: [String: Tracked] = [:]
  private var everSeen: Set<String> = []

  public init(lostAfter: TimeInterval, repeatEvery: TimeInterval) {
    self.lostAfter = lostAfter
    self.repeatEvery = repeatEvery
  }

  /// Distinct peripherals seen at any point in the run, including ones
  /// already declared lost.
  public var distinctPeripheralCount: Int { everSeen.count }

  /// Peripherals currently inside their quiet window.
  public var activePeripheralCount: Int { tracked.count }

  public mutating func observe(
    peripheral: String, at instant: TimeInterval, rssi: Int
  ) -> [ObserverOutcome] {
    everSeen.insert(peripheral)
    guard var entry = tracked[peripheral] else {
      tracked[peripheral] = Tracked(lastSeenAt: instant, lastReportedAt: instant)
      return [.firstSeen(id: peripheral, at: instant, rssi: rssi)]
    }
    // The freshness update happens whether or not a line is printed. Letting
    // the rate limit move the loss deadline would report a peripheral seen
    // every second as lost every tenth.
    entry.lastSeenAt = instant
    guard instant - entry.lastReportedAt >= repeatEvery else {
      tracked[peripheral] = entry
      return []
    }
    entry.lastReportedAt = instant
    tracked[peripheral] = entry
    return [.seen(id: peripheral, at: instant, rssi: rssi)]
  }

  /// Declares every peripheral whose quiet window has elapsed.
  ///
  /// Sorted by identifier so a run is reproducible line for line; dictionary
  /// order is not, and a log that reorders between runs cannot be diffed.
  public mutating func sweep(at instant: TimeInterval) -> [ObserverOutcome] {
    let expired = tracked.filter { instant - $0.value.lastSeenAt > lostAfter }
    for id in expired.keys { tracked.removeValue(forKey: id) }
    return expired.keys.sorted().map {
      .lost(id: $0, lastSeenAt: expired[$0]!.lastSeenAt, at: instant)
    }
  }

  /// Closes every still-open interval at the end of the run.
  ///
  /// Without this a peripheral that was still advertising when the window
  /// ended has a start and no end, and the log cannot be read as intervals at
  /// all — which is the only way to read it for dispatch#66.
  public mutating func closeOut(at instant: TimeInterval) -> [ObserverOutcome] {
    let remaining = tracked
    tracked.removeAll()
    return remaining.keys.sorted().map {
      .lost(id: $0, lastSeenAt: remaining[$0]!.lastSeenAt, at: instant)
    }
  }
}
