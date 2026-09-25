// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import Foundation

/// Sensing-time signal strength for one node.
///
/// USED FOR DISPLAY ONLY, NEVER FOR ANY DECISION. Nothing that records,
/// signs, or submits anything may read this type. That is not a convention
/// this comment asks for — it is a property of the call graph, and
/// `SensingCoordinator` is shaped to keep it true: `handleSignalStrength` is
/// a *sibling* of `handleDetection`, never a parameter of it, so no value of
/// this type is ever in lexical scope anywhere inside the recording call
/// tree (`handleDetection` → `observe` → `recordDeviceIdentity` → the window
/// ledger). Adding an `rssi` parameter to any of those, however convenient,
/// destroys the guarantee; the tests in `NodeSignalStrengthTests` only
/// witness it.
///
/// It also carries no ENIN window index, for the same structural reason: the
/// window index is record vocabulary, and a display path that cannot name
/// the window it belongs to cannot be folded into a per-window record even
/// by accident.
///
/// Values arrive from two distinct Barnard events — `.detection` (whose
/// `rssi` this app previously dropped on the floor) and `.rssiUpdate` — and
/// are keyed by the **normalized display id**
/// (`BeidSharedKit.sensing.normalizedDisplayIdOrNull`), the same identity the
/// radar drawing's angle uses, so the radius and the angle of a node cannot
/// disagree about which device they describe.
enum NodeSignalStrength: Equatable {
  /// The node is known but no usable measurement has arrived for it yet.
  ///
  /// This is not a rare edge case. It is the state of **every node on every
  /// iOS Simulator run**, because the Simulator has no BLE radio and the
  /// scripted `DemoEvent` path that stands in for scanning there produces no
  /// RSSI at all, ever. It is also the state of any real node whose only
  /// samples so far were the `0` sentinel described on
  /// `BeidConfig.nodeSignalUsableUpperBoundDbm`.
  ///
  /// **Defined rendering: the weakest position — outermost on the radar.**
  /// (This type does not implement that mapping; radius and position are
  /// beid#634's. It defines what the case *means* so #634 can draw it.)
  ///
  /// The reasoning, because the tempting alternatives are both worse. On a
  /// radar whose whole semantic is "distance from centre = signal strength",
  /// absence of evidence must never render as evidence of proximity. Drawing
  /// an unmeasured node at the centre would make the strongest possible
  /// proximity claim from zero measurement — which is exactly what Barnard's
  /// `discoveredRssi[id] ?? 0` fallback would cause if that `0` were taken
  /// literally as 0 dBm.
  ///
  /// Hiding the node instead was considered and rejected: the app already
  /// counts that device in `devicesVerified` the moment a detection with a
  /// display id arrives, so hiding it would make the graph disagree with the
  /// count printed next to it. A user can reconcile "far away"; they cannot
  /// reconcile "the number says 4 and I can see 3".
  case unmeasured
  /// Smoothed received power in dBm. Always strictly negative.
  ///
  /// Strict negativity is an invariant of the producer, not a request of the
  /// consumer: `SensingCoordinator.handleSignalStrength` admits a sample into
  /// the smoother only when it is below
  /// `BeidConfig.nodeSignalUsableUpperBoundDbm`, and an exponential moving
  /// average over strictly negative samples, seeded by one of them, stays
  /// strictly negative. It is stated here so a future producer cannot quietly
  /// widen the range and leave every consumer's scale wrong.
  ///
  /// Smoothed, not raw: a single BLE sample swings far enough to make a node
  /// visibly jitter. See `BeidConfig.nodeSignalSmoothingFactor`.
  case measured(dBm: Double)
}
