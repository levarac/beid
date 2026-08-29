// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import XCTest
@testable import Beid

/// Direct tests of `DailyRollupRuntime`, the thin native adapter over
/// `BeidSharedKit.aggregation`'s day-rollup functions (gh#291). Every
/// expected value below is a literal derived independently of the adapter
/// or the shared function under test — never a second call to either — so a
/// broken day-boundary comparison in `DayRollup.kt` cannot survive
/// undetected by agreeing with itself on both sides of an assertion.
///
/// Uses a fixed UTC `Calendar` and a fixed `now` throughout so results do
/// not depend on the host machine's timezone or the date the suite happens
/// to run on.
final class DailyRollupRuntimeTests: XCTestCase {
  private var utcCalendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
  }

  /// 2024-03-10T15:00:00Z — an arbitrary weekday, well clear of any DST
  /// edge (this suite fixes the day boundary itself; `DayRollupWindow`'s own
  /// DST-safety is a property of `Calendar.date(byAdding: .day, ...)`, which
  /// `DailyRollupRuntime` uses instead of a fixed 86,400,000ms offset — see
  /// its doc comment).
  private var fixedNow: Date {
    utcCalendar.date(from: DateComponents(year: 2024, month: 3, day: 10, hour: 15))!
  }

  func testRecordAtExactlyMidnightStartCountsAsToday() {
    let calendar = utcCalendar
    let dayStart = calendar.startOfDay(for: fixedNow)
    let proofAtStart = Proof(eventName: "At start", date: dayStart, peersVerified: 0)

    let result = DailyRollupRuntime.recordsToday(in: [proofAtStart], calendar: calendar, now: fixedNow)

    XCTAssertEqual(result, [proofAtStart])
  }

  func testRecordOneSecondBeforeMidnightIsYesterdayNotToday() {
    let calendar = utcCalendar
    let dayStart = calendar.startOfDay(for: fixedNow)
    let proofYesterday = Proof(
      eventName: "Yesterday",
      date: dayStart.addingTimeInterval(-1),
      peersVerified: 0
    )

    let result = DailyRollupRuntime.recordsToday(in: [proofYesterday], calendar: calendar, now: fixedNow)

    XCTAssertEqual(result, [])
  }

  /// The exact instant at the *next* midnight belongs to tomorrow, not
  /// today — this is the specific half-open-interval edge case
  /// `DayRollupWindow`'s doc comment calls out.
  func testRecordAtExactlyTheNextMidnightIsTomorrowNotToday() {
    let calendar = utcCalendar
    let dayStart = calendar.startOfDay(for: fixedNow)
    let nextDayStart = calendar.date(byAdding: .day, value: 1, to: dayStart)!
    let proofAtNextMidnight = Proof(eventName: "Next midnight", date: nextDayStart, peersVerified: 0)

    let result = DailyRollupRuntime.recordsToday(
      in: [proofAtNextMidnight],
      calendar: calendar,
      now: fixedNow
    )

    XCTAssertEqual(result, [])
  }

  /// A mixed fixture, both proving the filter and proving order/identity:
  /// only the two "today" proofs come back, in their original relative
  /// order, as the exact same values passed in (not re-derived copies).
  func testMixedFixtureReturnsOnlyTodaysProofsInOriginalOrder() {
    let calendar = utcCalendar
    let dayStart = calendar.startOfDay(for: fixedNow)
    let nextDayStart = calendar.date(byAdding: .day, value: 1, to: dayStart)!

    let proofYesterday = Proof(
      eventName: "Yesterday",
      date: dayStart.addingTimeInterval(-1),
      peersVerified: 0
    )
    let proofEarlyToday = Proof(eventName: "Early today", date: dayStart, peersVerified: 1)
    let proofLateToday = Proof(
      eventName: "Late today",
      date: dayStart.addingTimeInterval(20 * 3_600),
      peersVerified: 2
    )
    let proofTomorrow = Proof(eventName: "Tomorrow", date: nextDayStart, peersVerified: 3)

    let result = DailyRollupRuntime.recordsToday(
      in: [proofYesterday, proofEarlyToday, proofLateToday, proofTomorrow],
      calendar: calendar,
      now: fixedNow
    )

    XCTAssertEqual(result, [proofEarlyToday, proofLateToday])
  }

  func testEmptyProofListReturnsEmptyResult() {
    let result = DailyRollupRuntime.recordsToday(in: [], calendar: utcCalendar, now: fixedNow)

    XCTAssertEqual(result, [])
  }
}
