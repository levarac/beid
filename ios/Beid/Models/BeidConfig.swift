// Copyright (c) 2024-2026 Levarac Foundation
// SPDX-License-Identifier: MIT

import BeidSharedKit
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
  /// The base value (`3`) now comes from
  /// `BeidSharedKit.sensing.defaultEventConfirmThreshold` (beid#231 item 3) —
  /// see that constant's doc comment for its provenance and what it does not
  /// settle. This property still owns the DEBUG-only overrides below, which
  /// wrap the shared value rather than replace it.
  #if DEBUG
  /// Test-only override, checked ahead of the `-beid-threshold-override`
  /// launch argument below. Exists because some threshold values (e.g. `1`,
  /// the edge case where `SENSING` moves straight through `EVENT_FOUND` to
  /// `RECORDING` in a single detection) are otherwise reachable only by
  /// relaunching the process with that launch argument, which a single
  /// `XCTestCase` sharing a process with every other test cannot do. `nil`
  /// (the default) defers to the launch-argument/`3` resolution below. This
  /// is process-global mutable state — a test that sets it must reset it to
  /// `nil` in `addTeardownBlock`, or it leaks into every test that runs
  /// afterward in the same process.
  static var eventConfirmThresholdOverrideForTesting: Int?
  #endif

  static var eventConfirmThreshold: Int {
    #if DEBUG
    if let override = eventConfirmThresholdOverrideForTesting {
      return override
    }
    let args = ProcessInfo.processInfo.arguments
    if let flagIndex = args.firstIndex(of: "-beid-threshold-override"),
       args.indices.contains(flagIndex + 1),
       let override = Int(args[flagIndex + 1]) {
      return override
    }
    #endif
    return Int(BeidSharedKit.sensing.defaultEventConfirmThreshold)
  }

  /// Resolves the Debug demo walkthrough requested by a launch argument.
  /// Invalid or incomplete input deliberately falls back to the App Review
  /// golden path, so an App Review/demo launch never becomes a blank screen.
  static func demoScenario(arguments: [String] = ProcessInfo.processInfo.arguments) -> DemoScenario {
    guard let flagIndex = arguments.firstIndex(of: "-beid-demo-scenario"),
          arguments.indices.contains(flagIndex + 1),
          let scenario = DemoScenario.named(arguments[flagIndex + 1])
    else {
      return .appReviewGolden
    }
    return scenario
  }
}
