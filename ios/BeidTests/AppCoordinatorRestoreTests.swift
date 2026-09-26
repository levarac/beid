// Copyright (c) 2024-2026 Levarac Foundation
// SPDX-License-Identifier: MIT

import XCTest
@testable import Beid

/// Covers #194: a device that has already completed onboarding must not
/// restart at `.welcome` on cold launch.
@MainActor
final class AppCoordinatorRestoreTests: XCTestCase {
  /// A defaults store nothing else in the process can see.
  ///
  /// **`beid.hasCompletedOnboarding` in `UserDefaults.standard` is shared
  /// mutable state across every test in this target**, and writing it is not
  /// the passive act it looks like: an `AppCoordinator` constructed while it
  /// is set re-drives `restoreAfterOnboarding()` →
  /// `requestBluetoothPermission()` → `evaluateBluetoothState()`, which sets
  /// the key *again*, asynchronously, from whichever test happens to be
  /// running. These tests used to set it on `.standard` and hold it set for
  /// up to twenty seconds while polling, which is the window beid#393 was
  /// escalated for.
  ///
  /// Each test gets its own suite, so ordering cannot matter.
  private func isolatedDefaults(
    _ function: StaticString = #function
  ) -> UserDefaults {
    UserDefaults(
      suiteName: "AppCoordinatorRestoreTests.\(function).\(UUID().uuidString)"
    )!
  }

  func testColdLaunchWithCompletedOnboardingDoesNotStartAtWelcome() {
    let defaults = isolatedDefaults()
    defaults.set(true, forKey: "beid.hasCompletedOnboarding")

    let coordinator = AppCoordinator(userDefaults: defaults)

    XCTAssertNotEqual(coordinator.screen, .welcome)
  }

  func testColdLaunchWithoutCompletedOnboardingStartsAtWelcome() {
    let defaults = isolatedDefaults()

    let coordinator = AppCoordinator(userDefaults: defaults)

    XCTAssertEqual(coordinator.screen, .welcome)
  }

  func testRestoreEvaluatesBluetoothPermissionBeforeLandingOnHome() async {
    let defaults = isolatedDefaults()
    defaults.set(true, forKey: "beid.hasCompletedOnboarding")
    let evaluated = expectation(description: "Bluetooth permission evaluated")

    let coordinator = AppCoordinator(
      userDefaults: defaults,
      permissionEvaluation: {
        evaluated.fulfill()
        return .granted
      }
    )

    // `restoreAfterOnboarding()` starts this work from init and exposes no
    // task handle, so wait for the injected evaluation and then for its
    // state transition. The real CoreBluetooth XPC connection is outside
    // this unit test's contract and is covered by device/runtime evidence.
    await fulfillment(of: [evaluated], timeout: 1)
    let deadline = Date().addingTimeInterval(1)
    while coordinator.screen == .bluetoothPermission, Date() < deadline {
      try? await Task.sleep(nanoseconds: 10_000_000)
    }

    XCTAssertEqual(coordinator.screen, .home)
  }

  /// Regression for #220: `requestBluetoothPermission()`'s detached `Task`
  /// must not keep a deallocated `AppCoordinator` alive to write the
  /// onboarding key. `coordinator` is set to `nil` immediately after the
  /// call; a coordinator that has died has no business writing state.
  ///
  /// The RED run against pre-fix (strong-`self`) code failed as expected
  /// (the #220 fix's `red-test-run.log`), so the defect is real and this
  /// test can catch it.
  ///
  /// **This test used to be non-deterministic, and its doc used to say so at
  /// length.** It waited on the wall clock — 500ms, later widened to 20s —
  /// because the `Task` had no completion handle to await, and it read
  /// `UserDefaults.standard`. Both are gone: `requestBluetoothPermission()`
  /// now returns the `Task`, which this test awaits directly, and the
  /// defaults are a per-test suite with a UUID in its name. There is no
  /// timing window left to lose, and no shared key for another test in the
  /// same process to write into.
  ///
  /// That matters beyond tidiness. The old doc ended by telling whoever
  /// debugged this next to re-check `[weak self]` first and not the
  /// production code — **advice that was already wrong by the time it was
  /// read.** Two unexplained failures at two different wait durations were
  /// escalated as beid#393, and the mechanism found there was not the weak
  /// capture at all: `beid.hasCompletedOnboarding` lives in
  /// `UserDefaults.standard`, and any `AppCoordinator` constructed while it
  /// is set re-drives `restoreAfterOnboarding()` →
  /// `requestBluetoothPermission()` → `evaluateBluetoothState()`, which sets
  /// the key again — from a different test, inside this test's wait.
  ///
  /// The fix changed two things at once (isolate the defaults, await the
  /// task), so this file does not claim which one alone would have been
  /// enough. Both are needed for the test to be deterministic, and it now
  /// is.
  func testRequestBluetoothPermissionDoesNotWriteUserDefaultsAfterCoordinatorDeallocates() async {
    let defaults = UserDefaults(suiteName: "AppCoordinatorRestoreTests.deallocation.\(UUID().uuidString)")!
    defaults.removeObject(forKey: "beid.hasCompletedOnboarding")

    var coordinator: AppCoordinator? = AppCoordinator(userDefaults: defaults, permissionEvaluation: { .granted })
    let task = coordinator?.requestBluetoothPermission()
    coordinator = nil

    // Awaited directly: the task is the completion handle the old
    // wall-clock wait existed for.
    await task?.value

    XCTAssertFalse(defaults.bool(forKey: "beid.hasCompletedOnboarding"))
  }

  func testRequestBluetoothPermissionWritesWhenCoordinatorStaysAlive() async {
    let defaults = UserDefaults(suiteName: "AppCoordinatorRestoreTests.alive.\(UUID().uuidString)")!
    defaults.removeObject(forKey: "beid.hasCompletedOnboarding")
    let coordinator = AppCoordinator(userDefaults: defaults, permissionEvaluation: { .granted })

    await coordinator.requestBluetoothPermission().value

    XCTAssertTrue(defaults.bool(forKey: "beid.hasCompletedOnboarding"))
  }

  func testDeniedBluetoothPermissionRoutesToGuidance() async {
    let defaults = isolatedDefaults()
    let coordinator = AppCoordinator(
      userDefaults: defaults,
      permissionEvaluation: { .denied }
    )

    await coordinator.requestBluetoothPermission().value

    XCTAssertEqual(coordinator.screen, .bluetoothDenied)
  }

  func testUndeterminedBluetoothPermissionDoesNotAdvance() async {
    let defaults = isolatedDefaults()
    let coordinator = AppCoordinator(
      userDefaults: defaults,
      permissionEvaluation: { .notDetermined }
    )

    await coordinator.requestBluetoothPermission().value

    XCTAssertEqual(coordinator.screen, .bluetoothPermission)
    XCTAssertFalse(defaults.bool(forKey: "beid.hasCompletedOnboarding"))
  }

  func testGrantedBluetoothPermissionRoutesToHome() async {
    let defaults = isolatedDefaults()
    let coordinator = AppCoordinator(
      userDefaults: defaults,
      permissionEvaluation: { .granted }
    )

    await coordinator.requestBluetoothPermission().value

    XCTAssertEqual(coordinator.screen, .home)
  }
}
