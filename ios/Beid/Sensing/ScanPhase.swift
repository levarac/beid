// Copyright (c) 2024-2026 Levarac Foundation
// SPDX-License-Identifier: MIT

import Foundation

/// Drives the scan modal's screens. `.verifying`/`.verified`/`.collected`
/// (pre-Slice-2) merge into `.recording`: window-based reporting has no
/// finish line, so there is no "verified" moment distinct from "still
/// recording," and no "collected" moment distinct from either — a `Proof`
/// exists in `ProofStore` from the instant `.recording` begins, not at a
/// later terminal step. See `docs/specs/scan-slice2-redesign.md` §4.2.
///
/// The five cases and the rules for moving between them are owned by
/// `BeidSharedKit.sensing` (beid#116; mirrored as `ScanPhaseKind` there,
/// without this type's native-owned `EventSession`/`peersVerified`
/// payload) — see `SensingCoordinator`'s use of `applyScanDetection`/
/// `scanPhaseAfterStartSensing`/`scanPhaseAfterStopSensing`/
/// `scanPhaseAfterSignalLost`/`scanPhaseAfterResumeSensing`.
enum ScanPhase: Equatable {
  case idle
  case sensing
  case eventFound(EventSession)
  /// `peersVerified` is a cumulative, no-denominator count of **distinct
  /// devices** (`SensingCoordinator.devicesVerified`) — the same counter used
  /// internally for the threshold-confirm check
  /// (`BeidConfig.eventConfirmThreshold`) and displayed as-is in the UI.
  ///
  /// It counts devices, not observations and not ENIN windows: a device that
  /// stays nearby for an hour contributes exactly one, however many times its
  /// proximity identifier rotates (beid#154). Observations whose device could
  /// not be identified are excluded and counted separately, so this is a lower
  /// bound on what was actually nearby.
  case recording(event: EventSession, peersVerified: Int)
  /// Frozen count, resumable via `SensingCoordinator.resumeSensing()` —
  /// not a restart. Nothing already recorded is lost.
  case signalLost(event: EventSession, peersVerified: Int)
}

extension ScanPhase {
  /// Updates only the matching event payload. The coordinator calls this on
  /// the MainActor so eventFound/recording/signalLost copies change together
  /// with the pending binding payload.
  func updatingIdentityVerification(
    forEventID eventID: String,
    to identityVerification: EventIdentityVerification
  ) -> ScanPhase {
    switch self {
    case .eventFound(let event) where event.id == eventID:
      return .eventFound(event.replacingIdentityVerification(identityVerification))
    case .recording(let event, let peersVerified) where event.id == eventID:
      return .recording(
        event: event.replacingIdentityVerification(identityVerification),
        peersVerified: peersVerified
      )
    case .signalLost(let event, let peersVerified) where event.id == eventID:
      return .signalLost(
        event: event.replacingIdentityVerification(identityVerification),
        peersVerified: peersVerified
      )
    default:
      return self
    }
  }
}
