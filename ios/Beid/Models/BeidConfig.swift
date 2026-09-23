// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

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

  // MARK: - Radar node signal strength (beid#652)
  //
  // Display-only tuning for the sensing radar's per-node signal strength.
  // Nothing below is read by any record, signing, or submission path — see
  // `NodeSignalStrength`, which explains why that is a property of the call
  // graph rather than a rule this comment asks anyone to remember.

  /// Exponential-moving-average weight applied to each new dBm sample:
  /// `new = previous + alpha * (sample - previous)`. Lower is steadier and
  /// slower to follow a real move; higher tracks faster and jitters more.
  ///
  /// **UNVERIFIED ON HARDWARE.** This value was chosen by reasoning, not
  /// measured: no real-device run has been possible for this change. What
  /// would settle it is a device-lab measurement (`tools/beid-lab-cli`,
  /// beid#588) of RSSI traces from phones held still and phones walking, then
  /// choosing the largest alpha at which a stationary node stops visibly
  /// crawling on the radar. Until then, treat it as a placeholder that
  /// happens to be in service.
  static let nodeSignalSmoothingFactor: Double = 0.25

  /// Floor on how often `SensingCoordinator.nodeSignalStrengths` is
  /// republished, in seconds. The smoothed value updates on every sample;
  /// only the republish — and so the redraw — is coalesced.
  ///
  /// Measured against the `timestamp` the Barnard event carries, never
  /// `Date()` and never a `Timer`. That is deliberate: it keeps the whole
  /// path deterministic and unit-testable with no clock seam and no async,
  /// and it is why this is a plain number here rather than a scheduler
  /// somewhere.
  ///
  /// **UNVERIFIED ON HARDWARE.** What would settle it is watching the radar
  /// at a real gathering, where advertisement rates and node counts are what
  /// they actually are, and lowering this until the motion reads as
  /// continuous — or raising it if redraw cost shows up in a time profile.
  static let nodeSignalRedrawMinimumInterval: TimeInterval = 0.5

  /// Exclusive upper bound for a *usable* RSSI sample: a sample counts as a
  /// measurement iff `rssi < nodeSignalUsableUpperBoundDbm`. Everything at or
  /// above it — `0`, any positive value, `127` — leaves the node
  /// `.unmeasured` and never reaches the smoother.
  ///
  /// **This is not tuning, and it must not be "simplified" away.** It exists
  /// because of one proven behaviour in the pinned Barnard SDK (v0.9.2,
  /// `61e2f0ba`): in `BarnardEngine.swift` the detection path reads
  /// `let rssi = discoveredRssi[id] ?? 0`, while `discoveredRssi` is cleared
  /// wholesale elsewhere in that file and a GATT exchange can still be in
  /// flight across that clear. So `rssi: 0` reaches this app meaning *"never
  /// measured"*, not *"0 dBm"*. 0 dBm is not a plausible BLE received power;
  /// real values are negative. Barnard's own `isUsableRssi` (which rejects
  /// exactly `127`, CoreBluetooth's unavailable marker) guards the
  /// `.rssiUpdate` path but is **not** applied to that `?? 0` fallback, so
  /// this app must reject the sentinel itself.
  ///
  /// Accepting `0` would place an unmeasured node at the radar's centre — the
  /// strongest possible proximity claim, made from no measurement at all. See
  /// `NodeSignalStrength.unmeasured`.
  ///
  /// **UNVERIFIED ON HARDWARE**, in the narrow sense that no real-device run
  /// has confirmed how often the sentinel actually arrives. The bound itself
  /// does not depend on that: it is read off the SDK source above, not
  /// estimated. What a device run would settle is whether rejecting these
  /// samples ever leaves a node visibly stuck at `.unmeasured` while it is
  /// plainly nearby, which would point at the SDK, not at this number.
  static let nodeSignalUsableUpperBoundDbm: Int = 0

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
