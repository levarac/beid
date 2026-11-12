// Copyright (c) 2024-2026 Levarac Foundation
// SPDX-License-Identifier: MIT

import Combine
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

/// Drives the real monitor's post-mapping publication body and root router.
/// This is not a hardware callback or an OS Settings authorization test.
@MainActor
final class BluetoothDeniedCallbackTests: XCTestCase {
  func testLaterGrantedCallbackRoutesDeniedScreenToHome() async throws {
    let monitor = BluetoothMonitor(makeCentralManager: { _ in nil })
    let coordinator = try makeCoordinator(monitor: monitor)
    await resolveInitialState(.denied, monitor: monitor, coordinator: coordinator)
    XCTAssertEqual(coordinator.screen, .bluetoothDenied)

    var published: [BluetoothAuthorizationState] = []
    var cachedDuringPublication: [BluetoothAuthorizationState] = []
    let observation = monitor.$state.dropFirst().sink { state in
      published.append(state)
      cachedDuringPublication.append(monitor.state)
    }
    defer { observation.cancel() }

    monitor.receiveAuthorizationState(.granted)

    XCTAssertEqual(published, [.granted])
    // @Published uses willSet. A future subscriber must consume its event,
    // rather than re-read this still-denied cache during delivery.
    XCTAssertEqual(cachedDuringPublication, [.denied])
    XCTAssertEqual(monitor.state, .granted)
    XCTAssertEqual(coordinator.screen, .home, "A delivered grant must leave denied guidance via the existing home route")
  }

  func testLaterPoweredOffCallbackRoutesDeniedScreenToBluetoothOff() async throws {
    let monitor = BluetoothMonitor(makeCentralManager: { _ in nil })
    let coordinator = try makeCoordinator(monitor: monitor)
    await resolveInitialState(.denied, monitor: monitor, coordinator: coordinator)
    XCTAssertEqual(coordinator.screen, .bluetoothDenied)

    var published: [BluetoothAuthorizationState] = []
    let observation = monitor.$state.dropFirst().sink { published.append($0) }
    defer { observation.cancel() }

    // The unchanged native mapping emits poweredOff for allowedAlways +
    // poweredOff; applyBluetoothState already routes it to bluetoothOff.
    monitor.receiveAuthorizationState(.poweredOff)

    XCTAssertEqual(published, [.poweredOff])
    XCTAssertEqual(monitor.state, .poweredOff)
    XCTAssertEqual(coordinator.screen, .bluetoothOff, "An authorized but off radio must use the existing Bluetooth-off route")
  }

  func testRepeatedDeniedCallbacksKeepDeniedGuidance() async throws {
    let monitor = BluetoothMonitor(makeCentralManager: { _ in nil })
    let coordinator = try makeCoordinator(monitor: monitor)
    await resolveInitialState(.denied, monitor: monitor, coordinator: coordinator)
    XCTAssertEqual(coordinator.screen, .bluetoothDenied)

    var published: [BluetoothAuthorizationState] = []
    let observation = monitor.$state.dropFirst().sink { published.append($0) }
    defer { observation.cancel() }

    monitor.receiveAuthorizationState(.denied)
    monitor.receiveAuthorizationState(.denied)

    XCTAssertEqual(published, [.denied, .denied])
    XCTAssertEqual(monitor.state, .denied)
    XCTAssertEqual(coordinator.screen, .bluetoothDenied)
  }

  func testUndeterminedCallbackDoesNotUnblockDeniedGuidance() async throws {
    let monitor = BluetoothMonitor(makeCentralManager: { _ in nil })
    let coordinator = try makeCoordinator(monitor: monitor)
    await resolveInitialState(.denied, monitor: monitor, coordinator: coordinator)
    XCTAssertEqual(coordinator.screen, .bluetoothDenied)

    // Unknown/unsettled native states map to notDetermined. The seam is
    // after that mapping; it makes no claim to exercise CBManager itself.
    monitor.receiveAuthorizationState(.notDetermined)

    XCTAssertEqual(monitor.state, .notDetermined)
    XCTAssertEqual(coordinator.screen, .bluetoothDenied)
  }

  func testLaterCallbacksPreserveHome() async throws {
    let monitor = BluetoothMonitor(makeCentralManager: { _ in nil })
    let coordinator = try makeCoordinator(monitor: monitor)
    await resolveInitialState(.granted, monitor: monitor, coordinator: coordinator)
    XCTAssertEqual(coordinator.screen, .home)

    let states: [BluetoothAuthorizationState] = [.denied, .poweredOff, .notDetermined, .granted]
    for state in states {
      monitor.receiveAuthorizationState(state)
      XCTAssertEqual(monitor.state, state)
      XCTAssertEqual(coordinator.screen, .home)
    }
  }

  func testLaterCallbacksPreservePresentedEventCodeEntry() async throws {
    let monitor = BluetoothMonitor(makeCentralManager: { _ in nil })
    let coordinator = try makeCoordinator(monitor: monitor)
    await resolveInitialState(.granted, monitor: monitor, coordinator: coordinator)
    coordinator.openEventCodeEntryFromAccountSheet()
    XCTAssertEqual(coordinator.screen, .home)
    XCTAssertTrue(coordinator.eventCodeEntrySheetPresented)

    let states: [BluetoothAuthorizationState] = [.denied, .poweredOff, .notDetermined, .granted]
    for state in states {
      monitor.receiveAuthorizationState(state)
      XCTAssertEqual(monitor.state, state)
      XCTAssertEqual(coordinator.screen, .home)
      XCTAssertTrue(coordinator.eventCodeEntrySheetPresented)
    }
  }

  func testLaterCallbacksDoNotAdvanceUnrequestedPermissionScreen() throws {
    let monitor = BluetoothMonitor(makeCentralManager: { _ in nil })
    let coordinator = try makeCoordinator(monitor: monitor)
    coordinator.beginOnboarding()

    monitor.receiveAuthorizationState(.granted)

    XCTAssertEqual(monitor.state, .granted)
    XCTAssertEqual(coordinator.screen, .bluetoothPermission)
  }

  private func resolveInitialState(
    _ state: BluetoothAuthorizationState,
    monitor: BluetoothMonitor,
    coordinator: AppCoordinator
  ) async {
    coordinator.beginOnboarding()
    XCTAssertEqual(coordinator.screen, .bluetoothPermission)
    let request = coordinator.requestBluetoothPermission()
    monitor.receiveAuthorizationState(state)
    await request.value
    XCTAssertEqual(monitor.state, state)
  }

  private func makeCoordinator(monitor: BluetoothMonitor) throws -> AppCoordinator {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("bluetooth-denied-callback-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    let suiteName = "BluetoothDeniedCallbackTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
    let sensing = makeIsolatedSensingCoordinator(
      for: self,
      participantRelayControl: RecordingParticipantRelayControl(),
      eventJoinControl: RecordingEventJoinControl()
    )
    return AppCoordinator(
      proofStore: ProofStore(fileURL: directory.appendingPathComponent("proofs.json")),
      sensingCoordinator: sensing,
      reportSubmissionStore: ReportSubmissionStore(fileURL: directory.appendingPathComponent("reports.json")),
      reportProofLinkStore: ReportProofLinkStore(fileURL: directory.appendingPathComponent("links.json")),
      registryClient: nil,
      userDefaults: defaults,
      bluetoothMonitor: monitor
    )
  }
}
