// Copyright (c) 2024-2026 Levarac Foundation
// SPDX-License-Identifier: MIT

import BeidSharedKit
import Foundation

/// Thin adapter over shared's day-rollup API (`BeidSharedKit.aggregation`,
/// gh#291). Maps native `Proof`s to shared's input shape, calls shared once,
/// and maps the result back to the matching `Proof`s themselves — never a
/// second, native re-derivation of "which proofs are today's."
///
/// This is deliberately the *only* place that decides which proofs are
/// "today's": `DailySummaryView` must not separately filter `proof.date`
/// with `Calendar.isDateInToday` or similar to build its own row list,
/// because that would be a second native implementation of the exact
/// decision this adapter routes through shared — the ownership-boundary
/// violation AGENTS.md warns about. The record *count* is always
/// `recordsToday(...).count`, never computed independently.
///
/// Native's job here is exactly "what is today, in this device's calendar
/// and timezone" — resolved with `Calendar.date(byAdding: .day, ...)`, not a
/// fixed 86,400,000ms offset, so a DST-transition day (23 or 25 hours) still
/// produces a correct boundary. See `DayRollupWindow`'s doc comment in
/// `shared/.../aggregation/DayRollup.kt` for the full invariant this relies
/// on.
enum DailyRollupRuntime {
  /// `proofs` sorted by native record index, matching the order `recordIndex`
  /// was assigned in — callers read the result back against this same array.
  static func recordsToday(
    in proofs: [Proof],
    calendar: Calendar = .current,
    now: Date = Date()
  ) -> [Proof]? {
    let startOfDay = calendar.startOfDay(for: now)
    guard let startOfNextDay = calendar.date(byAdding: .day, value: 1, to: startOfDay) else {
      return nil
    }
    guard let window = BeidSharedKit.aggregation.dayRollupWindow(
      startEpochMillisInclusive: Int64(startOfDay.timeIntervalSince1970 * 1000),
      endEpochMillisExclusive: Int64(startOfNextDay.timeIntervalSince1970 * 1000)
    ) else {
      return nil
    }

    let input = BeidSharedKit.aggregation.createDayRollupInput()
    for (index, proof) in proofs.enumerated() {
      BeidSharedKit.aggregation.addDayRollupRecord(
        input: input,
        recordIndex: Int32(index),
        epochMillis: Int64(proof.date.timeIntervalSince1970 * 1000)
      )
    }

    let result = BeidSharedKit.aggregation.rollupRecordsForDay(input: input, window: window)
    var matched: [Proof] = []
    matched.reserveCapacity(Int(result.recordCount))
    for position in 0..<Int(result.recordCount) {
      guard let match = result.matchAt(position: Int32(position)) else { continue }
      matched.append(proofs[Int(match.recordIndex)])
    }
    return matched
  }
}
